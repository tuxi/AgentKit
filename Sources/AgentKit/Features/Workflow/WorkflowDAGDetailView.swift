//
//  WorkflowDAGDetailView.swift
//  AgentKit
//
//  v1.3 — Workflow DAG 详情视图（Inspector / Sheet）。
//  显示完整的 DAG 拓扑、节点状态、进度和最终输出。
//

import SwiftUI
import ClientToolProtocol

/// Workflow DAG 完整详情视图。
public struct WorkflowDAGDetailView: View {
    @ObservedObject var store: WorkflowStore
    @Environment(\.runtimeClient) private var runtimeClient
    let workflowID: String
    let conversationID: String?

    @State private var snapshotLoaded = false

    public init(store: WorkflowStore, workflowID: String, conversationID: String? = nil) {
        self.store = store
        self.workflowID = workflowID
        self.conversationID = conversationID
    }

    public var body: some View {
        Group {
            if let run = store.runs[workflowID] {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerSection(run)
                        Divider().padding(.vertical, 12)

                        // Progress summary
                        progressSummary(run)

                        // DAG topology — 独立水平滚动
                        if !run.nodes.isEmpty {
                            Divider().padding(.vertical, 12)
                            sectionLabel("Topology", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            ScrollView(.horizontal, showsIndicators: false) {
                                WorkflowDAGLayoutView(
                                    nodes: Array(run.nodes.values),
                                    edges: run.edges
                                )
                                .padding(.vertical, 8)
                            }
                        } else {
                            placeholderSection
                        }

                        // Output / Error
                        if let output = run.output {
                            Divider().padding(.vertical, 12)
                            outputSection(output)
                        }
                        if let error = run.error {
                            Divider().padding(.vertical, 12)
                            errorSection(error)
                        }

                        // Suspended info
                        if run.status == .suspended, let nodeName = run.suspendedNodeName {
                            Divider().padding(.vertical, 12)
                            suspendedBanner(nodeName: nodeName)
                        }

                        // Bottom spacer
                        Color.clear.frame(height: 8)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Workflow Not Found",
                    systemImage: "flowchart",
                    description: Text("No workflow with ID \(workflowID)")
                )
            }
        }
        .task {
            await loadSnapshotIfNeeded()
        }
    }

    // MARK: - Snapshot loading

    private func loadSnapshotIfNeeded() async {
        guard !snapshotLoaded else { return }
        guard let convID = conversationID else { return }
        guard let client = runtimeClient else { return }
        // 仅当尚未通过 snapshot 初始化时才加载
        guard store.runs[workflowID].map({ $0.lastSequence == 0 && $0.nodes.allSatisfy({ $0.value.state == .pending }) }) ?? true else {
            snapshotLoaded = true
            return
        }

        snapshotLoaded = true
        await store.fetchAndApplySnapshot(
            conversationID: convID,
            workflowID: workflowID,
            using: { cid, wid in try await client.getWorkflowSnapshot(conversationID: cid, workflowID: wid) }
        )
    }

    // MARK: - Sections

    private func headerSection(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "flowchart.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .padding(.top, 1)

                if let goal = run.goal {
                    ScrollView(.vertical) {
                        Text(goal)
                            .font(.headline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
                Spacer(minLength: 8)
                statusBadge(run.status)
            }

            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(run.workflowID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
                Spacer()
                Label("\(run.nodes.count) nodes", systemImage: "square.3.layers.3d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func progressSummary(_ run: WorkflowRun) -> some View {
        let stats = nodeStats(run)
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Progress", systemImage: "chart.bar.fill")

            // Compact progress bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    if stats.total > 0 {
                        let w = max(1, geo.size.width / CGFloat(stats.total) - 1)
                        ForEach(Array(run.nodes.values.sorted(by: { $0.name < $1.name }))) { node in
                            Rectangle()
                                .fill(nodeColor(for: node.state))
                                .frame(width: w)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 6)

            // Legend
            HStack(spacing: 12) {
                legendDot(.green, "\(stats.success) done")
                if stats.failed > 0 { legendDot(.red, "\(stats.failed) failed") }
                if stats.running > 0 { legendDot(.blue, "\(stats.running) running") }
                if stats.pending > 0 { legendDot(.gray, "\(stats.pending) pending") }
            }
            .font(.caption2)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func nodeColor(for state: WorkflowNodeState) -> Color {
        switch state {
        case .success: return .green
        case .failed, .failedPendingEdges: return .red
        case .running, .retrying, .awaiting, .successPendingEdges: return .blue
        default: return .gray.opacity(0.3)
        }
    }

    private struct NodeStats { var total = 0, success = 0, failed = 0, running = 0, pending = 0 }

    private func nodeStats(_ run: WorkflowRun) -> NodeStats {
        var s = NodeStats()
        for node in run.nodes.values {
            s.total += 1
            switch node.state {
            case .success: s.success += 1
            case .failed, .failedPendingEdges: s.failed += 1
            case .running, .retrying, .awaiting, .successPendingEdges: s.running += 1
            default: s.pending += 1
            }
        }
        return s
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.bottom, 4)
    }

    private func statusBadge(_ status: WorkflowTaskStatus) -> some View {
        Text(statusLabel(status))
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.12))
            .clipShape(Capsule())
    }

    private var placeholderSection: some View {
        VStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("Waiting for DAG topology...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func outputSection(_ output: JSONValue) -> some View {
        let text = output.prettyJSONString ?? "\(output)"
        return copyableContentSection(
            title: "Output",
            systemImage: "arrow.up.doc.fill",
            tint: nil,
            content: text,
            monospaced: true
        )
    }

    private func errorSection(_ error: String) -> some View {
        copyableContentSection(
            title: "Error",
            systemImage: "exclamationmark.triangle.fill",
            tint: .red,
            content: error,
            monospaced: false
        )
    }

    /// 带标题行（含复制按钮）+ 可滚动内容的通用 section。
    @ViewBuilder
    private func copyableContentSection(
        title: String,
        systemImage: String,
        tint: Color?,
        content: String,
        monospaced: Bool
    ) -> some View {
        let sectionTint = tint ?? .primary
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：label + 复制按钮
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(sectionTint)
                Spacer()
                CopyButton(text: content)
            }

            // 内容区域
            contentBox(content: content, tint: tint, monospaced: monospaced)
        }
    }

    @ViewBuilder
    private func contentBox(content: String, tint: Color?, monospaced: Bool) -> some View {
        let textColor = tint ?? .primary
        let borderColor = tint?.opacity(0.15) ?? Color.primary.opacity(0.08)
        let textFont: Font = monospaced ? .caption.monospaced() : .caption

        ScrollView(.vertical) {
            Text(content)
                .font(textFont)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private func suspendedBanner(nodeName: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Waiting for client tool: \(nodeName)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func statusLabel(_ status: WorkflowTaskStatus) -> String {
        switch status {
        case .pending:   return "Pending"
        case .running:   return "Running"
        case .suspended: return "Suspended"
        case .success:   return "Success"
        case .failed:    return "Failed"
        case .canceled:  return "Canceled"
        case .unknown(let v): return v
        }
    }

    private func statusColor(_ status: WorkflowTaskStatus) -> Color {
        switch status {
        case .pending:   return .gray
        case .running:   return .blue
        case .suspended: return .orange
        case .success:   return .green
        case .failed:    return .red
        case .canceled:  return .secondary
        case .unknown:   return .secondary
        }
    }
}

// MARK: - Copy Button

/// 图标复制按钮：点击后短暂显示 checkmark 反馈。
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = text
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.medium))
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }
}
