//
//  TurnProcessViews.swift
//  AgentKit
//
//  iOS turn chrome, matching Codex mobile and the Web renderer's semantics:
//  a completed turn collapses its process behind "用时 24分40秒 · 编辑 3 个文件",
//  a running turn stays flat under a ticking "已处理 8分15秒", and what the turn
//  wrote to disk sits under the answer as a change card.
//

#if os(iOS)
import SwiftUI

// MARK: - Palette

private enum TurnDiffPalette {
    static let added = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.78, blue: 0.52, alpha: 1)
            : UIColor(red: 0.23, green: 0.43, blue: 0.07, alpha: 1)
    })
    static let removed = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.48, blue: 0.48, alpha: 1)
            : UIColor(red: 0.64, green: 0.16, blue: 0.16, alpha: 1)
    })
}

// MARK: - Completed turn header

/// "用时 24分40秒 · 编辑 3 个文件 ›" — the fold affordance above a finished
/// answer. With no process blocks behind it the line still reports the facts,
/// it just stops being tappable.
struct TurnProcessHeader: View {
    let label: String
    let isFoldable: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            guard isFoldable else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isFoldable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
        .accessibilityLabel(label)
        .accessibilityHint(isFoldable ? (isExpanded ? "收起执行过程" : "展开执行过程") : "")
    }
}

// MARK: - Live turn header

/// "已处理 8分15秒" — one clock on top of the flat trace, so a long turn shows
/// it is still working without asking the Runtime for a snapshot every second.
struct LiveTurnHeader: View {
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            if let startedAt {
                LiveDurationLabel(startedAt: startedAt)
            } else {
                Text("已处理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Leaf view on purpose: the timer invalidates this label only. Wrapping the
/// whole turn in TimelineView would rebuild the transcript once a second (the
/// macOS TextKit path had to drop its ticker for exactly that reason).
private struct LiveDurationLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(timedText(at: context.date))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func timedText(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(startedAt).rounded())
        return "已处理 \(TurnDurationText.string(seconds: seconds))"
    }
}

// MARK: - Change card

/// "已编辑 5 个文件 +136 -3" under the answer, three rows by default.
///
/// `filesChanged` is the full-turn count while `files` may have been clipped by
/// the Runtime (200), so fold math runs on the list we hold and the withheld
/// files get their own line — otherwise a 250-file turn shows a header of 250
/// above "再显示 197 个文件" and the numbers stop adding up.
struct TurnChangesCardView: View {
    let changes: TurnChanges
    @State private var isExpanded = false

    private static let previewLimit = 3

    /// Sorting and fold counts live on the model (`TurnChanges.preview(limit:)`)
    /// so the SwiftUI and Web cards cannot drift apart.
    private var preview: TurnChanges.Preview { changes.preview(limit: Self.previewLimit) }
    private var visible: [TurnChanges.FileChange] {
        guard !isExpanded else {
            return changes.preview(limit: .max).rows
        }
        return preview.rows
    }
    private var hiddenCount: Int { preview.hiddenCount }
    private var withheldCount: Int { preview.withheldCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !visible.isEmpty {
                Divider().opacity(0.5)
                ForEach(Array(visible.enumerated()), id: \.offset) { index, file in
                    if index > 0 { Divider().opacity(0.5) }
                    row(for: file)
                }
            }
            if hiddenCount > 0 {
                Divider().opacity(0.5)
                expander
            }
            if withheldCount > 0, isExpanded || hiddenCount <= 0 {
                withheldNote
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已编辑 \(changes.filesChanged) 个文件")
    }

    private var header: some View {
        Button {
            guard hiddenCount > 0 || withheldCount > 0 else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("已编辑 \(changes.filesChanged) 个文件")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("+\(changes.addedLines)")
                    .font(.caption)
                    .foregroundStyle(TurnDiffPalette.added)
                Text("-\(changes.removedLines)")
                    .font(.caption)
                    .foregroundStyle(TurnDiffPalette.removed)
                Spacer(minLength: 0)
                if hiddenCount > 0 || withheldCount > 0 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }

    private func row(for file: TurnChanges.FileChange) -> some View {
        HStack(spacing: 12) {
            Text(file.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if file.added > 0 {
                    Text("+\(file.added)")
                        .foregroundStyle(TurnDiffPalette.added)
                }
                if file.removed > 0 {
                    Text("−\(file.removed)")
                        .foregroundStyle(TurnDiffPalette.removed)
                }
                if file.added == 0, file.removed == 0 {
                    Text(statusWord(file.status))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var expander: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "收起" : "再显示 \(hiddenCount) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var withheldNote: some View {
        Text("另有 \(withheldCount) 个文件未列出")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
    }

    private func statusWord(_ status: TurnChanges.Status) -> String {
        switch status {
        case .added: return "新增"
        case .deleted: return "删除"
        case .modified, .unknown: return "修改"
        }
    }
}
#endif
