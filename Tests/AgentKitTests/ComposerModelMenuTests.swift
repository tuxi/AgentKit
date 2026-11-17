#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AgentKit

@MainActor
final class ComposerModelMenuTests: XCTestCase {
    private func descriptor(_ id: String, efforts: [ModelReasoningEffort], defaultEffort: ModelReasoningEffort?, off: Bool = false) -> UnifiedModelDescriptor {
        .init(serverConnectionID: nil, connectionID: "test", providerID: "test", providerDisplayName: "Test provider", runtimeAlias: id, wireModelID: id, displayName: id, contextWindow: 100000, supportsTools: true, supportsReasoning: !efforts.isEmpty, inputModalities: [.text, .image], billingSource: "test", supportedReasoningEfforts: efforts, canDisableReasoning: off, reasoningEffort: defaultEffort)
    }
    private func catalog() -> [UnifiedModelDescriptor] {
        [descriptor("A", efforts: [.low, .high], defaultEffort: .low, off: true),
         descriptor("B", efforts: [.medium, .max], defaultEffort: .medium)]
    }
    private func fixture(defaults: UserDefaults? = nil, catalog: [UnifiedModelDescriptor]? = nil) throws -> (WorkspaceStore, ModelSettingsStore, DraftComposerPanelViewModel, ConversationLocalStateKey) {
        let defaults = try defaults ?? XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let states = InMemoryConversationLocalStateStore()
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        store.beginDraft()
        let models = ModelSettingsStore(defaults: defaults, localStateStore: states)
        let entries = catalog ?? self.catalog()
        models.applyUnifiedCatalog(entries, defaultModelID: entries.first?.id)
        let vm = DraftComposerPanelViewModel(workspaceStore: store, modelSettings: models, conversationViewModel: nil, isDraft: true, isEnabled: true, onSend: { _, _, _ in false })
        vm.restoreLocalState(persistOutgoingText: false)
        return (store, models, vm, .draft(try XCTUnwrap(store.draft?.id)))
    }

    func testNewDraftInheritsLatestModelAndEffortAcrossWorkspaceAndRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let (firstStore, firstModels, first, _) = try fixture(defaults: defaults)
        XCTAssertEqual(first.selectedModel?.model, "A", "first installation uses catalog default")
        XCTAssertEqual(first.selectionMode, .followDefault)
        firstStore.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp/project-one", isDirectory: true)))
        first.selectModel("B", reasoningEffort: .max)
        XCTAssertEqual(firstModels.lastSelectedModel?.model, "B")

