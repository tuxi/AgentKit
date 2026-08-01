import XCTest
@testable import AgentKit

final class InspectorEntryTests: XCTestCase {
    func testWorkbenchEntryOrderIsStable() {
        XCTAssertEqual(
            InspectorEntry.allCases,
            [.review, .terminal, .browser, .files, .sideChat]
        )
    }

    func testWorkbenchEntriesExposeLabelsAndSymbols() {
        for entry in InspectorEntry.allCases {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.systemImage.isEmpty)
        }
    }
}
