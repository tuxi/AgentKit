import Foundation
import XCTest
@testable import AgentKit

final class EmbeddedRuntimeConfigTests: XCTestCase {
    func testTaskSubagentInheritsAuthenticatedGatewayProvider() throws {
        let settingsURL = try XCTUnwrap(
            Bundle.module.url(forResource: "settings", withExtension: "json")
        )
        let data = try Data(contentsOf: settingsURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // The subagent must route through the same authenticated provider as the
        // parent. Assert the wiring instead of literal strings so renaming a
        // provider (gateway → talkify-gateway) cannot rot the test.
        let defaultModel = try XCTUnwrap(root["default_model"] as? String)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let provider = try XCTUnwrap(
            providers[defaultModel] as? [String: Any],
            "default_model must point at a configured provider"
        )
        let credential = try XCTUnwrap(provider["credential"] as? [String: Any])
        XCTAssertEqual(credential["namespace"] as? String, "gateway")
        XCTAssertEqual(credential["name"] as? String, "default")

        let credentials = try XCTUnwrap(root["credentials"] as? [String: Any])
        let gateway = try XCTUnwrap(credentials["gateway"] as? [String: Any])
        XCTAssertNotNil(gateway["default"], "the gateway credential must be injected")

        let agent = try XCTUnwrap(root["agent"] as? [String: Any])
        XCTAssertNil(
            agent["subagent_model"],
            "The iOS task subagent must inherit the authenticated parent provider."
        )
    }
}
