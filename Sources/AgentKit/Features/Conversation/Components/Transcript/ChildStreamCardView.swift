//
//  ChildStreamCardView.swift
//  AgentKit
//
//  iOS: entry card for child streams (task sub-agents, background jobs).
//  Tap to open the child stream inspector.
//

import SwiftUI

/// A card representing a child agent stream, tappable to view details.
struct ChildStreamCardView: View {
    let payload: ChildStreamNodePayload
    let onAction: (TranscriptAction) -> Void

    var body: some View {
        Button {
            onAction(.openChildStream(childID: payload.childID))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: payload.kind == .task ? "arrow.trianglehead.branch" : "terminal")
                    .font(.caption)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        statusLabel
                        if let elapsed = payload.elapsedMs {
                            Text(elapsed >= 1000
                                ? String(format: "%.1fs", Double(elapsed) / 1000)
                                : "\(elapsed)ms")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let code = payload.exitCode {
                            Text("exit \(code)")
                                .font(.caption2)
                                .foregroundStyle(code == 0 ? .green : .red)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch payload.status {
        case .running:
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.5)
                Text("运行中").font(.caption2)
            }
            .foregroundStyle(.orange)
        case .completed:
            Label("完成", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("失败", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
        case .canceled:
            Label("已取消", systemImage: "stop.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}
