//
//  UIPreviewViewerTimingTests.swift
//  AgentKitTests
//
//  P1-F.2: the native preview card must issue one request per artifact
//  revision when a session switch remounts it, must keep the exact revision
//  through its Retry path, and must still surface a real 404 as a render
//  failure instead of silently retrying forever.
//

#if os(iOS)
import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class UIPreviewViewerTimingTests: XCTestCase {
    private let viewerHTML = """
    <!doctype html><html><head>
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
    </head><body>preview</body></html>
    """

    func testConcurrentMountsShareOneViewerRequest() async {
        let resolver = CountingViewerResolver(delay: .milliseconds(40))
        let model = UIPreviewViewerModel()

        async let first: Void = model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            resolver: resolver
        )
        async let second: Void = model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            resolver: resolver
        )
        _ = await (first, second)

        let requests = await resolver.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.revision, 3)
        XCTAssertEqual(model.phase, .ready(viewerHTML))
    }

    func testRemountingTheSameRevisionDoesNotIssueAnotherRequest() async {
        let resolver = CountingViewerResolver(delay: .milliseconds(1))
        let model = UIPreviewViewerModel()

        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            resolver: resolver
        )
        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            resolver: resolver
        )

        let requests = await resolver.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testForcedRetryKeepsTheExactRevision() async {
        let resolver = CountingViewerResolver(delay: .milliseconds(1))
        let model = UIPreviewViewerModel()

        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 5,
            resolver: resolver
        )
        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 5,
            resolver: resolver,
            force: true
        )

        let requests = await resolver.requests
        XCTAssertEqual(requests.map(\.revision), [5, 5])
        XCTAssertEqual(model.phase, .ready(viewerHTML))
    }

    func testReal404StillSurfacesAsRenderFailure() async {
        let resolver = FailingViewerResolver(error: PreviewHTTPError(
            traceID: nil,
            httpStatus: 404,
            code: 40400,
            error: PreviewArtifactError(
                code: "preview_artifact_missing",
                message: "Artifact not found."
            )
        ))
        let model = UIPreviewViewerModel()

        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            resolver: resolver
        )

        XCTAssertEqual(model.phase, .failed("preview_artifact_missing"))
    }

    func testConcurrentFallbackLoadsShareOneAssetRequest() async {
        let resolver = CountingAssetResolver(delay: .milliseconds(40))
        let model = UIPreviewFallbackModel()

        async let first: Void = model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            assetID: "asset_fallback",
            expectedSHA256: nil,
            resolver: resolver
        )
        async let second: Void = model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 3,
            assetID: "asset_fallback",
            expectedSHA256: nil,
            resolver: resolver
        )
        _ = await (first, second)

        let requests = await resolver.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.assetID, "asset_fallback")
        if case .ready = model.phase {
        } else {
            XCTFail("fallback image did not load")
        }
    }

    func testRevisionOneThenTwoRequestsTheExactRevision() async {
        let resolver = RoutingViewerResolver(delays: [:])
        let model = UIPreviewViewerModel()

        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            resolver: resolver
        )
        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 2,
            resolver: resolver
        )

        let requests = await resolver.requests
        XCTAssertEqual(requests.map(\.revision), [1, 2])
        XCTAssertEqual(
            model.phase,
            .ready(RoutingViewerResolver.document(
                for: .init(sessionID: "session", artifactID: "artifact", revision: 2)
            ))
        )
    }

    func testQuickSessionSwitchIgnoresTheStaleResult() async {
        let oldRoute = RoutingViewerResolver.Route(
            sessionID: "old-session",
            artifactID: "artifact",
            revision: 1
        )
        let newRoute = RoutingViewerResolver.Route(
            sessionID: "new-session",
            artifactID: "artifact",
            revision: 1
        )
        let resolver = RoutingViewerResolver(delays: [
            oldRoute: .milliseconds(120),
            newRoute: .milliseconds(1),
        ])
        let model = UIPreviewViewerModel()

        async let oldLoad: Void = model.load(
            sessionID: oldRoute.sessionID,
            artifactID: oldRoute.artifactID,
            revision: oldRoute.revision,
            resolver: resolver
        )
        try? await Task.sleep(for: .milliseconds(5))
        async let newLoad: Void = model.load(
            sessionID: newRoute.sessionID,
            artifactID: newRoute.artifactID,
            revision: newRoute.revision,
            resolver: resolver
        )
        _ = await (oldLoad, newLoad)

        let requests = await resolver.requests
        XCTAssertEqual(Set(requests.map(\.sessionID)), ["new-session", "old-session"])
        XCTAssertEqual(model.phase, .ready(RoutingViewerResolver.document(for: newRoute)))
    }

    func testReplayFirstOpenRetriesRegistrationLagThenRenders() async {
        let base = RegistrationLagViewerResolver(delay: .milliseconds(1))
        let resolver = RetryingViewerResolver(base: base)
        let model = UIPreviewViewerModel()

        await model.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            resolver: resolver
        )

        let attempts = await base.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(
            model.phase,
            .ready(RegistrationLagViewerResolver.document)
        )
    }

    func testReal404LeavesTheFallbackImageUsable() async {
        let viewer = FailingViewerResolver(error: PreviewHTTPError(
            traceID: nil,
            httpStatus: 404,
            code: 40400,
            error: PreviewArtifactError(
                code: "preview_artifact_missing",
                message: "Artifact not found."
            )
        ))
        let asset = CountingAssetResolver(delay: .milliseconds(1))
        let viewerModel = UIPreviewViewerModel()
        let fallbackModel = UIPreviewFallbackModel()

        await viewerModel.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            resolver: viewer
        )
        await fallbackModel.load(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            assetID: "asset_fallback",
            expectedSHA256: nil,
            resolver: asset
        )

        XCTAssertEqual(viewerModel.phase, .failed("preview_artifact_missing"))
        if case .ready = fallbackModel.phase {
        } else {
            XCTFail("fallback image must remain available after a viewer 404")
        }
    }

    private actor CountingViewerResolver: PreviewViewerResolver {
        nonisolated let delay: Duration
        private let html: String
        private(set) var requests: [PreviewViewerRequest] = []

        init(delay: Duration) {
            self.delay = delay
            self.html = """
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
            </head><body>preview</body></html>
            """
        }

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            requests.append(request)
            try await Task.sleep(for: delay)
            let data = Data(html.utf8)
            return PreviewViewerResource(
                sessionID: request.sessionID,
                artifactID: request.artifactID,
                revision: request.revision,
                data: data,
                statusCode: 200,
                mimeType: "text/html; charset=utf-8",
                sizeBytes: data.count,
                sha256: PreviewRFC8785.sha256(data: data)
            )
        }
    }

    private struct FailingViewerResolver: PreviewViewerResolver {
        let error: PreviewHTTPError

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            throw error
        }
    }

    private struct RetryingViewerResolver: PreviewViewerResolver {
        let base: any PreviewViewerResolver

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            let retry = PreviewResolverRetry(
                policy: .init(maximumAttempts: 2, delay: .milliseconds(1))
            )
            return try await retry.run {
                try await base.resolve(request)
            }
        }
    }

    private actor RoutingViewerResolver: PreviewViewerResolver {
        struct Route: Hashable, Sendable {
            let sessionID: String
            let artifactID: String
            let revision: Int
        }

        private let delays: [Route: Duration]
        private(set) var requests: [PreviewViewerRequest] = []

        init(delays: [Route: Duration]) {
            self.delays = delays
        }

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            requests.append(request)
            let route = Route(
                sessionID: request.sessionID,
                artifactID: request.artifactID,
                revision: request.revision
            )
            if let delay = delays[route] {
                try await Task.sleep(for: delay)
            }
            return Self.resource(for: request, html: Self.document(for: route))
        }

        static func document(for route: Route) -> String {
            document(identity: "\(route.sessionID)|\(route.artifactID)|r\(route.revision)")
        }

        static func document(identity: String) -> String {
            """
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
            </head><body>\(identity)</body></html>
            """
        }

        static func resource(
            for request: PreviewViewerRequest,
            html: String
        ) -> PreviewViewerResource {
            let data = Data(html.utf8)
            return PreviewViewerResource(
                sessionID: request.sessionID,
                artifactID: request.artifactID,
                revision: request.revision,
                data: data,
                statusCode: 200,
                mimeType: "text/html; charset=utf-8",
                sizeBytes: data.count,
                sha256: PreviewRFC8785.sha256(data: data)
            )
        }
    }

    private actor RegistrationLagViewerResolver: PreviewViewerResolver {
        nonisolated let delay: Duration
        private(set) var attempts = 0

        init(delay: Duration) {
            self.delay = delay
        }

        static let document = RoutingViewerResolver.document(identity: "replay-first-open")

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            attempts += 1
            try await Task.sleep(for: delay)
            if attempts == 1 {
                throw PreviewHTTPError(
                    traceID: "trace_fixture",
                    httpStatus: 404,
                    code: 40400,
                    error: PreviewArtifactError(
                        code: "preview_artifact_missing",
                        message: "Artifact not registered yet."
                    )
                )
            }
            return RoutingViewerResolver.resource(
                for: request,
                html: Self.document
            )
        }
    }

    private actor CountingAssetResolver: PreviewAssetResolver {
        nonisolated let delay: Duration
        private(set) var requests: [PreviewAssetRequest] = []

        init(delay: Duration) {
            self.delay = delay
        }

        func resolveContent(_ request: PreviewAssetRequest) async throws -> PreviewAssetResource {
            requests.append(request)
            try await Task.sleep(for: delay)
            guard let data = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ) else {
                throw PreviewResourceError(
                    code: "preview_asset_unavailable",
                    message: "Fixture image is unavailable."
                )
            }
            return PreviewAssetResource(
                sessionID: request.sessionID,
                artifactID: request.artifactID,
                revision: request.revision,
                assetID: request.assetID,
                data: data,
                statusCode: 200,
                mimeType: "image/png",
                sizeBytes: data.count,
                sha256: PreviewRFC8785.sha256(data: data)
            )
        }
    }
}
#endif
