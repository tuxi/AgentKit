import XCTest
import SwiftUI
import ClientToolProtocol
@testable import AgentKit

@MainActor final class WorkspaceFileNavigationTests: XCTestCase {
    func testLiveAssetsKeepLineAndWorkspaceButImmutableAndDownloadResourcesDoNotRoute() {
        let asset = AgentAssetRef(id: "live", kind: "file_location", workspaceID: "workspace", workspaceRelativePath: "Sources/A.swift", range: .init(startLine: 42))
        let request = WorkspaceFileOpenRequest.liveAsset(asset)
        XCTAssertEqual(request?.path, "Sources/A.swift"); XCTAssertEqual(request?.line, 42)
        XCTAssertEqual(request?.workspaceID, "workspace")
        for uri in ["artifact://revision/1", "https://example.com/download", "mcp://resource/1", "file://another-machine/README.md"] {
            XCTAssertNil(WorkspaceFileOpenRequest.liveAsset(.init(id: uri, kind: "file", uri: uri, workspaceRelativePath: "same.md")))
        }
        XCTAssertNil(WorkspaceFileOpenRequest.liveAsset(.init(id: "name-only", kind: "file", displayName: "looks-like-a-file.swift")))
    }
    func testHostCapabilityPreservesLegacyInspectorAndExplicitVersionViewer() {
        let store = WorkspaceStore()
        let file = FilePayload(filePath: "a.swift", content: "historical", language: "swift")
        store.showInspector(.file(file))
        XCTAssertEqual(store.inspectorSelection, .file(file)); XCTAssertNil(store.inspectorWorkspaceState.fileOpenRequest)
        store.workspaceFileNavigationEnabled = true; store.workspaceFileNavigationContext = "runtime-a|conversation-a|root-a"
        store.showInspector(.file(file))
        XCTAssertNil(store.inspectorSelection)
        XCTAssertEqual(store.inspectorWorkspaceState.selectedTab?.entry, .files)
        XCTAssertEqual(store.inspectorWorkspaceState.fileOpenRequest?.contextID, "runtime-a|conversation-a|root-a")
        let firstID = store.inspectorWorkspaceState.fileOpenRequest?.id
        store.showInspector(.file(file))
        XCTAssertNotEqual(firstID, store.inspectorWorkspaceState.fileOpenRequest?.id)
        store.showInspector(.file(file), preferWorkspaceFile: false)
        XCTAssertEqual(store.inspectorSelection, .file(file))
        XCTAssertNil(store.inspectorWorkspaceState.fileOpenRequest)
        _ = store.openWorkspaceFile(path: "b.swift")
        store.isInspectorPresented = false
        XCTAssertNil(store.inspectorWorkspaceState.fileOpenRequest)
    }
    func testOutputsRouteOnlyLiveNonDeletedWorkspaceFiles() throws {
        func output(mode: String, state: String) throws -> SessionRailOutput {
            let body: [String: Any] = ["output_id": "o1", "title": "readme", "kind": "file", "relative_path": "README.md", "content_mode": mode, "state": state, "availability": "not_checked", "version_count": 1,
                "latest": ["evidence": "tool_write_report", "turn_id": "t1", "call_id": "c1", "sequence": 1, "updated_at": "", "operation": "modified"]]
            return try JSONDecoder().decode(SessionRailOutput.self, from: JSONSerialization.data(withJSONObject: body))
        }
        XCTAssertEqual(try output(mode: "live_workspace", state: "recorded").workspaceFileRequest?.path, "README.md")
        XCTAssertNil(try output(mode: "live_workspace", state: "deleted").workspaceFileRequest)
        XCTAssertNil(try output(mode: "immutable", state: "recorded").workspaceFileRequest)
    }
    func testAssetFromAnotherWorkspaceDoesNotOpenCurrentFiles() {
        let store = WorkspaceStore(); store.workspaceFileNavigationEnabled = true
        XCTAssertFalse(store.openWorkspaceFile(.init(path: "README.md", workspaceID: "other-workspace")))
        XCTAssertNil(store.inspectorWorkspaceState.fileOpenRequest)
    }
    #if os(macOS)
    func testConversationPathAndFileURLUseFilesInsteadOfClipboardOrExternalApp() {
        let store = WorkspaceStore(); store.workspaceFileNavigationEnabled = true
        let turn = ConversationTurn(id: "turn", userPrompt: nil, blocks: [], footer: nil, isLive: false)
        var externalOpened = false
        let dispatcher = TurnActionDispatcher(turn: turn, store: store, openURL: .init { _ in externalOpened = true; return .handled })
        dispatcher.handle(.openPath("Sources/A.swift:42"))
        XCTAssertEqual(store.inspectorWorkspaceState.fileOpenRequest?.path, "Sources/A.swift:42")
        dispatcher.handle(.openAsset(.init(display: "A", kind: .filePath, target: "Sources/A.swift", turnID: "turn")))
        XCTAssertEqual(store.inspectorWorkspaceState.fileOpenRequest?.path, "Sources/A.swift")
        dispatcher.handle(.openURL("file:///workspace/Sources/A.swift#L42"))
        XCTAssertEqual(store.inspectorWorkspaceState.fileOpenRequest?.path, "file:///workspace/Sources/A.swift#L42")
        XCTAssertFalse(externalOpened)
    }
    #endif
    func testNavigationRequestsStayWithTheirConversation() {
        let store = WorkspaceStore(); store.workspaceFileNavigationEnabled = true
        store.selectedConversation = .init(id: "a", workspacePath: "/tmp/a")
        _ = store.openWorkspaceFile(path: "a.md", line: 2)
        let firstState = store.inspectorWorkspaceState
        store.selectedConversation = .init(id: "b", workspacePath: "/tmp/b")
        XCTAssertNil(store.inspectorWorkspaceState.fileOpenRequest)
        XCTAssertEqual(firstState.fileOpenRequest?.path, "a.md")
    }
}
