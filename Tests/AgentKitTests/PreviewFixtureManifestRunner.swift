//
//  PreviewFixtureManifestRunner.swift
//  AgentKitTests
//
//  Executes the frozen code-agent preview fixture manifest from the sibling
//  repository checkout. The runner is test-only; it never writes fixtures.
//

import CryptoKit
import Foundation
import XCTest
@testable import AgentKit

struct PreviewFixtureManifestRunner {
    static let contractSHA256 = "e61de0a8de24749f14d63e57c1211f161700fd5ad0dd9bc18a4c5fb453a221f3"
    static let manifestSHA256 = "f06b5bccfc736e8a620fac9994de2edbf5941900944f3cb51d7ae5ebba9d1caa"

    struct Manifest: Decodable {
        let fixtureVersion: String
        let contract: String
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case contract, cases
            case fixtureVersion = "fixture_version"
        }
    }

    struct Case: Decodable {
        let files: [String]
        let expected: JSONValue
        let scenarioID: String
        let fileDigests: [String: String]?
        let evaluationTime: String?

        enum CodingKeys: String, CodingKey {
            case files, expected
            case scenarioID = "scenario_id"
            case fileDigests = "file_digests"
            case evaluationTime = "evaluation_time"
        }
    }

    struct Report {
        let scenarioCount: Int
        let fileCount: Int
        let passedScenarios: [String]
    }

    static func fixtureRoot() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PREVIEW_FIXTURE_ROOT"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        let testFile = URL(fileURLWithPath: #filePath)
        let gitRoot = testFile
            .deletingLastPathComponent() // AgentKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AgentKit
            .deletingLastPathComponent() // git
        let sibling = gitRoot.appendingPathComponent(
            "code-agent/docs/capability-runtime-upgrade/fixtures/preview/v1"
        )
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }

        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Documents/work/git/code-agent/docs/capability-runtime-upgrade/fixtures/preview/v1"
        )
        if FileManager.default.fileExists(atPath: home.path) { return home }
        throw NSError(
            domain: "PreviewFixtureManifestRunner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Preview fixture directory is unavailable."]
        )
    }

    static func run() throws -> Report {
        let root = try fixtureRoot()
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard sha256(manifestData) == "sha256:" + manifestSHA256 else {
            throw NSError(domain: "PreviewFixtureManifestRunner", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Manifest SHA-256 changed."])
        }

        let contractURL = root
            .deletingLastPathComponent() // preview
            .deletingLastPathComponent() // fixtures
            .deletingLastPathComponent() // capability-runtime-upgrade
            .appendingPathComponent("PREVIEW_CONTRACT_V1_6.md")
        let contractData = try Data(contentsOf: contractURL)
        guard sha256(contractData) == "sha256:" + contractSHA256 else {
            throw NSError(domain: "PreviewFixtureManifestRunner", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Contract SHA-256 changed."])
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.fixtureVersion == "preview.fixtures.v1",
              manifest.contract == "preview_contract_v1" else {
            throw NSError(domain: "PreviewFixtureManifestRunner", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture manifest version is invalid."])
        }

        var fileCount = 0
        for testCase in manifest.cases {
            for file in testCase.files {
                let data = try Data(contentsOf: root.appendingPathComponent(file))
                if let expected = testCase.fileDigests?[file] {
                    guard sha256(data) == expected else {
                        throw NSError(domain: "PreviewFixtureManifestRunner", code: 5,
                                      userInfo: [NSLocalizedDescriptionKey: "Fixture digest mismatch: \(file)"])
                    }
                }
                fileCount += 1
            }
            try verify(testCase, root: root)
        }

        return Report(
            scenarioCount: manifest.cases.count,
            fileCount: fileCount,
            passedScenarios: manifest.cases.map(\.scenarioID)
        )
    }

    private static func verify(_ testCase: Case, root: URL) throws {
        let expected = testCase.expected
        let allCapabilities = AgentCapabilityFlags.previewClient
        let negotiation = PreviewCapabilityNegotiation(
            hello: PreviewCapability.allCases.map(\.rawValue),
            runtime: PreviewCapability.allCases.map(\.rawValue),
            client: allCapabilities
        )

        switch testCase.scenarioID {
        case "ready-interactive", "static-image", "pending", "unavailable",
             "failed-with-fallback", "failed-without-fallback", "unavailable-with-fallback",
             "expiry-derived":
            let artifact = try loadArtifact(testCase.files[0], root: root)
            guard artifact.status.rawValue == expected["artifact_status"].stringValue,
                  artifact.kind.rawValue == expected["kind"].stringValue || expected["kind"].stringValue.isEmpty else {
                throw scenarioError(testCase, "artifact status/kind mismatch")
            }
            if let fallbackID = expected["fallback_asset_id"].string, !fallbackID.isEmpty {
                guard artifact.fallback?.assetID == fallbackID else {
                    throw scenarioError(testCase, "fallback asset mismatch")
                }
            }
            if let errorCode = expected["error_code"].string, !errorCode.isEmpty {
                guard artifact.error?.code == errorCode else {
                    throw scenarioError(testCase, "artifact error mismatch")
                }
            }
            let evaluationDate = testCase.evaluationTime.flatMap(parseISO8601)
            let presentation = artifact.presentationState(
                at: evaluationDate ?? Date(timeIntervalSince1970: 0),
                capabilities: negotiation
            )
            if let expectedPresentation = expected["presentation"].string, !expectedPresentation.isEmpty {
                guard presentation.rawValue == expectedPresentation else {
                    throw scenarioError(testCase, "presentation mismatch: \(presentation.rawValue)")
                }
            }

        case "revision-replacement":
            var store = PreviewArtifactStore()
            _ = store.merge(try loadEvent(testCase.files[0], root: root))
            _ = store.merge(try loadEvent(testCase.files[1], root: root))
            guard store.artifacts.count == expected["block_count"].intValue,
                  store.artifacts.first?.artifactID == expected["final_artifact_id"].stringValue,
                  store.artifacts.first?.revision == expected["final_revision"].intValue,
                  store.artifacts.first?.status.rawValue == expected["final_status"].stringValue else {
                throw scenarioError(testCase, "revision replacement mismatch")
            }

        case "duplicate-revision":
            var store = PreviewArtifactStore()
            let first = try loadEvent(testCase.files[0], root: root)
            let duplicate = try loadEvent(testCase.files[1], root: root)
            _ = store.merge(first)
            guard case .duplicate = store.merge(duplicate),
                  store.artifacts.count == expected["block_count"].intValue,
                  store.artifacts.first?.revision == expected["final_revision"].intValue else {
                throw scenarioError(testCase, "duplicate merge mismatch")
            }

        case "revision-conflict":
            var store = PreviewArtifactStore()
            _ = store.merge(try loadEvent(testCase.files[0], root: root))
            let result = store.merge(try loadEvent(testCase.files[1], root: root))
            guard result.errorCode == expected["error_code"].stringValue,
                  store.artifacts.first?.artifactID == expected["preserved_artifact_id"].stringValue,
                  store.artifacts.first?.revision == expected["preserved_revision"].intValue else {
                throw scenarioError(testCase, "revision conflict mismatch")
            }

        case "capability-matrix":
            let data = try Data(contentsOf: root.appendingPathComponent(testCase.files[0]))
            let matrix = try JSONDecoder().decode(JSONValue.self, from: data)
            for item in matrix["cases"].array ?? [] {
                let runtime = item["runtime"].array?.compactMap(\.string) ?? []
                let client = item["client"].array?.compactMap(\.string) ?? []
                let result = PreviewCapabilityNegotiation(hello: runtime, runtime: runtime, client: client)
                let expectedValue = item["expected"].stringValue
                switch expectedValue {
                case "interactive":
                    guard result.interactiveAvailable else { throw scenarioError(testCase, "expected interactive") }
                case "static":
                    guard result.staticAvailable, !result.interactiveAvailable else {
                        throw scenarioError(testCase, "expected static")
                    }
                case "unavailable", "unavailable_contract_absent":
                    guard !result.contractAvailable else { throw scenarioError(testCase, "expected unavailable") }
                case "degraded_invalid_runtime_advertisement_static":
                    guard result.runtimeAdvertisementInvalid, result.staticAvailable else {
                        throw scenarioError(testCase, "expected degraded static")
                    }
                case "live_interactive_history_static":
                    guard result.interactiveAvailable, !result.replayAvailable else {
                        throw scenarioError(testCase, "expected live-only interactive")
                    }
                case "interactive_unknown_ignored":
                    guard result.interactiveAvailable else {
                        throw scenarioError(testCase, "expected unknown capability ignored")
                    }
                default:
                    throw scenarioError(testCase, "unknown capability expectation: \(expectedValue)")
                }
            }

        case "producer-shape":
            let data = try Data(contentsOf: root.appendingPathComponent(testCase.files[0]))
            let producer = try JSONDecoder().decode(JSONValue.self, from: data)
            let previews = try ["server_tool", "hidden_client_tool", "direct_client_tool"]
                .compactMap { producer[$0]["previews"].array?.first }
                .map { try PreviewArtifactDraft.decode($0) }
            guard previews.count == 3,
                  previews.dropFirst().allSatisfy({ $0 == previews[0] }) else {
                throw scenarioError(testCase, "producer draft shapes differ")
            }

        case "negative-security":
            let digestData = try Data(contentsOf: root.appendingPathComponent("negative/viewer-error-response.json"))
            guard let httpError = PreviewHTTPError.decode(data: digestData, httpStatus: 422),
                  httpError.error.code == "preview_digest_mismatch" else {
                throw scenarioError(testCase, "HTTP preview error mismatch")
            }
            let invalidUTF8 = try Data(contentsOf: root.appendingPathComponent("negative/invalid-utf8.bin"))
            do {
                _ = try PreviewArtifact.decode(data: invalidUTF8)
                throw scenarioError(testCase, "invalid UTF-8 was accepted")
            } catch let error as PreviewArtifactError {
                guard error.code == "preview_invalid_artifact" else { throw error }
            }

        case "viewer-size-boundary":
            let accepted = try Data(contentsOf: root.appendingPathComponent("negative/viewer-2MiB.html"))
            let rejected = try Data(contentsOf: root.appendingPathComponent("negative/viewer-2MiB-plus-1.html"))
            guard accepted.count == expected["accepted_at"].intValue,
                  rejected.count > expected["rejected_above"].intValue else {
                throw scenarioError(testCase, "viewer size boundary mismatch")
            }

        case "transport-neutral-resolver":
            let contractData = try Data(contentsOf: root.appendingPathComponent("resolver-contract.json"))
            let contract = try JSONDecoder().decode(JSONValue.self, from: contractData)
            let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
            let assetData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
            let viewer = contract["viewer"]
            let asset = contract["asset"]
            guard viewerData.count == viewer["expected_size_bytes"].intValue,
                  assetData.count == asset["expected_size_bytes"].intValue,
                  sha256(viewerData) == viewer["expected_sha256"].stringValue,
                  sha256(assetData) == asset["expected_sha256"].stringValue else {
                throw scenarioError(testCase, "resolver fixture bytes mismatch")
            }

        default:
            throw scenarioError(testCase, "unhandled scenario")
        }
    }

    private static func loadArtifact(_ file: String, root: URL) throws -> PreviewArtifact {
        let data = try Data(contentsOf: root.appendingPathComponent(file))
        return try PreviewArtifact.decode(data: data)
    }

    private static func loadEvent(_ file: String, root: URL) throws -> PreviewArtifactEvent {
        let data = try Data(contentsOf: root.appendingPathComponent(file))
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        guard case .previewArtifact(let event) = AgentEvent.from(wire: wire) else {
            throw NSError(domain: "PreviewFixtureManifestRunner", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Preview event did not decode: \(file)"])
        }
        return event
    }

    private static func scenarioError(_ testCase: Case, _ message: String) -> NSError {
        NSError(
            domain: "PreviewFixtureManifestRunner",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "\(testCase.scenarioID): \(message)"]
        )
    }

    private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
