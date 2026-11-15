//
//  ToolResultDetailView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import SwiftUI
import ClientToolProtocol

/// Tool 调用结果详情视图。
///
/// 从 WorkspaceStore → activeConversationViewModel → snapshot 中查询匹配的 ToolNodePayload，
/// 展示 tool 名称、参数、状态、耗时和完整输出。
struct ToolResultDetailView: View {
    let callID: String

    @Environment(WorkspaceStore.self) private var store
    @Environment(\.inspectorPathState) private var inspectorPath

    private var payload: ToolNodePayload? {
        store.activeConversationViewModel?.snapshot.timeline
            .lazy
            .compactMap { node -> ToolNodePayload? in
                if case .tool(let p) = node.kind, p.callID == callID {
                    return p
                }
                return nil
            }
            .first
    }

    var body: some View {
        Group {
            if let payload {
                contentView(payload)
            } else {
                ContentUnavailableView("Tool 调用未找到", systemImage: "wrench.and.screwdriver")
            }
        }
        .navigationTitle("Tool Result")
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ p: ToolNodePayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Tool name header
                headerView(p)

                Divider()

                // Args
                if p.args != nil {
                    InspectorPayloadView(tool: p, kind: .inputJSON, title: "参数")
                }

                // Status & timing
                statusView(p)

                // Output
                if !p.output.isEmpty {
                    InspectorPayloadView(tool: p, kind: .outputText, title: "结果")
                }

                // Structured output
                if p.structuredOutput != nil {
                    InspectorPayloadView(tool: p, kind: .structuredOutput, title: "结构化输出")
                }

                // Error
                if p.status == .failed, let code = p.exitCode {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("退出码: \(code)")
                    }
                    .foregroundStyle(.red)
                }

                // Actions
                actionsView(p)
            }
            .padding()
        }
    }

    // MARK: - Subviews

    private func headerView(_ p: ToolNodePayload) -> some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(p.toolName)
                .font(.title2.weight(.semibold))
            Spacer()
        }
    }

    private func sectionView(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func statusView(_ p: ToolNodePayload) -> some View {
        HStack(spacing: 12) {
            // Status badge
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(p.status))
                    .frame(width: 8, height: 8)
                Text(statusLabel(p.status))
                    .font(.subheadline)
            }

            // Auto-approved
            if p.isAutoApproved {
                Text("自动批准")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )
            }

            // Elapsed
            if let elapsed = p.elapsedMs {
                Text("⏱ \(formatElapsed(elapsed))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func actionsView(_ p: ToolNodePayload) -> some View {
        HStack(spacing: 12) {
            // Copy
            Button {
                copyToClipboard(p.output)
            } label: {
                Label("复制结果", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(p.output.isEmpty)

            Spacer()
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: - Helpers

    private func statusColor(_ s: ToolNodeStatus) -> Color {
        switch s {
        case .running:   .orange
        case .completed: .green
        case .autoApproved: .green
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
}
