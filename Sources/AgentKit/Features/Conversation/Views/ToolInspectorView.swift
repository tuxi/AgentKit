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
        #if os(macOS)
        if let node = timeline.first(where: { $0.id == toolName }), case .tool(let payload) = node.kind {
            return payload
        }
        #endif
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
                if p.args != nil {
                    InspectorPayloadView(
                        tool: p,
                        kind: .inputJSON,
                        title: "参数"
                    )
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
                        #if os(macOS)
                        Text(p.output)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        #else
                        Text(outputPreview(p.output))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(10)
                        #endif
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

                    if p.structuredOutput?["schema"].string == "ui_evidence.v1" {
                        Button {
                            inspectorPath.push(.uiEvidence(UIEvidenceSelection(
                                callID: p.callID,
                                title: "UI Evidence"
                            )))
                        } label: {
                            Label("Open UI Evidence", systemImage: "viewfinder.rectangular")
                        }
                        .buttonStyle(.bordered)
                    }

                    if p.structuredOutput?["schema"].string == "ui_layout_result.v1" {
                        Button {
                            inspectorPath.push(.uiLayout(UILayoutSelection(
                                callID: p.callID,
                                title: "UI Layout"
                            )))
                        } label: {
                            Label("Open UI Layout", systemImage: "rectangle.3.group")
                        }
                        .buttonStyle(.bordered)
                    }

                    if p.structuredOutput?["schema"].string == "ui_preview_result.v1" {
                        Button {
                            inspectorPath.push(.uiPreview(UIPreviewSelection(
                                callID: p.callID,
                                title: "UI Preview Lineage"
                            )))
                        } label: {
                            Label("Open UI Preview Lineage", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.bordered)
                    }

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
        guard text.utf8.count > 500 else { return text }
        return String(text.prefix(500)) + "\n…"
    }
}
