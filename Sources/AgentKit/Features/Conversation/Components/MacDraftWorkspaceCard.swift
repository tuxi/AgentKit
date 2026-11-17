#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small, stable snapshot: changing selection must not move rows under the pointer.
struct MacDraftWorkspaceChoices {
    private(set) var workspaces: [Workspace] = []

    mutating func refresh(recent: [Workspace], selected: Workspace?, preserveOrder: Bool) {
        let candidates = (preserveOrder ? workspaces : []) + recent
        var seen = Set<String>()
        var result = candidates.filter { seen.insert($0.id).inserted }
        if let selected, !result.prefix(3).contains(where: { $0.id == selected.id }) {
            result = [selected] + result.filter { $0.id != selected.id }
        }
        workspaces = Array(result.prefix(3))
    }

    func subtitle(for workspace: Workspace) -> String? {
        guard workspaces.filter({ $0.name == workspace.name }).count > 1 else { return nil }
        return (workspace.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

struct MacDraftWorkspaceCard: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var choices = MacDraftWorkspaceChoices()
    @State private var showingFolderPicker = false

    private var locked: Bool {
        if case .committing = store.draft?.state { return true }
        return store.isPreparingWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if choices.workspaces.isEmpty {
                    Button { showingFolderPicker = true } label: {
                        Label("选择工作区…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MacDraftWorkspaceRowStyle())
                    .accessibilityIdentifier("draft.chooseWorkspace")
                } else {
                    ForEach(choices.workspaces) { workspace in
                        Button { choose(workspace) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name).lineLimit(1).truncationMode(.middle)
                                    if let subtitle = choices.subtitle(for: workspace) {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                                    .opacity(store.draft?.workspace?.id == workspace.id ? 1 : 0)
                            }
                            .frame(minHeight: 36)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MacDraftWorkspaceRowStyle())
                        .help(workspace.url.path)
                        .accessibilityAddTraits(store.draft?.workspace?.id == workspace.id ? .isSelected : [])
                        .accessibilityIdentifier("draft.workspace.\(workspace.id)")
                    }
                }
            }
            .padding(4)
            Divider()
            ComposerEnvironmentMenu(style: .draftCard)
                .padding(4)
        }
        .font(.system(size: 14))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .disabled(locked)
        .accessibilityIdentifier("draft.workspaceCard")
        .onAppear { refresh(preserveOrder: false) }
        .onChange(of: store.draftNavigationRevision) { _, _ in refresh(preserveOrder: false) }
        .onChange(of: store.draft?.id) { _, _ in refresh(preserveOrder: false) }
        .onChange(of: store.draft?.workspace?.id) { _, _ in refresh(preserveOrder: true) }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, !locked else { return }
            store.recentWorkspaces.beginAccess(to: url)
            choose(Workspace(url: url))
        }
    }

    private func refresh(preserveOrder: Bool) {
        choices.refresh(recent: store.recentWorkspaces.workspaces, selected: store.draft?.workspace, preserveOrder: preserveOrder)
    }

    private func choose(_ workspace: Workspace) {
        guard !locked else { return }
        // Restore an editor that had focus before this mouse click, without
        // stealing focus from keyboard navigation or triggering a send.
        let editor = NSApp.keyWindow?.firstResponder as? ComposerNSTextView
        store.selectWorkspace(workspace)
        if let editor { editor.window?.makeFirstResponder(editor) }
    }
}

private struct MacDraftWorkspaceRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(hovering || configuration.isPressed ? Color.primary.opacity(0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
#endif
