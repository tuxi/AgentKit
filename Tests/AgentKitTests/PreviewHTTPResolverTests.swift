import Foundation
import XCTest
@testable import AgentKit

private final class PreviewHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, headers, data) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class PreviewHTTPResolverTests: XCTestCase {
    override func tearDown() {
        PreviewHTTPProtocol.handler = nil
        super.tearDown()
    }

    private func client(
        store: any CredentialStore = MemoryCredentialStore()
    ) -> RuntimeHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewHTTPProtocol.self]
        return RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: URLSession(configuration: configuration),
            credentialStore: store,
            credentialTarget: .runtimeAccess("preview-fixture")
        )
    }

    func testViewerBearerTokenStaysInHeaderNotInURL() async throws {
        let secret = "p1f-" + String(repeating: "a", count: 40)
        let store = MemoryCredentialStore()
        try await store.set(
            Credential(kind: .bearer, secret: secret),
            for: .runtimeAccess("preview-fixture")
        )
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        PreviewHTTPProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(secret)"
            )
            let absolute = request.url?.absoluteString ?? ""
            XCTAssertFalse(absolute.contains(secret), "bearer token leaked into the URL")
            XCTAssertNil(request.url?.query, "viewer URL must not carry a query")
            return (200, ["Content-Type": "text/html; charset=utf-8"], data)
        }

        _ = try await client(store: store).resolvePreviewViewer(
            PreviewViewerRequest(
                sessionID: "session_fixture",
                artifactID: "preview_fixture_interactive",
                revision: 1
            )
        )
    }

    func testViewerUsesExactRevisionRouteAndValidatesContent() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        PreviewHTTPProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/1/viewer"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["Content-Type": "text/html; charset=utf-8"], data)
        }
        let result = try await client().resolvePreviewViewer(
            PreviewViewerRequest(
                sessionID: "session_fixture",
                artifactID: "preview_fixture_interactive",
                revision: 1
            )
        )
        XCTAssertEqual(result.sizeBytes, data.count)
        XCTAssertEqual(result.mimeType, "text/html; charset=utf-8")
        XCTAssertEqual(result.sha256, "sha256:52e183244f37b43eb8f29cd4e8811314ecb50083887bd7ea28804a2f942c9f88")
    }

    func testAssetUsesExactRevisionRouteAndRasterMIME() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        PreviewHTTPProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/1/assets/asset_fixture_fallback/content"
            )
            return (200, ["Content-Type": "image/png"], data)
        }
        let result = try await client().resolvePreviewAsset(
            PreviewAssetRequest(
                sessionID: "session_fixture",
                artifactID: "preview_fixture_interactive",
                revision: 1,
                assetID: "asset_fixture_fallback"
            )
        )
        XCTAssertEqual(result.sizeBytes, data.count)
        XCTAssertEqual(result.mimeType, "image/png")
    }

    func testPreviewHTTPFailureParsesStructuredEnvelope() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("negative/viewer-error-response.json"))
        PreviewHTTPProtocol.handler = { _ in
            (422, ["Content-Type": "application/json"], data)
        }
        do {
            _ = try await client().resolvePreviewViewer(
                PreviewViewerRequest(sessionID: "session_fixture", artifactID: "preview_fixture_interactive", revision: 1)
            )
            XCTFail("preview error was accepted")
        } catch let RuntimeHTTPError.preview(error) {
            XCTAssertEqual(error.httpStatus, 422)
            XCTAssertEqual(error.code, 42200)
            XCTAssertEqual(error.error.code, "preview_digest_mismatch")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testViewerRejectsNonHTMLMIME() async throws {
        PreviewHTTPProtocol.handler = { _ in
            (200, ["Content-Type": "image/png"], Data([0x00]))
        }
        do {
            _ = try await client().resolvePreviewViewer(
                PreviewViewerRequest(sessionID: "session", artifactID: "artifact", revision: 1)
            )
            XCTFail("non-HTML viewer was accepted")
        } catch let error as PreviewResourceError {
            XCTAssertEqual(error.code, "preview_viewer_mime_mismatch")
        }
    }
}
