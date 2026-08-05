import Foundation
import XCTest
@testable import AgentKit

final class EmbeddedRuntimeConfigTests: XCTestCase {
    func testTaskSubagentInheritsAuthenticatedGatewayProvider() throws {
        let settingsURL = try XCTUnwrap(
            Bundle.module.url(forResource: "settings", withExtension: "json")
        )
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(settings.contains("\"default_model\": \"gateway\""))
        XCTAssertTrue(settings.contains("\"namespace\": \"gateway\""))
        XCTAssertTrue(settings.contains("\"name\": \"default\""))
        XCTAssertFalse(
            settings.contains("subagent_model"),
            "The iOS task subagent must inherit the authenticated parent provider."
        )
    }
}
