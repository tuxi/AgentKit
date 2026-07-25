//
//  ToolCallGroupView.swift
//  AgentKit
//
//  iOS: renders a tool-call group with status indicator and expand/collapse.
//  Collapsed: tool name + count + status icon.
//  Expanded: each tool's input/output rendered as markdown.
//

import SwiftUI
import ClientToolProtocol

/// Renders a group of same-name tool calls as an expandable block.
struct ToolCallGroupView: View {
    let group: ToolGroup
    @Binding var documentState: TranscriptDocumentState
    let onAction: (TranscriptAction) -> Void

    private var isExpanded: Bool {
        documentState.expandedToolIDs.contains(group.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            Button {
                onAction(.toggleTool(callID: group.id))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                    Text(group.summary)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    statusBadge
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded: per-tool details
            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)
                ForEach(group.tools, id: \.callID) { tool in
                    toolDetailView(tool)
                }
            }
        }
//        .background(
//            RoundedRectangle(cornerRadius: 8)
//                .fill(Color.secondary.opacity(0.06))
//        )
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        let statuses = Set(group.tools.map(\.status))
        if statuses.contains(.running) {
            HStack(spacing: 3) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("运行中")
                    .font(.caption2)
            }
            .foregroundStyle(.orange)
        } else if statuses == [.completed] || statuses == [.autoApproved] {
//            Image(systemName: "checkmark.circle.fill")
//                .font(.caption2)
//                .foregroundStyle(.green)
            EmptyView()
        } else if statuses.contains(.failed) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        } else {
            EmptyView()
        }
    }

    // MARK: - Tool Detail

    @ViewBuilder
    private func toolDetailView(_ tool: ToolNodePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Args (if available)
            if let args = tool.args, !args.isEmpty {
                Text("输入")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                MarkdownRenderer(text: args.prettyPrinted, baseFont: .caption)
            }
            // Output — DAG component for workflow tools, markdown for others
            if !tool.output.isEmpty {
                if let dag = tryParseDAG(from: tool.output) {
                    workflowToolDAGView(dag: dag, toolName: tool.toolName)
                } else {
                    Text("输出")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    MarkdownRenderer(text: tool.output, baseFont: .caption)
                }
            }
            // Error
            if tool.status == .failed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("工具执行失败")
                        .font(.caption2)
                    if let code = tool.exitCode {
                        Text("(exit \(code))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.red)
                .padding(.top, 2)
            }
            // Elapsed
            if let elapsed = tool.elapsedMs {
                Text("耗时 \(elapsed)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

        if tool.callID != group.tools.last?.callID {
            Divider()
                .padding(.horizontal, 10)
        }
    }

    // MARK: - Workflow tool DAG rendering

    /// 尝试从工具输出 JSON 解析 DAG 定义（兼容 `workflow_definition`、`workflow_plan_ready` 等格式）。
    private func tryParseDAG(from jsonString: String) -> ToolResultDAGData? {
        guard let data = jsonString.data(using: .utf8),
              let dag = try? JSONDecoder().decode(ToolResultDAGData.self, from: data),
              !dag.nodes.isEmpty else { return nil }
        return dag
    }

    @ViewBuilder
    private func workflowToolDAGView(dag: ToolResultDAGData, toolName: String) -> some View {
        let nodes = dag.nodes.map { wn in
            WorkflowNode(
                name: wn.name,
                type: wn.type ?? (wn.tool != nil ? "tool" : "unknown"),
                state: .pending,
                toolName: wn.tool
            )
        }
        let edges = (dag.edges ?? []).map { WorkflowEdge(from: $0.from, to: $0.to) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flowchart.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                Text(dag.goal ?? toolName)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Text("\(dag.nodes.count) nodes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                WorkflowDAGLayoutView(nodes: nodes, edges: edges)
                    .padding(6)
            }
            .frame(maxHeight: 220)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.top, 4)
    }
}

// MARK: - Tool result DAG detection types

/// 工具输出中 DAG 定义的轻量 Decodable（workflow_definition / workflow_plan_ready 等格式）。
private struct ToolResultDAGData: Decodable {
    let goal: String?
    let workflowId: String?
    let nodes: [ToolResultDAGNode]
    let edges: [ToolResultDAGEdge]?

    enum CodingKeys: String, CodingKey {
        case goal, nodes, edges
        case workflowId = "workflow_id"
    }
}

private struct ToolResultDAGNode: Decodable {
    let name: String
    let tool: String?
    let type: String?
}

private struct ToolResultDAGEdge: Decodable {
    let from: String
    let to: String
}

private extension JSONValue {
    var isEmpty: Bool {
        switch self {
        case .object(let d): return d.isEmpty
        case .array(let a): return a.isEmpty
        case .string(let s): return s.isEmpty
        case .null: return true
        case .bool, .number, .integer: return false
        }
    }

    var prettyPrinted: String {
        switch self {
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self),
               let str = String(data: data, encoding: .utf8) {
                return "```json\n\(str)\n```"
            }
            return "\(self)"
        case .string(let s): return s
        case .number(let n): return "\(n)"
        case .integer(let n): return "\(n)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}
