//
//  WorkflowDashboardView.swift
//  AgentKit
//
//  P18 R1/R2 — Workflow 控制面板。镜像 AutomationDashboardView 结构：
//  目录页（跨 workspace 枚举）→ 详情页（版本历史 + run 历史）→ Snapshot 页。
//  P1 范围：纯只读观测，不包含删除/触发/重试/模板化。
//

import SwiftUI
import ClientToolProtocol

// MARK: - Route

enum WorkflowDashboardRoute: Hashable {
    case detail(workspacePath: String, name: String)
    case snapshot(workspacePath: String, workflowName: String, taskID: Int64)
}

// MARK: - WorkflowDashboardView

public struct WorkflowDashboardView: View {

    @Environment(WorkspaceStore.self) private var store
    @State private var viewModel: WorkflowDashboardViewModel?
    @State private var path: [WorkflowDashboardRoute] = []

    // P2: save-as-template / trigger sheets
    @State private var saveTemplateContext: SaveTemplateContext?
    @State private var triggerContext: TriggerContext?
    @State private var successMessage: String?

    struct SaveTemplateContext: Identifiable {
        let workspacePath: String
        let taskID: Int64
        var id: String { "\(workspacePath)#\(taskID)" }
    }

    struct TriggerContext: Identifiable {
        let workspacePath: String
        let name: String
        var id: String { "\(workspacePath)#\(name)" }
    }

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                let vm = WorkflowDashboardViewModel(
                    client: store.client,
                    workspacePaths: Self.knownWorkspacePaths(store: store)
                )
                viewModel = vm
                await vm.loadInitialIfNeeded()
            }
        }
    }

    private static func knownWorkspacePaths(store: WorkspaceStore) -> [String] {
        var paths: [String] = []
        paths.append(contentsOf: store.recentWorkspaces.workspaces.map(\.url.path))
        paths.append(contentsOf: store.projects.projects.map(\.url.path))
        paths.append(contentsOf: store.listViewModel.conversations.map(\.workspacePath))
        return paths
    }

    @ViewBuilder
    private func content(vm: WorkflowDashboardViewModel) -> some View {
        NavigationStack(path: $path) {
            workspaceSplit(vm: vm)
                .navigationDestination(for: WorkflowDashboardRoute.self) { route in
                    switch route {
                    case .detail(let ws, let name):
                        WorkflowDetailPage(
                            viewModel: vm,
                            workspacePath: ws,
                            name: name,
                            onSaveTemplate: { taskID in
                                saveTemplateContext = SaveTemplateContext(workspacePath: ws, taskID: taskID)
                            },
                            onTrigger: {
                                triggerContext = TriggerContext(workspacePath: ws, name: name)
                            }
                        )
                    case .snapshot(let ws, let name, let taskID):
                        WorkflowSnapshotPage(
                            viewModel: vm,
                            workspacePath: ws,
                            workflowName: name,
                            taskID: taskID
                        )
                    }
                }
        }
        .sheet(item: $saveTemplateContext) { context in
            WorkflowSaveTemplateSheet(viewModel: vm, context: context) { savedName in
                successMessage = "已保存为模板「\(savedName)」"
                Task { await vm.load(force: true) }
            }
#if os(macOS)
            .frame(minWidth: 360, idealWidth: 420)
#endif
        }
        .sheet(item: $triggerContext) { context in
            WorkflowTriggerFormSheet(viewModel: vm, context: context) { taskID in
                path.append(.snapshot(
                    workspacePath: context.workspacePath,
                    workflowName: context.name,
                    taskID: taskID
                ))
            }
#if os(macOS)
            .frame(minWidth: 480, idealWidth: 560, minHeight: 480)
#endif
        }
        .alert("操作成功", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(successMessage ?? "")
        }
    }

    /// 跨平台 workspace 选择器布局：macOS 左侧 sidebar，iOS 顶部标签。
    @ViewBuilder
    private func workspaceSplit(vm: WorkflowDashboardViewModel) -> some View {
#if os(macOS)
        HSplitView {
            workspaceSidebar(vm: vm)
                .frame(minWidth: 180, idealWidth: 220)
            directoryView(vm: vm)
        }
#else
        VStack(spacing: 0) {
            workspaceTabs(vm: vm)
            directoryView(vm: vm)
        }
#endif
    }

    // MARK: - Workspace Selector

    /// macOS 风格：左侧 workspace 列表，点击切换加载。
    private func workspaceSidebar(vm: WorkflowDashboardViewModel) -> some View {
        List(selection: workspaceSelectionBinding(vm)) {
            Section("工作区") {
                ForEach(vm.workspacePaths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Label(WorkflowDashboardViewModel.workspaceDisplayName(path), systemImage: "folder")
                            .lineLimit(1)
                        if vm.workspaceErrors[path] != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(path)
                    .help(path)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// iOS 风格：顶部 workspace 标签（横向滚动），点击切换加载。
    private func workspaceTabs(vm: WorkflowDashboardViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.workspacePaths, id: \.self) { path in
                    let isSelected = vm.selectedWorkspacePath == path
                    Button {
                        Task { await vm.selectWorkspace(path) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(WorkflowDashboardViewModel.workspaceDisplayName(path))
                                .font(.callout)
                            if vm.workspaceErrors[path] != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func workspaceSelectionBinding(_ vm: WorkflowDashboardViewModel) -> Binding<String?> {
        Binding(
            get: { vm.selectedWorkspacePath },
            set: { newValue in
                if let newValue {
                    Task { await vm.selectWorkspace(newValue) }
                }
            }
        )
    }

    // MARK: - Directory

    private func directoryView(vm: WorkflowDashboardViewModel) -> some View {
        VStack(spacing: 0) {
            if let path = vm.selectedWorkspacePath {
                listHeader(vm: vm, workspacePath: path)
            }
            if vm.isLoading && !vm.hasLoaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if let err = vm.errorMessage, vm.catalog.isEmpty {
                errorView(message: err, vm: vm)
            } else if vm.catalog.isEmpty {
                emptyView(vm: vm)
            } else {
                list(vm: vm)
            }
        }
        .navigationTitle("Workflow")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    /// 目录头部：当前 workspace 全路径 + 数量。
    private func listHeader(vm: WorkflowDashboardViewModel, workspacePath: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(workspacePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("共 \(vm.catalog.count) 个 Workflow")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func list(vm: WorkflowDashboardViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vm.catalog) { entry in
                    WorkflowCatalogCard(
                        summary: entry.summary,
                        workspaceName: entry.workspaceName,
                        detailRoute: .detail(workspacePath: entry.workspacePath, name: entry.summary.name),
                        onTrigger: {
                            triggerContext = TriggerContext(
                                workspacePath: entry.workspacePath,
                                name: entry.summary.name
                            )
                        }
                    )
                }
            }
            .padding(14)
        }
    }

    private func emptyView(vm: WorkflowDashboardViewModel) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "flowchart")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("该工作区还没有 Workflow")
                .font(.headline)
            Text("Workflow 是计划收敛之后的执行形态。\n使用 plan_workflow 工具发起一次工作流，\n运行记录将在此处展示。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func errorView(message: String, vm: WorkflowDashboardViewModel) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await vm.load(force: true) }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Catalog Card

private struct WorkflowCatalogCard: View {
    let summary: WorkflowSummary
    let workspaceName: String
    let detailRoute: WorkflowDashboardRoute
    let onTrigger: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(value: detailRoute) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !summary.description.isEmpty {
                                Text(summary.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        statusBadge
                    }

                    if let hash = summary.latestHash, !hash.isEmpty {
                        Text(hash.prefix(12))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onTrigger) {
                Label("触发", systemImage: "play.fill")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.trailing, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var cardBackground: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(.systemBackground)
#endif
    }

    private var statusBadge: some View {
        let (color, text) = WorkflowStatusStyle.style(for: summary.latestStatus)
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Status Style

/// 状态颜色语义与 Automation 面板一致：success=绿/failed=红/running=蓝/等。
enum WorkflowStatusStyle {
    static func style(for status: String?) -> (color: Color, text: String) {
        guard let status = status?.lowercased() else {
            return (.gray, "未知")
        }
        switch status {
        case "success", "succeeded":
            return (.green, "成功")
        case "failed":
            return (.red, "失败")
        case "running":
            return (.blue, "运行中")
        case "pending":
            return (.gray, "等待中")
        case "suspended":
            return (.orange, "已挂起")
        case "canceled":
            return (.secondary, "已取消")
        case "skipped":
            return (.gray.opacity(0.5), "已跳过")
        default:
            return (.secondary, status)
        }
    }
}

// MARK: - Detail Page

private struct WorkflowDetailPage: View {
    let viewModel: WorkflowDashboardViewModel
    let workspacePath: String
    let name: String
    let onSaveTemplate: (Int64) -> Void
    let onTrigger: () -> Void

    @State private var detail: WorkflowDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                detailView(detail)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onTrigger) {
                    Label("触发", systemImage: "play.fill")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await viewModel.loadDetail(workspacePath: workspacePath, name: name)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "加载详情失败"
        }
    }

    private func detailView(_ detail: WorkflowDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.name).font(.title2.weight(.semibold))
                    if !detail.description.isEmpty {
                        Text(detail.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("ID: \(detail.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Versions
                if !detail.versions.isEmpty {
                    sectionLabel("版本历史", systemImage: "clock.arrow.circlepath")
                    ForEach(detail.versions) { v in
                        HStack {
                            Text("v\(v.version)")
                                .font(.caption.monospaced())
                            Text(v.hash.prefix(12))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospaced()
                            Spacer()
                            Text(v.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    Divider()
                }

                // Runs
                sectionLabel("运行历史", systemImage: "play.rectangle.fill")
                if detail.runs.isEmpty {
                    Text("暂无运行记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.runs) { run in
                        runRow(run)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func runRow(_ run: WorkflowRunSummary) -> some View {
        let (color, text) = WorkflowStatusStyle.style(for: run.status)
        return HStack(spacing: 0) {
            NavigationLink(value: WorkflowDashboardRoute.snapshot(
                workspacePath: workspacePath,
                workflowName: name,
                taskID: run.id
            )) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run #\(run.id)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let err = run.error, !err.isEmpty {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.12))
                            .clipShape(Capsule())
                        Text(run.createdAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    onSaveTemplate(run.id)
                } label: {
                    Label("保存为模板", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 10)
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Snapshot Page

private struct WorkflowSnapshotPage: View {
    let viewModel: WorkflowDashboardViewModel
    let workspacePath: String
    let workflowName: String
    let taskID: Int64

    @Environment(WorkspaceStore.self) private var store
    @State private var snapshot: WorkflowSnapshot?
    @State private var loadError: String?
    @State private var observeID = 0
    @State private var isResuming = false
    @State private var resumeErrorMessage: String?

    /// 实时状态来自 WorkflowStore（WS workflow_* 事件叠加在 snapshot 基线之上）。
    /// 快照已 apply 后 liveRun 即非空，作为节点/拓扑的权威渲染源。
    private var liveRun: WorkflowRun? {
        guard let wid = snapshot?.workflowId else { return nil }
        return store.workflowStore.runs[wid]
    }

    private var nodes: [WorkflowNode] {
        if let run = liveRun {
            return Array(run.nodes.values).sorted { $0.name < $1.name }
        }
        guard let snapshot else { return [] }
        return snapshot.nodes.map { sn in
            var node = WorkflowNode(name: sn.name, type: inferType(sn.name))
            node.state = WorkflowNodeState(rawValue: sn.state)
            node.terminal = sn.terminal
            node.progress = sn.progress ?? 0
            node.error = sn.error
            node.output = sn.output
            return node
        }
    }

    private var edges: [WorkflowEdge] {
        if let run = liveRun { return run.edges }
        return (snapshot?.edges ?? []).map { WorkflowEdge(from: $0.from, to: $0.to) }
    }

    private var suspendedNodes: Set<String> {
        Set((snapshot?.nodes ?? []).filter(\.suspended).map(\.name))
    }

    private func inferType(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "start" { return "start" }
        if lower == "end" { return "end" }
        return "tool"
    }

    var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else if let loadError {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView("加载 Run #\(taskID)…")
            }
        }
        .navigationTitle("Run #\(taskID)")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isResumable {
                    Button {
                        resume()
                    } label: {
                        if isResuming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("恢复", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isResuming)
                }
            }
        }
        .alert("恢复失败", isPresented: Binding(
            get: { resumeErrorMessage != nil },
            set: { if !$0 { resumeErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resumeErrorMessage ?? "")
        }
        .task(id: observeID) { await observe() }
    }

    /// 可恢复状态：suspended / failed / canceled。
    private var isResumable: Bool {
        guard let status = snapshot?.task?.status else { return false }
        switch WorkflowTaskStatus(rawValue: status) {
        case .suspended, .failed, .canceled: return true
        default: return false
        }
    }

    private func resume() {
        isResuming = true
        resumeErrorMessage = nil
        Task {
            defer { isResuming = false }
            do {
                try await viewModel.resumeRun(
                    workspacePath: workspacePath,
                    workflowName: workflowName,
                    taskID: taskID
                )
                // 重启观测循环：旧 task 取消，新循环从最新 snapshot 开始，
                // run 状态转为 running 后持续轮询到下一个终态/挂起点。
                observeID += 1
            } catch {
                resumeErrorMessage = (error as? LocalizedError)?.errorDescription ?? "恢复失败"
            }
        }
    }

    /// 观测循环：拉 snapshot → apply 到 WorkflowStore（WS 事件在其上增量叠加），
    /// 非终态时每 2s 轮询。会话内 run 的实时更新由现有 WS 通道驱动（同一个 store），
    /// headless run 走轮询，两条路径共用同一渲染面。
    private func observe() async {
        while !Task.isCancelled {
            do {
                let snap = try await viewModel.loadSnapshot(
                    workspacePath: workspacePath, workflowName: workflowName, taskID: taskID
                )
                snapshot = snap
                loadError = nil
                store.workflowStore.applySnapshot(snap)
                if let status = snap.task?.status, WorkflowTaskStatus(rawValue: status).isTerminal {
                    return
                }
            } catch {
                if snapshot == nil {
                    loadError = (error as? LocalizedError)?.errorDescription ?? "加载快照失败"
                }
                // 轮询中的瞬时错误保留已有数据，继续下一次
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func content(_ snapshot: WorkflowSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                taskHeader(snapshot)

                Divider()

                if let goal = snapshot.goal ?? liveRun?.goal {
                    sectionLabel("目标", systemImage: "target")
                    Text(goal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                if !nodes.isEmpty {
                    sectionLabel("拓扑", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    ScrollView(.horizontal, showsIndicators: false) {
                        WorkflowDAGLayoutView(nodes: nodes, edges: edges)
                            .padding(.vertical, 8)
                    }
                    Divider()
                }

                if !nodes.isEmpty {
                    sectionLabel("节点状态 (\(nodes.count))", systemImage: "square.3.layers.3d")
                    nodeListView
                    Divider()
                }

                if let error = snapshot.task?.error ?? liveRun?.error {
                    errorSection(error)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func taskHeader(_ snapshot: WorkflowSnapshot) -> some View {
        let status = liveRun?.status ?? WorkflowTaskStatus(rawValue: snapshot.task?.status ?? "pending")
        let (color, text) = WorkflowStatusStyle.style(for: status.rawValue)
        let progress = snapshot.task?.progress ?? 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Task #\(snapshot.task?.id ?? taskID)", systemImage: "flowchart.fill")
                    .font(.headline)
                Spacer()
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            }

            if progress > 0 {
                ProgressView(value: progress)
                    .tint(color)
            }

            HStack(spacing: 6) {
                Label("\(snapshot.nodes.count) 节点", systemImage: "square.3.layers.3d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let status = snapshot.task?.status, WorkflowTaskStatus(rawValue: status) == .suspended {
                    Label("挂起中", systemImage: "pause.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            if isResumable {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Text("任务挂起或失败，可手动恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var nodeListView: some View {
        LazyVStack(spacing: 6) {
            ForEach(nodes) { node in
                let isSuspended = suspendedNodes.contains(node.name)
                NodeRowView(node: node, isSuspended: isSuspended)
            }
        }
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("错误", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Node Row

private struct NodeRowView: View {
    let node: WorkflowNode
    let isSuspended: Bool

    var body: some View {
        let (color, text) = nodeStateLabel
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(node.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let tool = node.toolName {
                Text(tool)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isSuspended {
                Text("挂起")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }

            if node.progress > 0 && node.progress < 1.0 {
                ProgressView(value: node.progress)
                    .tint(color)
                    .frame(width: 40)
            }

            if let err = node.error, !err.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Text(text)
                .font(.caption2)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var nodeStateLabel: (Color, String) {
        switch node.state {
        case .success: return (.green, "成功")
        case .failed, .failedPendingEdges: return (.red, "失败")
        case .running, .retrying: return (.blue, "运行中")
        case .awaiting: return (.orange, "等待")
        case .successPendingEdges: return (.teal, "待收敛")
        case .pending: return (.gray, "待处理")
        case .ready: return (.gray, "就绪")
        case .skipped: return (.gray.opacity(0.5), "跳过")
        case .canceled: return (.gray.opacity(0.5), "取消")
        case .unknown(let v): return (.secondary, v)
        }
    }
}

// MARK: - Save Template Sheet (P2 R4)

/// 把某次 run 保存为命名模板：模板名（必填）+ 描述（可选）。
private struct WorkflowSaveTemplateSheet: View {
    let viewModel: WorkflowDashboardViewModel
    let context: WorkflowDashboardView.SaveTemplateContext
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模板名")
                        TextField("例如：daily-stock-report", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("描述（可选）")
                        TextField("这个模板做什么", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    Text("基本信息")
                } footer: {
                    Text("将 Run #\(context.taskID) 的 manifest 固化为可复用模板，之后可在目录中一键触发。")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("保存")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("保存为模板")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let savedName = try await viewModel.saveTemplate(
                    workspacePath: context.workspacePath,
                    sourceTaskID: context.taskID,
                    name: name,
                    description: description.isEmpty ? nil : description
                )
                dismiss()
                onSaved(savedName)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存失败"
            }
        }
    }
}

// MARK: - Trigger Form Sheet (P2 R5)

/// 参数化触发表单：goal 必填 + 每个 agent 用会话选择器选 session_id。
/// 模板固化字段（template 类型/agents 结构/message/parallelism/timeout_ms）
/// 从 manifest 只读展示；无 manifest 时降级为手动表单。
/// 提交成功后回调 task_id，由调用方跳转 snapshot 观测页。
private struct WorkflowTriggerFormSheet: View {
    let viewModel: WorkflowDashboardViewModel
    let context: WorkflowDashboardView.TriggerContext
    let onTriggered: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 表单本地行状态（带稳定 id，供 ForEach 增删）。
    /// `isLocked` = manifest 模式：role/message/intent/correlation_id/workspace_path 只读，
    /// 仅 session_id 可编辑（会话选择器）。
    struct AgentRow: Identifiable {
        let id = UUID()
        var role: String
        var message: String
        var intent: String
        var correlationID: String
        var workspacePath: String
        var sessionID: String
        var isLocked: Bool
    }

    @State private var detail: WorkflowDetail?
    @State private var goal = ""
    @State private var templateKind = "cross_workspace_collaboration_v1"
    @State private var agents: [AgentRow] = []
    @State private var parallelismText = ""
    @State private var timeoutMsText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    /// 从 detail.manifest 解析的模板信息。
    private var manifest: WorkflowManifest? {
        guard let detail else { return nil }
        return WorkflowManifest.fromJSONValue(detail.manifest)
    }

    /// manifest 有 agents → 模板模式（只读展示 + 会话选择）；否则 fallback 手动表单。
    private var usesManifest: Bool {
        !(manifest?.agents ?? []).isEmpty
    }

    /// 模板所属 workspace（供 AutomationSessionPicker 按该 workspace 过滤会话）。
    private var workspace: Workspace? {
        Workspace(url: URL(fileURLWithPath: context.workspacePath))
    }

    /// 提交可用性：goal 非空，且每个 agent 都选了会话（session_id 非空）。
    private var canSubmit: Bool {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !agents.isEmpty && agents.allSatisfy {
            !$0.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func loadDetail() async {
        do {
            let d = try await viewModel.loadDetail(workspacePath: context.workspacePath, name: context.name)
            detail = d
            if let m = WorkflowManifest.fromJSONValue(d.manifest),
               let manifestAgents = m.agents, !manifestAgents.isEmpty {
                // 模板模式：固化字段预填 + 只读
                goal = m.goal ?? ""
                templateKind = m.template ?? "cross_workspace_collaboration_v1"
                agents = manifestAgents.map { a in
                    AgentRow(
                        role: a.role ?? "",
                        message: a.message ?? "",
                        intent: a.intent ?? "request",
                        correlationID: a.correlationID ?? "",
                        workspacePath: a.workspacePath ?? "",
                        sessionID: "",
                        isLocked: true
                    )
                }
                parallelismText = m.parallelism.map(String.init) ?? ""
                timeoutMsText = m.timeoutMs.map(String.init) ?? ""
            } else {
                // fallback：手动表单骨架
                agents = [Self.newFallbackRow()]
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "加载模板信息失败"
        }
    }

    private static func newFallbackRow() -> AgentRow {
        AgentRow(
            role: "",
            message: "",
            intent: "request",
            correlationID: UUID().uuidString.prefix(8).lowercased(),
            workspacePath: "",
            sessionID: "",
            isLocked: false
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if detail == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("加载模板信息…")
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("目标（goal）")
                            TextField("这次运行要完成什么", text: $goal, axis: .vertical)
                                .lineLimit(3...6)
                                .textFieldStyle(.roundedBorder)
                        }
                        if usesManifest {
                            LabeledContent("模板类型", value: templateKind)
                        } else {
                            Picker("模板类型", selection: $templateKind) {
                                Text("cross_workspace_collaboration_v1").tag("cross_workspace_collaboration_v1")
                                Text("cross_workspace_collaboration_v2").tag("cross_workspace_collaboration_v2")
                            }
                        }
                    } header: {
                        Text("任务")
                    }

                    Section {
                        ForEach($agents) { $row in
                            if row.isLocked {
                                ManifestAgentRowView(row: $row, workspace: workspace)
                            } else {
                                AgentRowEditor(row: $row, workspace: workspace)
                            }
                        }
                        .onDelete { offsets in
                            guard !usesManifest else { return }
                            agents.remove(atOffsets: offsets)
                        }
                        if usesManifest {
                            Text("以上 agent 结构来自模板固化 manifest，仅需为每个 agent 选择会话。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                agents.append(Self.newFallbackRow())
                            } label: {
                                Label("添加 Agent", systemImage: "plus")
                            }
                            Text("此模板无保存的 manifest（旧模板或一次性 run），请手动填写各字段。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Agents 花名册 (\(agents.count))")
                    } footer: {
                        Text("每个 agent 的 session_id 通过会话选择器选取该 workspace 下的会话。")
                    }

                    if usesManifest {
                        Section {
                            LabeledContent("parallelism", value: parallelismText.isEmpty ? "默认" : parallelismText)
                            LabeledContent("timeout_ms", value: timeoutMsText.isEmpty ? "默认" : timeoutMsText)
                        } header: {
                            Text("固化参数")
                        }
                    } else {
                        Section {
                            TextField("parallelism（可选）", text: $parallelismText)
#if os(iOS)
                                .keyboardType(.numberPad)
#endif
                            TextField("timeout_ms（可选）", text: $timeoutMsText)
#if os(iOS)
                                .keyboardType(.numberPad)
#endif
                        } header: {
                            Text("高级")
                        }
                    }

                    Section {
                        Button {
                            submit()
                        } label: {
                            if isSubmitting {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                Text("触发运行")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .disabled(!canSubmit || isSubmitting)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("触发 \(context.name)")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("触发失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await loadDetail() }
    }

    private func submit() {
        let request = WorkflowTriggerRequest(
            goal: goal,
            template: templateKind,
            agents: agents.map { row in
                WorkflowAgentSpec(
                    role: row.role,
                    sessionID: row.sessionID,
                    message: row.message,
                    intent: row.intent,
                    correlationID: row.correlationID,
                    workspacePath: row.workspacePath.isEmpty ? nil : row.workspacePath
                )
            },
            parallelism: Int(parallelismText),
            timeoutMs: Int64(timeoutMsText)
        )
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let taskID = try await viewModel.triggerRun(
                    workspacePath: context.workspacePath,
                    name: context.name,
                    request: request
                )
                dismiss()
                onTriggered(taskID)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "触发失败"
            }
        }
    }
}

// MARK: - Agent Row Editor

/// 触发表单 fallback 模式（无 manifest）的单个 agent 行：
/// role/message/intent/correlation_id/workspace_path 可编辑，session_id 用会话选择器。
private struct AgentRowEditor: View {
    @Binding var row: WorkflowTriggerFormSheet.AgentRow
    let workspace: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("role", text: $row.role)
                    .textFieldStyle(.roundedBorder)
                AutomationSessionPicker(workspace: workspace, sessionID: $row.sessionID)
            }

            TextField("message（发给该 agent 的任务书）", text: $row.message, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("intent", selection: $row.intent) {
                    Text("request").tag("request")
                    Text("notification").tag("notification")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer()

                Text(row.correlationID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            TextField("workspace_path（可选，缺省用当前 workspace）", text: $row.workspacePath)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Manifest Agent Row

/// 模板模式（manifest 已固化）的 agent 行：结构信息只读展示，仅 session_id 可编辑。
private struct ManifestAgentRowView: View {
    @Binding var row: WorkflowTriggerFormSheet.AgentRow
    let workspace: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.role.isEmpty ? "agent" : row.role)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                AutomationSessionPicker(workspace: workspace, sessionID: $row.sessionID)
            }

            if !row.message.isEmpty {
                Text(row.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if row.intent != "request" {
                    Label(row.intent, systemImage: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if !row.correlationID.isEmpty {
                    Text(row.correlationID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            if !row.workspacePath.isEmpty {
                Text(row.workspacePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }
}
