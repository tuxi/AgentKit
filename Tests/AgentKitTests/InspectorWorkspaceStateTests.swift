import XCTest
@testable import AgentKit

@MainActor
final class InspectorWorkspaceStateTests: XCTestCase {
    func testOpeningEntriesCreatesReusableIndependentTabs() {
        let state = InspectorWorkspaceState(conversationID: "conversation-a")

        let terminal = state.open(.terminal)
        terminal.pathState.push(.filePreview(filePath: "terminal.log"))
        let browser = state.open(.browser)
        browser.pathState.push(.filePreview(filePath: "browser.html"))

        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.selectedTab?.entry, .browser)
        XCTAssertNotEqual(terminal.session.id, browser.session.id)
        XCTAssertEqual(terminal.pathState.path, [.filePreview(filePath: "terminal.log")])
        XCTAssertEqual(browser.pathState.path, [.filePreview(filePath: "browser.html")])

        let reopenedTerminal = state.open(.terminal)
        XCTAssertTrue(reopenedTerminal === terminal)
        XCTAssertEqual(reopenedTerminal.session.id, terminal.session.id)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.selectedTab?.entry, .terminal)
    }

    func testClosingSelectedTabSelectsNeighborAndLandingPreservesTabs() {
        let state = InspectorWorkspaceState()
        let review = state.open(.review)
        let files = state.open(.files)
        let browser = state.open(.browser)

        state.close(tabID: files.id)
        XCTAssertEqual(state.selectedTab?.id, browser.id)

        state.showLanding()
        XCTAssertNil(state.selectedTabID)
        XCTAssertEqual(state.tabs.map(\.id), [review.id, browser.id])

        state.close(tabID: review.id)
        XCTAssertNil(state.selectedTabID)
        XCTAssertEqual(state.tabs.map(\.id), [browser.id])
    }

    func testWorkspaceStoreRestoresInspectorStatePerConversation() {
        let store = WorkspaceStore()
        let first = ConversationRef(id: "inspector-a", workspacePath: "/tmp/a")
        let second = ConversationRef(id: "inspector-b", workspacePath: "/tmp/b")

        store.selectedConversation = first
        let firstState = store.inspectorWorkspaceState
        let firstTab = firstState.open(.terminal)
        firstTab.pathState.push(.filePreview(filePath: "a.txt"))
        store.showInspector(.todo("first selection"))

        store.selectedConversation = second
        let secondState = store.inspectorWorkspaceState
        XCTAssertFalse(firstState === secondState)
        XCTAssertFalse(store.isInspectorPresented)
        XCTAssertNil(store.inspectorSelection)
        XCTAssertTrue(secondState.tabs.isEmpty)

        secondState.open(.browser)
        store.selectedConversation = first

        XCTAssertTrue(store.inspectorWorkspaceState === firstState)
        XCTAssertTrue(store.isInspectorPresented)
        XCTAssertEqual(store.inspectorSelection, .todo("first selection"))
        XCTAssertEqual(store.inspectorWorkspaceState.selectedTab?.entry, .terminal)
        XCTAssertEqual(firstTab.pathState.path, [.filePreview(filePath: "a.txt")])
    }

    func testHidingInspectorDropsTransientSelectionButPreservesTabSession() {
        let store = WorkspaceStore()
        store.selectedConversation = ConversationRef(
            id: "inspector-hide",
            workspacePath: "/tmp/hide"
        )
        let terminal = store.inspectorWorkspaceState.open(.terminal)
        terminal.session.hostResourceID = "pty-1"
        terminal.session.selectedFilePath = "output.log"
        terminal.session.selectedReviewFilePath = "Sources/Changed.swift"
        terminal.pathState.push(.filePreview(filePath: "output.log"))
        store.showInspector(.todo("temporary detail"))

        store.isInspectorPresented = false

        XCTAssertNil(store.inspectorSelection)
        XCTAssertFalse(store.inspectorWorkspaceState.isPresented)
        XCTAssertTrue(store.inspectorWorkspaceState.selectedTab === terminal)
        XCTAssertEqual(terminal.session.hostResourceID, "pty-1")
        XCTAssertEqual(terminal.session.selectedFilePath, "output.log")
        XCTAssertEqual(terminal.session.selectedReviewFilePath, "Sources/Changed.swift")
        XCTAssertEqual(terminal.pathState.path, [.filePreview(filePath: "output.log")])
    }
}
