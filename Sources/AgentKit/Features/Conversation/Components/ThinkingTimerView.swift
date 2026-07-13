//
//  ThinkingTimerView.swift
//  AgentKit
//
//  Live "agent working" indicator, shown only WHILE a turn is active
//  (turn_started → turn_finished). Branded (Code Agent + icon) with a turn-level
//  timer, matching Claude Code's persistent logo+timer. There is no "thinking
//  finished" state — a completed turn shows its stats in the turn footer, so the
//  indicator simply disappears when the turn ends (no misleading "done" line).
//

import SwiftUI

struct ThinkingTimerView: View {
    /// Non-nil while the turn is active — the indicator's lifetime.
    let turnStartedAt: Date?
    /// The model is actively generating (vs. running a tool).
    let isThinking: Bool
    /// Latest token count, if a model invocation has finished this turn.
    let modelStats: ModelStats?

    var body: some View {
        if let started = turnStartedAt {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let elapsed = Date().timeIntervalSince(started)
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Code Agent")
                            Text("· \(formatSeconds(elapsed))")
                            if let stats = modelStats {
                                // Compact-line priority: units → calls → total → context.
                                if stats.hasUsageUnits { Text("· \(stats.formattedUsageUnits) units") }
                                if stats.invocationCount > 0 { Text("· \(stats.invocationCount)x") }
                            }
                            if isThinking {
                                Text("· 思考中…")
                            }
                        }
                        if let stats = modelStats, stats.invocationCount > 0 {
                            Text("累计 \(stats.formattedTotalTokens) tokens · 当前上下文 \(stats.formattedContextTokens)")
                                .font(.caption2)
                        }
                    }
                    .shimmering(active: isThinking)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10:
            return String(format: "%.1fs", seconds)
        case 10..<60:
            return String(format: "%.0fs", seconds)
        default:
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        }
    }
}
