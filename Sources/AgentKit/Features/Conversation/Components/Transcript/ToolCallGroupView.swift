//
//  ToolCallGroupView.swift
//  AgentKit
//
//  iOS: renders a tool-call group with status indicator and expand/collapse.
//  Collapsed: tool name + count + status icon.
//  Expanded: each tool's input/output rendered as markdown.
//

import SwiftUI

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
            // Output
            if !tool.output.isEmpty {
                Text("输出")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                MarkdownRenderer(text: tool.output, baseFont: .caption)
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