        let (newStore, reopened, next, key) = try fixture(defaults: defaults)
        newStore.selectWorkspace(Workspace(url: URL(fileURLWithPath: "/tmp/project-two", isDirectory: true)))
        XCTAssertEqual(next.selectedModel?.model, "B")
        XCTAssertEqual(next.selectedModel?.reasoningEffort, .max)
        XCTAssertEqual(next.selectionMode, .explicit)
        XCTAssertEqual(reopened.modelForNewConversation?.model, "B")
        XCTAssertEqual(try newStore.localStateStore.state(for: key)?.selectedModelID, "B")
        XCTAssertTrue(next.isCurrentModel("test/B"), "menu checks the effective model even through its wire identity")
    }

    func testEffortMemoryIsPerModelAndClampsToChangedCapabilities() throws {
        let (_, models, vm, _) = try fixture()
        vm.selectModel("A", reasoningEffort: .high)
        vm.selectModel("B", reasoningEffort: .max)
        vm.selectModel("A", reasoningEffort: nil)
        XCTAssertEqual(vm.selectedModel?.reasoningEffort, .high)
        XCTAssertEqual(models.availableReasoningEfforts(for: "A"), [.off, .low, .high])
        XCTAssertEqual(models.availableReasoningEfforts(for: "B"), [.medium, .max])
        XCTAssertNil(models.validatedReasoningEffort(.off, for: "B"))
        vm.resetReasoningEffort(for: "A")
        XCTAssertNil(vm.selectedModel?.reasoningEffort)
        XCTAssertEqual(vm.effectiveReasoningEffort(for: "A", supported: [.off, .low, .high]), .low)
        vm.selectModel("B", reasoningEffort: nil)
        XCTAssertEqual(vm.selectedModel?.reasoningEffort, .max)
        models.applyUnifiedCatalog([catalog()[0], descriptor("B", efforts: [.medium], defaultEffort: .medium)], defaultModelID: "A")
        XCTAssertNil(vm.submissionModel?.reasoningEffort, "a removed effort must not reach runtime")
        XCTAssertNil(models.rememberedReasoningEffort(for: "B"))
        vm.selectModel("B", reasoningEffort: nil)
        XCTAssertNil(vm.selectedModel?.reasoningEffort)
        XCTAssertEqual(vm.effectiveReasoningEffort(for: "B", supported: [.medium]), .medium)
    }

    func testUnavailableRecentModelFallsBackToDefaultWhenCatalogArrives() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let (_, _, first, _) = try fixture(defaults: defaults)
        first.selectModel("B", reasoningEffort: .max)
        let (store, models, next, key) = try fixture(defaults: defaults, catalog: [])
        XCTAssertNil(next.selectedModel)
        models.applyUnifiedCatalog([catalog()[0]], defaultModelID: "A")
        next.handleModelSettingsChange(newIDs: models.availableModelIDs)
        XCTAssertEqual(next.selectedModel?.model, "A")
        XCTAssertEqual(next.selectionMode, .followDefault)
        XCTAssertNil(try store.localStateStore.state(for: key)?.selectedModelID)
    }

    func testUnsentAndPendingDraftKeepOwnChoiceInsteadOfLatestGlobalModel() throws {
        let (store, models, vm, key) = try fixture()
        vm.selectModel("A", reasoningEffort: .high)
        vm.text = "保留这份草稿"
        vm.persistCurrentText()
        models.didUseModel("B", reasoningEffort: .max, conversation: "another-workspace")
        vm.restoreLocalState(persistOutgoingText: false)
        XCTAssertEqual(vm.selectedModel?.model, "A")
        XCTAssertEqual(vm.selectedModel?.reasoningEffort, .high)
        models.applyUnifiedCatalog([], defaultModelID: nil)
        vm.restoreLocalState(persistOutgoingText: false)
        XCTAssertEqual(vm.selectedModel?.model, "A", "an unloaded catalog cannot erase the saved draft choice")
        models.applyUnifiedCatalog(catalog(), defaultModelID: "A")
        vm.handleModelSettingsChange(newIDs: models.availableModelIDs)
        _ = try store.localStateStore.markSubmissionPending(key: key, input: .text(vm.text, model: "test/A", requestID: "r"))
        vm.restoreLocalState(persistOutgoingText: false)
        XCTAssertEqual(vm.selectedModel?.model, "A")
        XCTAssertTrue(vm.hasPendingSubmission)
    }

    func testEmptyRestoredDraftUsesLatestSelectionAndMenuSizeStaysBounded() async throws {
        let entries = (0..<30).map { descriptor("Model-\($0)", efforts: [.low, .medium, .high], defaultEffort: .medium) }
        let (store, models, vm, _) = try fixture(catalog: entries)
        vm.selectModel(entries[0].id, reasoningEffort: .low)
        models.didUseModel(entries[29].id, reasoningEffort: .high, conversation: "elsewhere")
        vm.restoreLocalState(persistOutgoingText: false)
        XCTAssertEqual(vm.selectedModel?.model, entries[29].id)
        XCTAssertEqual(vm.selectedModel?.reasoningEffort, .high)
        let host = NSHostingView(rootView: MacComposerModelPicker(vm: vm, onClose: {}).background(Color(nsColor: .textBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 304, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 410, "only model rows scroll; Effort stays outside the scroll view")
        _ = NSApplication.shared
        let window = ModelMenuPreviewWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 500, "opening a long menu must reveal the selected final model")
        if let path = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("model-menu.png"))
        }
        let effort = NSHostingView(rootView: MacComposerEffortPicker(values: [.low, .medium, .high], selected: .high, defaultValue: .medium, onSelect: { _ in }).background(Color(nsColor: .textBackgroundColor)))
        effort.appearance = NSAppearance(named: .aqua)
        effort.frame = NSRect(origin: .zero, size: effort.fittingSize)
        effort.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"], let rep = effort.bitmapImageRepForCachingDisplay(in: effort.bounds) {
            effort.cacheDisplay(in: effort.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("effort-menu.png"))
        }
        XCTAssertEqual(vm.effectiveReasoningEffort(for: entries[29].id, supported: [.low, .medium, .high]), .high)
        XCTAssertEqual(store.draft?.workspace?.url.path, nil)
    }
}
private final class ModelMenuPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif
