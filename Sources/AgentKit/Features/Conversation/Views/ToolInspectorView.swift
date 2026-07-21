//
//  ToolInspectorView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI
import ClientToolProtocol

struct ToolInspectorView: View {

    /// Inspector 选择中携带的标识符（可能是 callID 或 toolName）。
    let toolName: String

    @Environment(WorkspaceStore.self) private var store
    @Environment(\.inspectorPathState) private var inspectorPath

    /// 在 snapshot timeline 中查找匹配的 ToolNodePayload。
    private var toolPayload: ToolNodePayload? {
        guard let timeline = store.activeConversationViewModel?.snapshot.timeline else {
            return nil
        }
        // 优先按 callID 精确匹配，其次按 toolName 匹配
        for node in timeline {
            if case .tool(let p) = node.kind {
                if p.callID == toolName { return p }
            }
        }
        for node in timeline {
            if case .tool(let p) = node.kind {
                if p.toolName == toolName { return p }
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let payload = toolPayload {
                contentView(payload)
            } else {
                placeholderView
            }
        }
    }

    // MARK: - Content with real data

    private func contentView(_ p: ToolNodePayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(p.toolName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }

                // Args
                if let args = p.args {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("参数")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(args.prettyPrinted)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }

                Divider()

                // Status & timing
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(p.status))
                            .frame(width: 8, height: 8)
                        Text(statusLabel(p.status))
                            .font(.subheadline)
                    }
                    if let elapsed = p.elapsedMs {
                        Text("⏱ \(formatElapsed(elapsed))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Output preview
                if !p.output.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("输出预览")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(outputPreview(p.output))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(10)
                    }
                }

                // Actions
                HStack(spacing: 12) {
                    Button {
                        inspectorPath.push(.toolResult(callID: p.callID))
                    } label: {
                        Label("查看详情", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding()
        }
    }

    // MARK: - Placeholder (backward compat)

    private var placeholderView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(toolName)
                .font(.title2)

            Text("暂无可用的工具调用数据")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func statusColor(_ s: ToolNodeStatus) -> Color {
        switch s {
        case .running:   .orange
        case .completed, .autoApproved: .green
        case .failed:    .red
        }
    }

    private func statusLabel(_ s: ToolNodeStatus) -> String {
        switch s {
        case .running:      "运行中"
        case .completed:    "成功"
        case .autoApproved: "已批准"
        case .failed:       "失败"
        }
    }

    private func formatElapsed(_ ms: Int) -> String {
        if ms >= 1000 {
            String(format: "%.1fs", Double(ms) / 1000.0)
        } else {
            "\(ms)ms"
        }
    }

    private func outputPreview(_ text: String) -> String {
        let preview = text.prefix(500)
        return text.count > 500 ? String(preview) + "\n…" : String(preview)
    }
}

// MARK: - JSONValue Pretty Print

private extension JSONValue {
    var prettyPrinted: String {
        switch self {
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\(self)"
        case .string(let s):  return s
        case .number(let n):  return "\(n)"
        case .integer(let n): return "\(n)"
        case .bool(let b):    return b ? "true" : "false"
        case .null:           return "null"
        }
    }
}
