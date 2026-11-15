//
//  PreviewResolverRetryTests.swift
//  AgentKitTests
//
//  P1-F.2: a session switch or replay can mount the preview card from the
//  client snapshot a moment before the runtime has registered the artifact,
//  producing one spurious 404. The resolver retries that window once, keeps
//  the same revision, and never retries a real failure.
//

import Foundation
import XCTest
@testable import AgentKit

final class PreviewResolverRetryTests: XCTestCase {
    private let viewerRequest = PreviewViewerRequest(
        sessionID: "session_fixture",
        artifactID: "preview_fixture_interactive",
        revision: 2
    )

    func testRegistrationLag404RetriesTheSameRevisionAndSucceeds() async throws {
        let request = viewerRequest
        let resolver = StubViewerResolver(results: [
            .failure(missingError()),
            .success(viewerResource()),
        ])
        let retry = PreviewResolverRetry(
            policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
        )

        let result = try await retry.run {
            try await resolver.resolve(request)
        }

        XCTAssertEqual(result.revision, 2)
        let requests = await resolver.requests
        XCTAssertEqual(requests, [request, request])
    }

    func testPersistent404StillSurfacesAfterOneTransparentRetry() async throws {
        let request = viewerRequest
        let resolver = StubViewerResolver(results: [
            .failure(missingError()),
            .failure(missingError()),
        ])
        let retry = PreviewResolverRetry(
            policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
        )

        do {
            _ = try await retry.run {
                try await resolver.resolve(request)
            }
            XCTFail("persistent 404 was hidden")
        } catch let error as PreviewHTTPError {
            XCTAssertEqual(error.httpStatus, 404)
            XCTAssertEqual(error.error.code, "preview_artifact_missing")
        }
        let requests = await resolver.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0 == request })
    }

    func testNonTransientViewerFailureIsNotRetried() async throws {
        let request = viewerRequest
        let resolver = StubViewerResolver(results: [
            .failure(PreviewHTTPError(
                traceID: nil,
                httpStatus: 422,
                code: 42200,
                error: PreviewArtifactError(
                    code: "preview_digest_mismatch",
                    message: "Viewer digest did not match."
                )
            )),
        ])
        let retry = PreviewResolverRetry(
            policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
        )

        do {
            _ = try await retry.run {
                try await resolver.resolve(request)
            }
            XCTFail("digest mismatch was accepted")
        } catch let error as PreviewHTTPError {
            XCTAssertEqual(error.httpStatus, 422)
        }
        let requests = await resolver.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAssetRegistrationLag404RetriesAndKeepsAssetIdentity() async throws {
        let request = PreviewAssetRequest(
            sessionID: "session_fixture",
            artifactID: "preview_fixture_interactive",
            revision: 2,
            assetID: "asset_fixture_fallback"
        )
        let resolver = StubAssetResolver(results: [
            .failure(missingError()),
            .success(assetResource(assetID: request.assetID)),
        ])
        let retry = PreviewResolverRetry(
            policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
        )

        let result = try await retry.run {
            try await resolver.resolveContent(request)
        }

        XCTAssertEqual(result.assetID, "asset_fixture_fallback")
        XCTAssertEqual(result.revision, 2)
        let requests = await resolver.requests
        XCTAssertEqual(requests, [request, request])
    }

    func testRuntimeResolverRetries404WithoutLeakingTokenIntoURL() async throws {
        let secret = "p1f2-" + String(repeating: "b", count: 40)
        let store = MemoryCredentialStore()
        try await store.set(
            Credential(kind: .bearer, secret: secret),
            for: .runtimeAccess("preview-retry")
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewRetryHTTPProtocol.self]
        let http = RuntimeHTTPClient(
            environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
            session: URLSession(configuration: configuration),
            credentialStore: store,
            credentialTarget: .runtimeAccess("preview-retry")
        )
        let html = Data("<!doctype html><html><body>preview</body></html>".utf8)
        PreviewRetryHTTPProtocol.reset(html: html)

        let resolver = RuntimePreviewResolver(
            http: http,
            retry: PreviewResolverRetry(
                policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
            )
        )
        let result = try await resolver.resolve(PreviewViewerRequest(
            sessionID: "session_fixture",
            artifactID: "preview_fixture_interactive",
            revision: 2
        ))

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(PreviewRetryHTTPProtocol.requests.count, 2)
        for request in PreviewRetryHTTPProtocol.requests {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(secret)"
            )
            let absolute = request.url?.absoluteString ?? ""
            XCTAssertFalse(absolute.contains(secret))
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(
                request.url?.path,
                "/v1/conversations/session_fixture/previews/preview_fixture_interactive/revisions/2/viewer"
            )
        }
    }

    private func missingError() -> PreviewHTTPError {
        PreviewHTTPError(
            traceID: "trace_fixture",
            httpStatus: 404,
            code: 40400,
            error: PreviewArtifactError(
                code: "preview_artifact_missing",
                message: "Artifact not found."
            )
        )
    }

    private func viewerResource() -> PreviewViewerResource {
        let data = Data("<!doctype html><html><body>preview</body></html>".utf8)
        return PreviewViewerResource(
            sessionID: "session_fixture",
            artifactID: "preview_fixture_interactive",
            revision: 2,
            data: data,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: data.count,
            sha256: PreviewRFC8785.sha256(data: data)
        )
    }

    private func assetResource(assetID: String) -> PreviewAssetResource {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        return PreviewAssetResource(
            sessionID: "session_fixture",
            artifactID: "preview_fixture_interactive",
            revision: 2,
            assetID: assetID,
            data: data,
            statusCode: 200,
            mimeType: "image/png",
            sizeBytes: data.count,
            sha256: PreviewRFC8785.sha256(data: data)
        )
    }
}

private actor StubViewerResolver: PreviewViewerResolver {
    private var results: [Result<PreviewViewerResource, Error>]
    private(set) var requests: [PreviewViewerRequest] = []

    init(results: [Result<PreviewViewerResource, Error>]) {
        self.results = results
    }

    func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
        requests.append(request)
        let result = results.isEmpty
            ? Result<PreviewViewerResource, Error>.failure(PreviewResourceError(
                code: "preview_invalid_artifact",
                message: "No stub result."
            ))
            : results.removeFirst()
        return try result.get()
    }
}

private actor StubAssetResolver: PreviewAssetResolver {
    private var results: [Result<PreviewAssetResource, Error>]
    private(set) var requests: [PreviewAssetRequest] = []

    init(results: [Result<PreviewAssetResource, Error>]) {
        self.results = results
    }

    func resolveContent(_ request: PreviewAssetRequest) async throws -> PreviewAssetResource {
        requests.append(request)
        let result = results.isEmpty
            ? Result<PreviewAssetResource, Error>.failure(PreviewResourceError(
                code: "preview_asset_unavailable",
                message: "No stub result."
            ))
            : results.removeFirst()
        return try result.get()
    }
}

private final class PreviewRetryHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var html = Data()
    nonisolated(unsafe) private static var attempted = 0
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(html: Data) {
        Self.html = html
        attempted = 0
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attempted += 1
        Self.requests.append(request)
        if Self.attempted == 1 {
            let body = Data("""
            {"trace_id":"trace_fixture","code":40400,"msg":"preview_artifact_missing",\
            "data":{"http_status":404,"error":{"code":"preview_artifact_missing",\
            "message":"Artifact not found.","retryable":false}}}
            """.utf8)
            respond(status: 404, headers: ["Content-Type": "application/json"], data: body)
        } else {
            respond(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                data: Self.html
            )
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String], data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: nil,
                  headerFields: headers
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
