import XCTest
@testable import AgentKit

@MainActor final class WorkspaceReviewNavigationTests: XCTestCase {
    func testLegacyHostKeepsExistingInspectorWhenReviewNavigationUnavailable() {
        let store = WorkspaceStore(); store.showInspector(.todo("detail"))
        XCTAssertFalse(store.openWorkspaceChanges(path: "a.swift"))
        XCTAssertEqual(store.inspectorSelection, .todo("detail"))
        XCTAssertNil(store.inspectorWorkspaceState.reviewOpenRequest)
    }
    func testReviewEntryCreatesScopedRequestAndReusesItsTab() {
        let store = WorkspaceStore(); store.workspaceReviewNavigationEnabled = true
        store.workspaceFileNavigationContext = "runtime|conversation|repository"
        XCTAssertTrue(store.openWorkspaceChanges(path: "Sources/A.swift"))
        let first = store.inspectorWorkspaceState.reviewOpenRequest
        XCTAssertEqual(first?.path, "Sources/A.swift"); XCTAssertEqual(first?.contextID, "runtime|conversation|repository")
        XCTAssertEqual(store.inspectorWorkspaceState.selectedTab?.entry, .review)
        XCTAssertTrue(store.isInspectorPresented); XCTAssertNil(store.inspectorSelection)
        XCTAssertTrue(store.openWorkspaceChanges())
        XCTAssertNotEqual(first?.id, store.inspectorWorkspaceState.reviewOpenRequest?.id)
        XCTAssertEqual(store.inspectorWorkspaceState.tabs.count, 1)
    }
    func testClosingOrOpeningAnotherDetailCancelsPendingReviewEntry() {
        let store = WorkspaceStore(); store.workspaceReviewNavigationEnabled = true
        _ = store.openWorkspaceChanges(path: "A.swift"); store.isInspectorPresented = false
        XCTAssertNil(store.inspectorWorkspaceState.reviewOpenRequest)
        _ = store.openWorkspaceChanges(); store.showInspector(.todo("other"))
        XCTAssertNil(store.inspectorWorkspaceState.reviewOpenRequest)
        XCTAssertEqual(store.inspectorSelection, .todo("other"))
    }
}
