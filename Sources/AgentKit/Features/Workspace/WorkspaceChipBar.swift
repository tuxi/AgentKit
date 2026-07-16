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
    // 导入命名（iOS copy-in）：picker 选完后暂存源 URL，弹命名框确认后再复制。
    @State private var pendingImportURL: URL?
    @State private var importName = ""
    @State private var isImportNamePresented = false
    // Runtime-owned Public Git Clone v1.
    @State private var isGitClonePresented = false
    @State private var cloneTask: Task<Void, Never>?
    @State private var cloneError: String?

    var body: some View {
        HStack(spacing: 6) {
            content
            if store.isPreparingWorkspace {
                ProgressView().controlSize(.small)
                Text("准备工作区…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .sheet(isPresented: $isGitClonePresented) {
            PublicGitCloneSheet(
                projectsRoot: store.runtimeProjectsRoot,
                isCloning: cloneTask != nil,
                errorMessage: cloneError,
                onCancel: {
                    cloneTask?.cancel()
                    isGitClonePresented = false
                },
                onClone: { form in
                    startClone(form)
                }
            )
        }
        .alert("为项目命名", isPresented: $isNewProjectPresented) {
            TextField("Project name", text: $newProjectName)
            Button("取消", role: .cancel) { }
            Button("创建") { createProject() }
        } message: {
            #if os(macOS)
            Text("将在文稿中创建一个新项目，并初始化 Git 仓库。")
            #else
            Text("将在 Documents 下创建一个新项目目录。")
            #endif
        }
        .alert("导入文件夹", isPresented: $isImportNamePresented) {
            TextField("项目名", text: $importName)
            Button("取消", role: .cancel) { pendingImportURL = nil }
            Button("导入") { confirmImport() }
        } message: {
            Text("将复制进 Documents。可改名以区分不同来源（iOS 无法自动获取来源 App 名）。")
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
        case frozen(name: String, branch: String?, worktree: ManagedWorktreeMetadata?)
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
            return .frozen(
                name: name,
                branch: vm.managedWorktree?.branch ?? vm.workspace?.branch,
                worktree: vm.managedWorktree
            )
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
            managedWorktreeControl

        case .committing(let ws):
            localChip
            chip(icon: "folder", text: ws.name)
            if store.draft?.usesManagedWorktree == true {
                chip(icon: "square.stack.3d.up.fill", text: "Worktree", prominent: true)
            }
            ProgressView().controlSize(.small)

        case .frozen(let name, let branch, let worktree):
            localChip
            chip(icon: "folder", text: name)          // 只读，无下拉
            if let branch {
                chip(icon: "arrow.triangle.branch", text: branch)
            }
            if let worktree {
                chip(
                    icon: worktree.requiresAttention
                        ? "exclamationmark.triangle.fill"
                        : "square.stack.3d.up.fill",
                    text: worktree.requiresAttention ? worktreeStateTitle(worktree) : "Worktree",
                    prominent: worktree.requiresAttention
                )
            }

        case .hidden:
            EmptyView()
        }
    }

    private var localChip: some View {
        chip(icon: "desktopcomputer", text: "Local")
    }

    private var managedWorktreeMenu: some View {
        let enabled = store.draft?.usesManagedWorktree == true
        return Menu {
            Button {
                store.setDraftManagedWorktreeEnabled(!enabled)
            } label: {
                Label(
                    enabled ? "使用主工作区" : "使用独立 Worktree",
                    systemImage: enabled ? "square" : "checkmark.square"
                )
            }

            if enabled {
                Divider()
                Button {
                    store.setDraftManagedWorktreeBaseRef(.head)
                } label: {
                    Label(
                        "从当前 HEAD 创建",
                        systemImage: store.draft?.managedWorktreeBaseRef == .head
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
                Button {
                    store.setDraftManagedWorktreeBaseRef(.fresh)
                } label: {
                    Label(
                        "从远端默认分支创建",
                        systemImage: store.draft?.managedWorktreeBaseRef == .fresh
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
            }
        } label: {
            chip(
                icon: enabled ? "checkmark.square.fill" : "square",
                text: "独立 Worktree",
                prominent: enabled,
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.isPreparingWorkspace)
    }

    @ViewBuilder
    private var managedWorktreeControl: some View {
        if store.supportsManagedWorktreeCreation {
            managedWorktreeMenu
        } else {
            let isLoading = store.runtimeCapabilityDiscoveryState == .idle
                || store.runtimeCapabilityDiscoveryState == .loading
            let canRetry = store.runtimeCapabilityDiscoveryState == .unavailable
            Button {
                guard canRetry else { return }
                Task { await store.refreshRuntimeState() }
            } label: {
                chip(
                    icon: isLoading ? "ellipsis.circle" : "exclamationmark.triangle",
                    text: isLoading ? "Worktree 检测中" : "Worktree 不可用"
                )
            }
            .buttonStyle(.plain)
            .disabled(!canRetry || store.isPreparingWorkspace)
            .help(worktreeUnavailableHelp)
        }
    }

    private var worktreeUnavailableHelp: String {
        switch store.runtimeCapabilityDiscoveryState {
        case .idle, .loading:
            return "正在读取 Runtime 的托管 Worktree 能力。"
        case .available:
            return "当前 Runtime 未声明 managed_worktree_v1 和 workspace_execution_policy_v1。"
        case .unavailable:
            return store.runtimeCapabilityErrorMessage.map {
                "无法读取 Runtime 能力：\($0)。点击重试。"
            } ?? "无法读取 Runtime 能力。点击重试。"
        }
    }

    private func worktreeStateTitle(_ worktree: ManagedWorktreeMetadata) -> String {
        if worktree.needsRebind || worktree.state == "missing" { return "Worktree 不可用" }
        if worktree.state == "remove_failed" { return "清理失败" }
        if worktree.state == "failed" { return "创建失败" }
        return worktree.state
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
                Menu {
                    Button {
                        newProjectName = "New Project"
                        isNewProjectPresented = true
                    } label: {
                        Label("新建空白项目…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        isImporterPresented = true
                    } label: {
                        #if os(macOS)
                        Label("使用现有文件夹…", systemImage: "folder")
                        #else
                        Label("导入现有文件夹…", systemImage: "square.and.arrow.down")
                        #endif
                    }
                    if store.supportsPublicGitClone {
                        Button {
                            cloneError = nil
                            isGitClonePresented = true
                        } label: {
                            Label("从 Git 仓库克隆…", systemImage: "arrow.down.circle")
                        }
                    }
                } label: {
                    Label("新建项目", systemImage: "plus")
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
        .disabled(store.isPreparingWorkspace)   // clone/import 进行中禁止再选目录
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

    private func confirmImport() {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        let name = importName
        Task {
            do {
                try await store.importAndSelectProject(from: url, named: name)
            } catch {
                createError = error.localizedDescription
            }
        }
    }

    private func startClone(_ form: PublicGitCloneForm) {
        guard cloneTask == nil else { return }
        cloneError = nil
        // A single attempt owns one stable id. URLSession/Runtime reconnect behavior
        // reuses it; pressing Clone again after a terminal error creates a new id.
        let request = PublicGitCloneRequest(
            requestID: UUID().uuidString,
            url: form.url,
            ref: form.ref,
            name: form.name,
            depth: form.clonesFullHistory ? 0 : 1
        )
        cloneTask = Task {
            defer { cloneTask = nil }
            do {
                try await store.cloneAndSelectProject(request: request)
                guard !Task.isCancelled else { return }
                isGitClonePresented = false
            } catch {
                guard !Task.isCancelled else { return }
                cloneError = error.localizedDescription
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        #if os(iOS)
        // iOS：copy-in —— 先弹命名框（iOS 拿不到来源 App 名，预填智能默认名供确认/改名），
        // 确认后再复制进 Documents（源 scope 仅复制期间临时持有，不持久化 bookmark）。
        pendingImportURL = url
        importName = ProjectsStore.suggestedName(forImporting: url)
        isImportNamePresented = true
        #else
        // macOS：原地选择外部文件夹（无沙盒，外部 server 有全 FS 访问）。
        // scope 生命周期统一交给 RecentWorkspacesStore 管理（进入 recents 即持有、挤出即释放）。
        store.recentWorkspaces.beginAccess(to: url)
        store.selectWorkspace(Workspace(url: url))
        #endif
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

private struct PublicGitCloneForm: Sendable {
    let url: String
    let name: String?
    let ref: String?
    let clonesFullHistory: Bool
}

private struct PublicGitCloneSheet: View {
    let projectsRoot: String?
    let isCloning: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onClone: (PublicGitCloneForm) -> Void

    @State private var repositoryURL = ""
    @State private var projectName = ""
    @State private var gitRef = ""
    @State private var clonesFullHistory = false

    private var trimmedURL: String {
        repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repository.git", text: $repositoryURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("公开 HTTPS Git 地址")
                } footer: {
                    Text("支持 GitHub、GitLab、Gitee 和公开自建 Git 服务；不传输登录凭据。")
                }

                Section("可选") {
                    TextField("项目名（默认从 URL 推导）", text: $projectName)
                    TextField("分支或标签（默认远程默认分支）", text: $gitRef)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Toggle("克隆完整历史", isOn: $clonesFullHistory)
                }

                if let projectsRoot, !projectsRoot.isEmpty {
                    Section("存放位置") {
                        Label(projectsRoot, systemImage: "folder")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if isCloning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在克隆仓库…")
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("从 Git 仓库克隆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isCloning ? "取消 Clone" : "取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        onClone(PublicGitCloneForm(
                            url: trimmedURL,
                            name: optional(projectName),
                            ref: optional(gitRef),
                            clonesFullHistory: clonesFullHistory
                        ))
                    }
                    .disabled(trimmedURL.isEmpty || isCloning)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 430)
        #endif
        .interactiveDismissDisabled(isCloning)
    }

    private func optional(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
