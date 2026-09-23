//
//  ModelRetryView.swift
//  AgentKit
//
//  Transient notice shown when the model is retrying after a transient failure.
//  Ephemeral, live-only — not persisted in history.
//

import SwiftUI

/// A compact inline view showing model retry progress.
/// Uses orange/warning color scheme distinct from blue (thinking) and red (error).
struct ModelRetryView: View {
    let state: ModelRetryState

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Retrying model")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("(\(state.attempt)/\(state.maxAttempts))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.isFallback {
                        Text("· Fallback to non-stream")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = state.err, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.2), lineWidth: 2)
                    .frame(width: 20, height: 20)
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: state.progress)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
        // No .transition() here: on macOS this view is hosted inside an
        // NSTableView cell (NSHostingView), where AppKit drives layout
        // synchronously — a size-animating transition re-enters the layout
        // pass and is skipped ("NSHostingView is being laid out reentrantly").
        // The iOS call site applies the transition where SwiftUI owns layout.
    }
}

#if DEBUG
struct ModelRetryView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            ModelRetryView(state: ModelRetryState(
                attempt: 2,
                maxAttempts: 5,
                retryDelayMs: 2000,
                retryFallback: false,
                err: "OpenRouter free tier returned 503",
                invocationID: "inv_123"
            ))

            ModelRetryView(state: ModelRetryState(
                attempt: 3,
                maxAttempts: 3,
                retryDelayMs: 5000,
                retryFallback: true,
                err: "Stream failed, switching to non-stream",
                invocationID: "inv_456"
            ))

            ModelRetryView(state: ModelRetryState(
                attempt: 1,
                maxAttempts: 3,
                retryDelayMs: 1000,
                retryFallback: false,
                err: nil,
                invocationID: "inv_789"
            ))
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif