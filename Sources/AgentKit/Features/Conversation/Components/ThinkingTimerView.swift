//
//  ThinkingTimerView.swift
//  AgentKit
//
//  Live thinking duration display.
//  Shows "思考中... 3.2s" while model is actively processing,
//  and "思考完成 (1.9s)" when model_finished arrives.
//
//  Uses TimelineView for smooth 0.5s-updating counter.
//

import SwiftUI

// MARK: - ThinkingTimerView

/// Shows thinking progress — elapsed time since model started.
/// Use when `snapshot.modelStartedAt` is non-nil or `snapshot.modelStats` is available.
struct ThinkingTimerView: View {
    let modelStartedAt: Date?
    let modelStats: ModelStats?
    let isLive: Bool

    var body: some View {
        if let startedAt = modelStartedAt, isLive {
            // Model is actively thinking — show live timer
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let elapsed = Date().timeIntervalSince(startedAt)
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("思考中... \(formatSeconds(elapsed))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let stats = modelStats {
            // Model finished — show final elapsed time
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("思考完成 (\(stats.formattedElapsed))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if stats.promptTokens > 0 {
                    Text("· \(stats.formattedTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
