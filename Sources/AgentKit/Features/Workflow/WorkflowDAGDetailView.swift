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
    let workflowID: String

    public init(store: WorkflowStore, workflowID: String) {
        self.store = store
        self.workflowID = workflowID
    }

    public var body: some View {
        if let run = store.runs[workflowID] {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    headerSection(run)

                    // DAG topology — 独立水平滚动，不撑宽外层
                    if !run.nodes.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            WorkflowDAGLayoutView(
                                nodes: Array(run.nodes.values),
                                edges: run.edges
                            )
                            .padding(.vertical, 12)
                        }
                    } else {
                        placeholderSection
                    }

                    // Output / Error
                    if let output = run.output {
                        outputSection(output)
                    }
                    if let error = run.error {
                        errorSection(error)
                    }

                    // Suspended info
                    if run.status == .suspended, let nodeName = run.suspendedNodeName {
                        suspendedBanner(nodeName: nodeName)
                    }
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

    // MARK: - Sections

    private func headerSection(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Goal + status badge 同行
            HStack(alignment: .firstTextBaseline) {
                if let goal = run.goal {
                    Text(goal)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                statusBadge(run.status)
            }

            // workflowID + node count
            HStack {
                Text(run.workflowID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .lineLimit(1)
                Spacer()
                Text("\(run.nodes.count) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            ProgressView()
            Text("Waiting for DAG topology...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func outputSection(_ output: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Output", systemImage: "arrow.up.doc")
                .font(.subheadline.weight(.semibold))
            Text(output.prettyJSONString ?? "\(output)")
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func suspendedBanner(nodeName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
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
