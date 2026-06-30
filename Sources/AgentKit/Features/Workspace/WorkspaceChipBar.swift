//
//  WorkspaceChipBar.swift
//  AgentKit
//
//  P5.0 — 输入框上方的工作区 chip 行（对齐 Claude Code 的 [Local] [📁 folder] [⎇ branch]）。
//  三态：
//    • 草稿无工作区 → 醒目的「Select Workspace ▾」
//    • 草稿已选工作区 → chip 可改（下拉换项 / Open folder…）
//    • 活跃会话 → chip 只读（冻结，无下拉）
//

import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceChipBar: View {

    @Environment(WorkspaceStore.self) private var store
    @State private var isImporterPresented = false
    @State private var isNewProjectPresented = false
    @State private var newProjectName = ""
    @State private var createError: String?

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { store.projects.reload() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("New Project", isPresented: $isNewProjectPresented) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { }
            Button("Create") { createProject() }
        } message: {
            Text("在 Documents 下创建一个新项目目录。")
        }
        .alert(
            "无法创建项目",
            isPresented: Binding(get: { createError != nil },
                                 set: { if !$0 { createError = nil } })
        ) {
            Button("好", role: .cancel) { createError = nil }
        } message: {
            Text(createError ?? "")
        }
    }

    // MARK: - Mode

    private enum Mode {
        case draftEmpty
        case draftReady(Workspace)
        case committing(Workspace)
        case frozen(name: String, branch: String?)
        case hidden
    }

    private var mode: Mode {
        if let draft = store.draft {
            if case .committing = draft.state, let ws = draft.workspace {
                return .committing(ws)
            }
            if let ws = draft.workspace { return .draftReady(ws) }
            return .draftEmpty
        }
        if let vm = store.activeConversationViewModel, let name = vm.workspaceDisplayName {
            return .frozen(name: name, branch: vm.workspace?.branch)
        }
        return .hidden
    }

    /// 仅在草稿或带工作区的活跃会话时才占位。
    var isVisible: Bool {
        if case .hidden = mode { return false }
        return true
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .draftEmpty:
            workspaceMenu {
                chip(icon: "folder.badge.plus", text: "Select Workspace",
                     prominent: true, showsChevron: true)
            }

        case .draftReady(let ws):
            localChip
            workspaceMenu {
                chip(icon: "folder", text: ws.name, showsChevron: true)
            }
            if let branch = ws.branch {
                chip(icon: "arrow.triangle.branch", text: branch)
            }

        case .committing(let ws):
            localChip
            chip(icon: "folder", text: ws.name)
            ProgressView().controlSize(.small)

        case .frozen(let name, let branch):
            localChip
            chip(icon: "folder", text: name)          // 只读，无下拉
            if let branch {
                chip(icon: "arrow.triangle.branch", text: branch)
            }

        case .hidden:
            EmptyView()
        }
    }

    private var localChip: some View {
        chip(icon: "desktopcomputer", text: "Local")
    }

    // MARK: - Workspace menu (recents + open folder)

    private func workspaceMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            if !store.recentWorkspaces.workspaces.isEmpty {
                Section("Recent") {
                    ForEach(store.recentWorkspaces.workspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            if store.projects.isAvailable {
                // iOS：Documents 项目列表（排除已在 Recent 中的，避免重复）。
                let recentIDs = Set(store.recentWorkspaces.workspaces.map(\.id))
                let others = store.projects.projects.filter { !recentIDs.contains($0.id) }
                if !others.isEmpty {
                    Section("Projects") {
                        ForEach(others) { ws in
                            workspaceButton(ws)
                        }
                    }
                }
                Divider()
                Button {
                    newProjectName = ""
                    isNewProjectPresented = true
                } label: {
                    Label("New Project…", systemImage: "folder.badge.plus")
                }
            } else {
                // macOS：无工作区根 → 任意文件夹选择。
                Divider()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func workspaceButton(_ ws: Workspace) -> some View {
        Button {
            store.selectWorkspace(ws)
        } label: {
            Label(ws.name, systemImage: "folder")
        }
    }

    private func createProject() {
        do {
            try store.createAndSelectProject(named: newProjectName)
        } catch {
            createError = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // 取得 security-scoped 访问，生命周期统一交给 RecentWorkspacesStore 管理
        // （进入 recents 即持有、被挤出/退出时释放）。先行 begin 以便 Workspace.init
        // 能读取 .git/HEAD；selectWorkspace → touch 会再次 begin（幂等）。
        store.recentWorkspaces.beginAccess(to: url)
        store.selectWorkspace(Workspace(url: url))
    }

    // MARK: - Chip

    private func chip(
        icon: String,
        text: String,
        prominent: Bool = false,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            prominent
                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                : AnyShapeStyle(.quaternary)
        )
        .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .clipShape(Capsule())
    }
}
