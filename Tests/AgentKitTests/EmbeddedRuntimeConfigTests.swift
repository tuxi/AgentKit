import Foundation
import XCTest
@testable import AgentKit

final class EmbeddedRuntimeConfigTests: XCTestCase {
    func testTaskSubagentInheritsAuthenticatedGatewayProvider() throws {
        let configURL = try XCTUnwrap(
            Bundle.module.url(forResource: "config", withExtension: "yaml")
        )
        let config = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertTrue(config.contains("default_model: gateway"))
        XCTAssertTrue(config.contains("namespace: gateway"))
        XCTAssertTrue(config.contains("name: default"))
        XCTAssertFalse(
            config.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("subagent_model:")
            },
            "The iOS task subagent must inherit the authenticated parent provider."
        )
    }
}
