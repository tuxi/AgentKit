#if os(macOS)
import AppKit
import SwiftUI

/// Native title editing and NSMenu actions inside the host's split header.
public struct MacConversationToolbarTitle: View {
    @Environment(WorkspaceStore.self) private var store
    private let conversation: ConversationRef
    private let allowsFinderReveal: Bool
    private let onInteraction: () -> Void
    @State private var editor = MacConversationTitleEditor()
    @State private var deletionTarget: ConversationRef?
    @State private var forcedDeletion: ToolbarWorktreeDeletion?
    @State private var actionError: String?
    @State private var deleting = false

    public init(conversation: ConversationRef, allowsFinderReveal: Bool, onInteraction: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.allowsFinderReveal = allowsFinderReveal
        self.onInteraction = onInteraction
    }

    private var current: ConversationRef {
        // ConversationRef equality intentionally compares IDs, so names are
        // invalidated by the list's explicit presentation revision.
        _ = store.listViewModel.revision
        return store.listViewModel.conversations.first { $0.id == conversation.id }
            ?? store.listViewModel.archivedConversations.first { $0.id == conversation.id }
            ?? store.selectedConversation.flatMap { $0.id == conversation.id ? $0 : nil }
            ?? conversation
    }

    private var title: String { current.displayTitle }
    private var busy: Bool { editor.isSaving || deleting }

    public var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let preferred = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
            HStack(spacing: 4) {
                if editor.target != nil {
                    MacConversationNameField(text: $editor.text, isSaving: editor.isSaving,
                        focusRevision: editor.focusRevision,
                        onCommit: { saveName() }, onCancel: { editor.cancel() })
                        .frame(width: min(max(0, width - (editor.isSaving ? 24 : 0)), max(180, min(360, preferred + 24))), height: 28)
                    if editor.isSaving { ProgressView().controlSize(.small).frame(width: 20) }
                } else {
                    Button { beginRename() } label: {
                        Text(title)
                            .font(.system(size: 14))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .frame(width: min(max(0, width - 28), preferred + 4))
                    .help(title + " · 点击重命名")
                    .accessibilityLabel("重命名对话：\(title)")
                    .accessibilityIdentifier("conversation.title.rename")
                    actionsMenu
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 28, alignment: .leading)
        }
        .frame(minWidth: 40, maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .alert(editor.errorMessage != nil ? "无法重命名" : "无法完成操作", isPresented: Binding(
            get: { editor.errorMessage != nil || actionError != nil },
            set: { if !$0 { clearError() } }
        )) {
            Button("好", role: .cancel) { clearError() }
        } message: { Text(editor.errorMessage ?? actionError ?? "") }
        .confirmationDialog(deletionTarget?.worktree?.managed == true ? "删除任务和 Worktree？" : "删除任务？",
            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible) {
            if let target = deletionTarget {
                if target.worktree?.managed == true {
                    Button("仅删除任务，保留 Worktree", role: .destructive) { delete(target, disposition: .keep) }
                    Button("删除任务和 Worktree", role: .destructive) { delete(target, disposition: .remove) }
                } else {
                    Button("删除任务", role: .destructive) { delete(target, disposition: .keep) }
                }
                Button("取消", role: .cancel) { deletionTarget = nil }
            }
        } message: {
            Text(deletionTarget?.worktree?.managed == true
                ? "Worktree 可能包含未保存的更改。删除 Worktree 前会执行安全检查，Git 分支不会被删除。"
                : "此操作会永久删除任务及其事件历史，无法撤销。工作区文件会保留。")
        }
        .alert("Worktree 包含未保存的更改", isPresented: Binding(
            get: { forcedDeletion != nil }, set: { if !$0 { forcedDeletion = nil } }), presenting: forcedDeletion) { item in
            Button("取消", role: .cancel) { forcedDeletion = nil }
            Button("强制删除 Worktree 和任务", role: .destructive) { delete(item.conversation, disposition: .remove, force: true) }
        } message: { item in Text(item.message) }
    }

    private var actionsMenu: some View {
        Menu {
            Menu("Open in") {
                Button("Show in Finder") { revealWorkspace() }
                    .disabled(!allowsFinderReveal || !current.workspacePath.hasPrefix("/"))
            }
            .disabled(!allowsFinderReveal || !current.workspacePath.hasPrefix("/"))
            Button("Rename") { beginRename() }
            Divider()
            Button("Delete", role: .destructive) { onInteraction(); deletionTarget = current }
                .disabled(!store.canDeleteConversation(current) || store.listViewModel.deletingConversationIDs.contains(current.id))
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("对话菜单")
        .accessibilityLabel("对话菜单")
        .accessibilityIdentifier("conversation.title.menu")
        .simultaneousGesture(TapGesture().onEnded { onInteraction() })
    }

    private func beginRename() {
        guard !busy else { return }
        onInteraction()
        editor.begin(current)
    }

    private func saveName() {
        Task { @MainActor in
            await editor.save(rename: { target, name in await store.renameConversation(target, name: name) },
                              failure: { store.listViewModel.errorMessage ?? "未能保存名称，请重试。" })
        }
    }

    private func clearError() {
        if editor.errorMessage != nil { editor.dismissError() }
        actionError = nil
    }

    private func revealWorkspace() {
        onInteraction()
        guard allowsFinderReveal, current.workspacePath.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: current.workspacePath, isDirectory: true)
        Task { @MainActor in
            let exists = await Task.detached(priority: .userInitiated) { (try? url.checkResourceIsReachable()) == true }.value
            guard exists else { actionError = "工作区目录不存在或当前无法访问。"; return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func delete(_ target: ConversationRef, disposition: ConversationWorktreeDisposition, force: Bool = false) {
        guard !deleting else { return }
        deletionTarget = nil
        forcedDeletion = nil
        deleting = true
        Task { @MainActor in
            defer { deleting = false }
            do {
                try await store.deleteConversation(target, worktreeDisposition: disposition, forceWorktreeRemoval: force)
            } catch let error as ManagedWorktreeRemovalError where error.isDirtyConflict && !force {
                forcedDeletion = ToolbarWorktreeDeletion(conversation: target, summary: error.summary)
            } catch { actionError = error.localizedDescription }
        }
    }
}

private struct ToolbarWorktreeDeletion {
    let conversation: ConversationRef
    let summary: ManagedWorktreeDirtySummary?
    var message: String {
        guard let summary else { return "检测到可能丢失的更改。强制删除会永久移除 checkout，但保留 Git 分支。" }
        return "检测到 \(summary.modifiedFiles) 个已修改文件、\(summary.untrackedFiles) 个未跟踪文件和 \(summary.newCommits) 个新提交。强制删除会永久移除 checkout，但保留 Git 分支。"
    }
}
#endif
