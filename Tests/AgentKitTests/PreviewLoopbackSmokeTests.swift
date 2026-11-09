//
//  PreviewLoopbackSmokeTests.swift
//  AgentKitTests
//
//  Cross-repo smoke coverage for the authenticated preview fixture server.
//  These tests opt in through PREVIEW_LOOPBACK_READY and otherwise skip.
//

#if os(macOS)
import AppKit
import XCTest
@testable import AgentKit

@MainActor
final class PreviewLoopbackSmokeTests: XCTestCase {
    private struct Ready: Decodable {
        let baseURL: String
        let bearerToken: String

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case bearerToken = "bearer_token"
        }
    }

    private struct ResolverContract: Decodable {
        struct Entry: Decodable {
            let expectedMIMEType: String
            let expectedSizeBytes: Int
            let expectedSHA256: String

            enum CodingKeys: String, CodingKey {
                case expectedMIMEType = "expected_mime_type"
                case expectedSizeBytes = "expected_size_bytes"
                case expectedSHA256 = "expected_sha256"
            }
        }

        let viewer: Entry
        let asset: Entry
    }

    private func liveClient() async throws -> DefaultAgentClient {
        guard let raw = ProcessInfo.processInfo.environment["PREVIEW_LOOPBACK_READY"],
              !raw.isEmpty else {
            throw XCTSkip("PREVIEW_LOOPBACK_READY is not configured")
        }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(raw.utf8))
        let origin = try XCTUnwrap(URL(string: ready.baseURL))
        let environment = try RuntimeEnvironment(origin: origin)
        let store = MemoryCredentialStore()
        try await store.set(
            Credential(kind: .bearer, secret: ready.bearerToken),
            for: .runtimeAccess("preview-fixture")
        )
        return DefaultAgentClient(
            environment: environment,
            credentialStore: store,
            credentialTarget: .runtimeAccess("preview-fixture")
        )
    }

    private func fixtureRoot() throws -> URL {
        try PreviewFixtureManifestRunner.fixtureRoot()
    }

    private func loadArtifact(_ name: String, root: URL) throws -> PreviewArtifact {
        try PreviewArtifact.decode(data: Data(contentsOf: root.appendingPathComponent(name)))
    }

    private func previewEvents(in batch: AgentEventBatch) -> [PreviewArtifactEvent] {
        batch.events.compactMap { event in
            guard case .previewArtifact(let preview) = event else { return nil }
            return preview
        }
    }

    func testExactRevisionViewerAndAssetOverAuthenticatedLoopback() async throws {
        let client = try await liveClient()
        let root = try fixtureRoot()
        let artifact = try loadArtifact("ready-interactive.json", root: root)
        let contract = try JSONDecoder().decode(
            ResolverContract.self,
            from: Data(contentsOf: root.appendingPathComponent("resolver-contract.json"))
        )

        let capabilities = try await client.runtimeCapabilities()
        for capability in PreviewCapability.allCases {
            XCTAssertEqual(capabilities.capabilities[capability.rawValue], true, capability.rawValue)
        }

        let viewerResolver = try XCTUnwrap(client.previewViewerResolver())
        let viewer = try await viewerResolver.resolve(PreviewViewerRequest(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision
        ))
        XCTAssertEqual(
            artifact.viewer?.url,
            "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/1/viewer"
        )
        XCTAssertEqual(viewer.mimeType, contract.viewer.expectedMIMEType)
        XCTAssertEqual(viewer.sizeBytes, contract.viewer.expectedSizeBytes)
        XCTAssertEqual(viewer.sha256, contract.viewer.expectedSHA256)
        XCTAssertEqual(viewer.data.count, contract.viewer.expectedSizeBytes)
        try viewer.validate(against: artifact)

        let assetResolver = try XCTUnwrap(client.previewAssetResolver())
        let asset = try await assetResolver.resolveContent(PreviewAssetRequest(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            assetID: "asset_fixture_fallback"
        ))
        XCTAssertEqual(
            artifact.assets.first?.contentURL,
            "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/1/assets/asset_fixture_fallback/content"
        )
        XCTAssertEqual(asset.mimeType, contract.asset.expectedMIMEType)
        XCTAssertEqual(asset.sizeBytes, contract.asset.expectedSizeBytes)
        XCTAssertEqual(asset.sha256, contract.asset.expectedSHA256)
        XCTAssertEqual(asset.data.count, contract.asset.expectedSizeBytes)
        try asset.validate(against: artifact)

        let replacement = try loadArtifact("failed-with-fallback.json", root: root)
        let replacementAsset = try await assetResolver.resolveContent(PreviewAssetRequest(
            sessionID: replacement.sessionID,
            artifactID: replacement.artifactID,
            revision: replacement.revision,
            assetID: "asset_fixture_fallback"
        ))
        XCTAssertEqual(
            replacement.assets.first?.contentURL,
            "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/2/assets/asset_fixture_fallback/content"
        )
        XCTAssertEqual(replacementAsset.revision, 2)
        XCTAssertEqual(replacementAsset.data, asset.data)
        try replacementAsset.validate(against: replacement)
    }

    func testFallbackPNGDecodesAndStaticFallbackUsesNetworkAsset() async throws {
        let client = try await liveClient()
        let root = try fixtureRoot()
        let artifact = try loadArtifact("unavailable-with-fallback.json", root: root)
        let assetResolver = try XCTUnwrap(client.previewAssetResolver())
        let asset = try await assetResolver.resolveContent(PreviewAssetRequest(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            assetID: "asset_fixture_fallback"
        ))
        try asset.validate(against: artifact)

        let image = try XCTUnwrap(NSBitmapImageRep(data: asset.data))
        XCTAssertEqual(image.pixelsWide, 1200)
        XCTAssertEqual(image.pixelsHigh, 800)

        let all = PreviewCapabilityNegotiation(
            hello: PreviewCapability.allCases.map(\.rawValue),
            runtime: PreviewCapability.allCases.map(\.rawValue),
            client: .previewClient
        )
        XCTAssertEqual(
            artifact.presentationState(at: Date(timeIntervalSince1970: 0), capabilities: all),
            .staticFallback
        )

        let staticImage = try loadArtifact("static-image.json", root: root)
        let staticAsset = try await assetResolver.resolveContent(PreviewAssetRequest(
            sessionID: staticImage.sessionID,
            artifactID: staticImage.artifactID,
            revision: staticImage.revision,
            assetID: "asset_fixture_fallback"
        ))
        try staticAsset.validate(against: staticImage)
        XCTAssertEqual(
            staticImage.presentationState(at: Date(timeIntervalSince1970: 0), capabilities: all),
            .staticFallback
        )
    }

    func testReplayRequiresObservationOfReplacementDuplicateAndConflict() async throws {
        let client = try await liveClient()
        let cases: [(session: String, check: (PreviewArtifactMergeResult) -> Void)] = [
            ("session_fixture_revision_replacement", { result in
                guard case .replaced(_, previousRevision: 1, revision: 2) = result else {
                    return XCTFail("expected revision replacement, got \(result)")
                }
            }),
            ("session_fixture_duplicate_revision", { result in
                guard case .duplicate(_, revision: 1) = result else {
                    return XCTFail("expected duplicate revision, got \(result)")
                }
            }),
            ("session_fixture_revision_conflict", { result in
                guard case .conflict(_, revision: 1, let error) = result else {
                    return XCTFail("expected revision conflict, got \(result)")
                }
                XCTAssertEqual(error.code, "preview_revision_conflict")
            }),
        ]

        for item in cases {
            let batch = try await client.getEventBatch(conversationID: item.session, since: 0)
            let events = previewEvents(in: batch)
            XCTAssertEqual(events.count, 2, item.session)
            XCTAssertTrue(events.allSatisfy(\.isValid), item.session)
            XCTAssertEqual(
                batch.nextSince,
                events.compactMap(\.sequence).max(),
                item.session
            )

            var store = PreviewArtifactStore()
            guard case .inserted(_, revision: 1) = store.merge(events[0]) else {
                return XCTFail("first replay event was not inserted: \(item.session)")
            }
            item.check(store.merge(events[1]))
            XCTAssertEqual(store.artifacts.count, 1, item.session)
            XCTAssertEqual(store.artifacts.first?.artifactID, "preview_fixture_interactive", item.session)
            XCTAssertEqual(store.artifacts.first?.revision, item.session.contains("replacement") ? 2 : 1, item.session)
        }
    }

    func testNetworkViewerIsSandboxedAndIsolatedFromParentFrame() async throws {
        let client = try await liveClient()
        let root = try fixtureRoot()
        let artifact = try loadArtifact("ready-interactive.json", root: root)
        let resolver = try XCTUnwrap(client.previewViewerResolver())
        let viewer = try await resolver.resolve(PreviewViewerRequest(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision
        ))
        try viewer.validate(against: artifact)

        let html = try ConversationWebPreviewSecurity.validateViewerDocument(viewer.data)
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertEqual(ConversationWebPreviewSecurity.iframeSandbox, "allow-scripts")
        for forbidden in [
            "allow-same-origin", "allow-forms", "allow-popups",
            "allow-top-navigation", "allow-downloads", "allow-modals",
        ] {
            XCTAssertFalse(ConversationWebPreviewSecurity.iframeSandbox.contains(forbidden))
        }

        let shell = ConversationWebSchemeHandler.indexURL
        let remote = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertEqual(
            ConversationWebPreviewSecurity.navigationDecision(
                url: remote,
                isMainFrame: false,
                isNewWindow: false,
                shouldPerformDownload: false,
                isInitialShellNavigation: false,
                shellURL: shell,
                pendingPreviewInitialURLs: [remote]
            ),
            .cancel
        )

        let handler = ConversationWebSchemeHandler()
        let frameURL = try XCTUnwrap(handler.registerPreviewViewer(viewer))
        XCTAssertTrue(frameURL.absoluteString.hasPrefix("agentkit-workbench://preview/"))
        XCTAssertFalse(frameURL.absoluteString.hasPrefix(shell.absoluteString))
    }
}
#endif
