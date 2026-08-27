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
                viewModel = WorkflowDashboardViewModel(
                    client: store.client,
                    workspacePaths: Self.knownWorkspacePaths(store: store)
                )
            }
            await viewModel?.load()
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
            directoryView(vm: vm)
                .navigationDestination(for: WorkflowDashboardRoute.self) { route in
                    switch route {
                    case .detail(let ws, let name):
                        WorkflowDetailPage(
                            viewModel: vm,
                            workspacePath: ws,
                            name: name,
                            onOpenRun: { taskID in
                                path.append(.snapshot(workspacePath: ws, workflowName: name, taskID: taskID))
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
    }

    // MARK: - Directory

    private func directoryView(vm: WorkflowDashboardViewModel) -> some View {
        VStack(spacing: 0) {
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

    private func list(vm: WorkflowDashboardViewModel) -> some View {
        let groups = groupedEntries(vm.catalog)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.name) { group in
                    GroupHeader(name: group.name, error: vm.workspaceErrors[group.path])
                    ForEach(group.entries) { entry in
                        WorkflowCatalogCard(
                            summary: entry.summary,
                            workspaceName: entry.workspaceName
                        ) {
                            path.append(.detail(workspacePath: entry.workspacePath, name: entry.summary.name))
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private struct WorkspaceGroup {
        let path: String
        let name: String
        let entries: [WorkflowDashboardViewModel.WorkflowCatalogEntry]
    }

    private func groupedEntries(_ catalog: [WorkflowDashboardViewModel.WorkflowCatalogEntry]) -> [WorkspaceGroup] {
        var groups: [String: WorkspaceGroup] = [:]
        for entry in catalog {
            if var g = groups[entry.workspacePath] {
                var entries = g.entries
                entries.append(entry)
                groups[entry.workspacePath] = WorkspaceGroup(path: entry.workspacePath, name: entry.workspaceName, entries: entries)
            } else {
                groups[entry.workspacePath] = WorkspaceGroup(path: entry.workspacePath, name: entry.workspaceName, entries: [entry])
            }
        }
        return groups.values.sorted { $0.name < $1.name }
    }

    private func emptyView(vm: WorkflowDashboardViewModel) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "flowchart")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("还没有 Workflow")
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

// MARK: - Group Header

private struct GroupHeader: View {
    let name: String
    let error: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Catalog Card

private struct WorkflowCatalogCard: View {
    let summary: WorkflowSummary
    let workspaceName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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

                HStack(spacing: 8) {
                    if let hash = summary.latestHash, !hash.isEmpty {
                        Text(hash.prefix(12))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                    Spacer()
                    if summary.latestTaskID != nil {
                        Text("点击查看详情")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(12)
#if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
#else
            .background(Color(.systemBackground))
#endif
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
    let onOpenRun: (Int64) -> Void

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
                        Button {
                            onOpenRun(run.id)
                        } label: {
                            runRow(run)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func runRow(_ run: WorkflowRunSummary) -> some View {
        let (color, text) = WorkflowStatusStyle.style(for: run.status)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run #\(run.id)")
                    .font(.subheadline.weight(.medium))
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
        .task { await observe() }
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