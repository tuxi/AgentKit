#if os(macOS)
import XCTest
@testable import AgentKit

@MainActor
final class ComposerDraftAcceptanceTests: XCTestCase {
    private func fixture() throws -> (WorkspaceStore, ModelSettingsStore, ConversationLocalStateKey) {
        let states = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
        let model = UnifiedModelDescriptor(serverConnectionID: nil, connectionID: "test", providerID: "test", providerDisplayName: "Test", runtimeAlias: "text", wireModelID: "text", displayName: "Text", contextWindow: 100000, supportsTools: true, supportsReasoning: false, inputModalities: [.text], billingSource: "test")
        models.applyUnifiedCatalog([model], defaultModelID: model.id)
        return (store, models, .draft(try XCTUnwrap(store.draft?.id)))
    }

    func testLiveSendClearsAcceptedRawMultilineDraft() async throws {
        for raw in ["正文\n\n", "\n\t这是多行内容\n\n应用类型\n来源\n\n协议\n端口\n\n备注\n操作\n\t  ", "\r\n正文\r\n"] {
            let (store, models, key) = try fixture()
            let accepted = expectation(description: "accepted")
            var vm: DraftComposerPanelViewModel!
            vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { text, _, _ in
                XCTAssertEqual(text, raw.trimmingCharacters(in: .whitespacesAndNewlines))
                do {
                    let snapshot = try store.localStateStore.markSubmissionPending(key: key, input: .text(text, requestID: "r"))
                    XCTAssertEqual(snapshot.draftText, raw)
                    try store.localStateStore.acceptSubmission(key: key, requestID: "r", turnID: "t")
                    vm.reconcileAcceptedSubmission()
                } catch { XCTFail("submission failed: \(error)") }
                accepted.fulfill()
                return true
            })
            vm.restoreLocalState(persistOutgoingText: false)
            vm.text = raw
            vm.send()
            await fulfillment(of: [accepted], timeout: 2)
            for _ in 0..<100 where vm.isSending { await Task.yield() }
            XCTAssertEqual(vm.text, "", "accepted editor content must clear even when wire text was trimmed")
            XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, "", "stale editor text must not resurrect the persisted draft")
            XCTAssertFalse(vm.hasPendingSubmission)
        }
    }

    func testLocalDeliveryAcceptanceFlushesNextDraftBeforeAutosave() async throws {
        let (store, models, key) = try fixture()
        let finished = expectation(description: "local delivery accepted")
        var vm: DraftComposerPanelViewModel!
        vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models,
            conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { text, _, _ in
                do {
                    let record = try store.beginLocalSubmission(key: key, text: text, model: nil, effort: nil)
                    vm.reconcileLocalSubmission()
                    XCTAssertEqual(vm.text, "")
                    vm.text = "尚未自动保存的下一条"
                    vm.scheduleTextSave(vm.text, for: key)
                    _ = try store.localStateStore.markSubmissionPending(key: key, input: record.input)
                    try store.localStateStore.acceptSubmission(key: key, requestID: record.id, turnID: "t")
                    vm.reconcileAcceptedSubmission()
                    XCTAssertEqual(vm.text, "尚未自动保存的下一条")
                    XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, vm.text)
                } catch { XCTFail("\(error)") }
                finished.fulfill()
                return true
            })
        vm.restoreLocalState(persistOutgoingText: false)
        vm.text = "已提交的内容"
        vm.send()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testRejectedLiveSendKeepsExactRawTextWithoutDuplicatePrefix() async throws {
        let (store, models, key) = try fixture()
        let dispatched = expectation(description: "dispatched")
        let raw = "\n  第一行\n\n第二行\t\n\n"
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _, _, _ in dispatched.fulfill(); return false })
        vm.restoreLocalState(persistOutgoingText: false)
        vm.text = raw
        vm.send()
        await fulfillment(of: [dispatched], timeout: 2)
        for _ in 0..<100 where vm.isSending { await Task.yield() }
        XCTAssertEqual(vm.text, raw)
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, raw)
    }

    func testLiveAcceptancePreservesDifferentNextDraftIncludingWhitespace() async throws {
        let (store, models, key) = try fixture()
        let accepted = expectation(description: "accepted")
        let raw = "\n第一条\n\n"
        let next = "  下一条草稿\n\n"
        var vm: DraftComposerPanelViewModel!
        vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { text, _, _ in
            do {
                _ = try store.localStateStore.markSubmissionPending(key: key, input: .text(text, requestID: "r"))
                vm.text = next
                vm.persistCurrentText()
                try store.localStateStore.acceptSubmission(key: key, requestID: "r", turnID: "t")
                vm.reconcileAcceptedSubmission()
            } catch { XCTFail("submission failed: \(error)") }
            accepted.fulfill()
            return true
        })
        vm.restoreLocalState(persistOutgoingText: false)
        vm.text = raw
        vm.send()
        await fulfillment(of: [accepted], timeout: 2)
        for _ in 0..<100 where vm.isSending { await Task.yield() }
        XCTAssertEqual(vm.text, next)
        XCTAssertEqual(try store.localStateStore.state(for: key)?.composerDraft.text, next)
    }
}
#endif
