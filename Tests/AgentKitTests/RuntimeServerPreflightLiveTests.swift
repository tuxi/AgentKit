//
//  RuntimeServerPreflightLiveTests.swift
//  AgentKitTests
//
//  Opt-in live acceptance for a no-auth loopback Runtime Server. The test is
//  skipped unless AGENTKIT_LIVE_RUNTIME_ENDPOINT points at a running runtime.
//

#if os(macOS)
import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class RuntimeServerPreflightLiveTests: XCTestCase {
    func testNoAuthLoopbackCatalogSucceeds() async throws {
        guard let raw = ProcessInfo.processInfo.environment[
            "AGENTKIT_LIVE_RUNTIME_ENDPOINT"
        ], let endpoint = URL(string: raw) else {
            throw XCTSkip("AGENTKIT_LIVE_RUNTIME_ENDPOINT is not set")
        }
        let service = RuntimeServerPreflightService(platform: .macOS)
        let result = try await service.test(
            endpoint: endpoint,
            authentication: .none,
            accessToken: nil
        )
        XCTAssertEqual(result.kind, .local)
        XCTAssertTrue(result.modelCatalog.hasSupportedSchema)
        XCTAssertFalse(result.modelCatalog.connections.isEmpty)
        XCTAssertTrue(
            result.modelCatalog.connections.contains {
                !$0.models.isEmpty
            }
        )
    }
}
#endif
