//
//  ContextWindowDetailView.swift
//  AgentKit
//
//  上下文窗口详情面板 — 展示 `GET /v1/conversations/{id}/context` 快照。
//  由 DraftComposerPanel 的 context_window 按钮弹出（macOS popover / iOS sheet）。
//

import SwiftUI

/// 上下文窗口详情面板。
struct ContextWindowDetailView: View {
    let snapshot: ConversationContextSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
                Spacer()
            }
            .padding(16)
        }
#if os(macOS)
        .frame(width: 340)
#endif
        .background(Color.approvalPanelBackground)
    }

    private var header: some View {
        HStack {
            Text(AgentKitLocalized.string("context_window.title"))
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isLoading)
            .accessibilityLabel(AgentKitLocalized.string("context_window.refresh"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && snapshot == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text(AgentKitLocalized.string("context_window.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(AgentKitLocalized.string("context_window.refresh"), action: onRefresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if let snapshot {
            VStack(alignment: .leading, spacing: 16) {
                modelSection(snapshot.model)
                Divider()
                usageSection(snapshot.current)
                Divider()
                compactionSection(snapshot.compaction)
                Divider()
                structureSection(snapshot.structure)
            }
        } else {
            Text(AgentKitLocalized.string("context_window.empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    // MARK: - Sections

    private func modelSection(_ model: ConversationContextModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(AgentKitLocalized.string("context_window.model"))
            Text(model.name)
                .font(.callout.weight(.semibold))
            LabeledContent(
                AgentKitLocalized.string("context_window.context_window"),
                value: ContextFormat.tokens(model.contextWindow)
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.compact_threshold"),
                value: ContextFormat.tokens(model.compactThreshold)
            )
        }
    }

    private func usageSection(_ current: ConversationContextCurrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(AgentKitLocalized.string("context_window.current_usage"))
            ProgressView(value: ContextFormat.clamped(current.usagePct / 100))
                .progressViewStyle(.linear)
                .tint(usageColor(current))
            LabeledContent(
                AgentKitLocalized.string("context_window.prompt_tokens"),
                value: ContextFormat.tokens(current.promptTokens)
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.usage_pct"),
                value: ContextFormat.pct(current.usagePct)
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.threshold_pct"),
                value: ContextFormat.pct(current.thresholdPct)
            )
        }
    }

    private func compactionSection(_ compaction: ConversationContextCompaction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(AgentKitLocalized.string("context_window.compaction"))
            LabeledContent(
                AgentKitLocalized.string("context_window.compaction_count"),
                value: "\(compaction.totalCount)"
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.total_saved_tokens"),
                value: ContextFormat.tokens(compaction.totalSavedTokens)
            )
            if let last = compaction.last {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AgentKitLocalized.string("context_window.last_compaction"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    LabeledContent(
                        AgentKitLocalized.string("context_window.before"),
                        value: ContextFormat.tokens(last.beforeTokens)
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.after"),
                        value: ContextFormat.tokens(last.afterTokens)
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.saved_tokens"),
                        value: ContextFormat.tokens(last.savedTokens)
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.ratio"),
                        value: ContextFormat.pct(last.ratio * 100)
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.summary_chars"),
                        value: "\(last.summaryChars)"
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.has_summary"),
                        value: last.ineffective
                            ? AgentKitLocalized.string("context_window.ineffective")
                            : AgentKitLocalized.string("context_window.effective")
                    )
                    LabeledContent(
                        AgentKitLocalized.string("context_window.last_compaction"),
                        value: Self.formattedDate(last.at)
                    )
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(AgentKitLocalized.string("context_window.never_compacted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func structureSection(_ structure: ConversationContextStructure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(AgentKitLocalized.string("context_window.structure"))
            LabeledContent(
                AgentKitLocalized.string("context_window.message_count"),
                value: "\(structure.messageCount)"
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.estimated_tokens"),
                value: ContextFormat.tokens(structure.estimatedTokens)
            )
            LabeledContent(
                AgentKitLocalized.string("context_window.has_summary"),
                value: structure.hasSummary
                    ? AgentKitLocalized.string("context_window.summary_present")
                    : AgentKitLocalized.string("context_window.summary_absent")
            )
            if structure.hasSummary {
                LabeledContent(
                    AgentKitLocalized.string("context_window.summary_chars"),
                    value: "\(structure.summaryChars)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    private func usageColor(_ current: ConversationContextCurrent) -> Color {
        if current.usagePct >= current.thresholdPct { return .red }
        if current.usagePct >= current.thresholdPct * 0.8 { return .orange }
        return .green
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func formattedDate(_ raw: String) -> String {
        let date = isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 上下文数值格式化。
enum ContextFormat {
    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func tokens(_ value: Int) -> String {
        tokenFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
