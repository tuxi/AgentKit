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

/// Renders ordered tool and thinking activity with user-controlled disclosure.
struct ToolCallGroupView: View {
    let group: ToolGroup
    @Binding var documentState: TranscriptDocumentState
    let onAction: (TranscriptAction) -> Void

    private var isExpanded: Bool {
        documentState.isToolExpanded(callID: group.id, defaultExpanded: group.isCollecting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            Button {
                onAction(.toggleTool(callID: group.id, defaultExpanded: group.isCollecting))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                    Text(group.summary)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
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
                ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(group.entries) { entry in
                    switch entry {
                    case .tool(let tool):
                        let presentation = ToolTranscriptPresenter.activityPresentation(for: tool)
                        Button {
                            onAction(.toggleTool(callID: tool.callID, defaultExpanded: false))
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: presentation.systemImage)
                                Text(presentation.title).lineLimit(1)
                                if let changes = presentation.changeSummary { Text(changes) }
                                if let status = presentation.statusText { Text(status) }
                                Image(systemName: documentState.isToolExpanded(callID: tool.callID, defaultExpanded: false) ? "chevron.up" : "chevron.down")
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)
                        if let detail = presentation.detail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 10)
                        }
                        if documentState.isToolExpanded(callID: tool.callID, defaultExpanded: false) {
                            ScrollView(.vertical) { toolDetailView(tool) }
                                .frame(maxHeight: 144)
                        }
                    case .thinking(let id, let payload):
                        ThinkingCardView(id: id, payload: payload,
                            isExpanded: documentState.expandedThinkingIDs.contains(id),
                            onToggle: { onAction(.toggleThinking(id: id)) })
                    }
                }
                }
                }
                .frame(maxHeight: 320)
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
        if statuses.contains(.running) || group.isThinking {
            HStack(spacing: 3) {
                ProgressView()
                    .scaleEffect(0.5)
                Text(ToolTranscriptText().text("running"))
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
        ToolDetailRowView(tool: tool, onAction: onAction)

        if tool.callID != group.tools.last?.callID {
            Divider()
                .padding(.horizontal, 10)
        }
    }

    // MARK: - Workflow tool DAG rendering

    /// 尝试从工具输出 JSON 解析 DAG 定义（兼容 `workflow_definition`、`workflow_plan_ready` 等格式）。
    /// Large outputs are never decoded here: the expanded row already bounds
    /// them behind a summary, and decoding every body pass would repeat that
    /// cost on the main thread.
    fileprivate static func parseDAG(from jsonString: String) -> ToolResultDAGData? {
        guard jsonString.utf8.count <= 64 * 1024,
              jsonString.contains("\"nodes\""),
              let data = jsonString.data(using: .utf8),
              let dag = try? JSONDecoder().decode(ToolResultDAGData.self, from: data),
              !dag.nodes.isEmpty else { return nil }
        return dag
    }

    fileprivate static func dagView(
        _ dag: ToolResultDAGData,
        toolName: String
    ) -> some View {
        let nodes = dag.nodes.map { wn in
            WorkflowNode(
                name: wn.name,
                type: wn.type ?? (wn.tool != nil ? "tool" : "unknown"),
                state: .pending,
                toolName: wn.tool
            )
        }
        let edges = (dag.edges ?? []).map { WorkflowEdge(from: $0.from, to: $0.to) }

        return VStack(alignment: .leading, spacing: 6) {
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

// MARK: - Expanded tool detail

/// Expanded detail for one tool call. The payload summary renders first and
/// the full input/output is formatted lazily, off the main actor, and cached
/// per call. A failed `ui_preview` call can carry megabytes of HTML in both
/// its arguments and its echoed error; that payload must never be encoded or
/// laid out synchronously on expansion.
private struct ToolDetailRowView: View {
    let tool: ToolNodePayload
    let onAction: (TranscriptAction) -> Void

    @StateObject private var model = ToolPayloadDetailModel()
    @State private var expandedKinds: Set<ToolPayloadKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tool.toolName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button {
                    onAction(.openToolResult(callID: tool.callID))
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let summary = model.summary {
                if let input = summary.input {
                    ToolPayloadDetailSection(
                        title: ToolTranscriptText().text("input"),
                        kind: .inputJSON,
                        summary: input,
                        tool: tool,
                        model: model,
                        isExpanded: expansion(.inputJSON),
                        maxHeight: 96,
                        horizontalScroll: true
                    )
                }
                outputSection(summary.output)
            }

            if tool.status == .failed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(ToolTranscriptText().text("failed"))
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

            if let elapsed = tool.elapsedMs {
                Text("耗时 \(elapsed)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .task(id: ToolPayloadDetailModel.contentKey(tool)) {
            model.prepare(tool: tool)
        }
        .onChange(of: model.summary) { _, summary in
            guard let summary else { return }
            if let input = summary.input, input.isInlineFriendly {
                expandedKinds.insert(.inputJSON)
            }
        }
    }

    @ViewBuilder
    private func outputSection(_ summary: ToolPayloadSummary?) -> some View {
        if !tool.output.isEmpty {
            if let summary {
                if !summary.isInlineFriendly {
                    ToolPayloadDetailSection(
                        title: ToolTranscriptText().text("output"),
                        kind: .outputText,
                        summary: summary,
                        tool: tool,
                        model: model,
                        isExpanded: expansion(.outputText),
                        maxHeight: 96,
                        horizontalScroll: false
                    )
                } else if let dag = ToolCallGroupView.parseDAG(from: tool.output) {
                    ToolCallGroupView.dagView(dag, toolName: tool.toolName)
                } else {
                    Text(ToolTranscriptText().text("output"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    MarkdownRenderer(text: tool.output, baseFont: .caption)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func expansion(_ kind: ToolPayloadKind) -> Binding<Bool> {
        Binding(
            get: { expandedKinds.contains(kind) },
            set: { isOn in
                if isOn {
                    expandedKinds.insert(kind)
                } else {
                    expandedKinds.remove(kind)
                }
            }
        )
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
