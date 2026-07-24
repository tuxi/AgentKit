//
//  WorkflowCardView.swift
//  AgentKit
//
//  v1.3 — Timeline 中的 Flux Workflow DAG 入口卡片。
//  点击打开 DAG 详情视图（Inspector 或 sheet）。
//

import SwiftUI

/// Workflow DAG 入口卡，类似 ChildStreamCardView，点击跳转 DAG 详情。
struct WorkflowCardView: View {
    let id: String
    let payload: WorkflowNodePayload
    let onAction: (TranscriptAction) -> Void

    var body: some View {
        Button {
            onAction(.openWorkflow(workflowID: payload.workflowID))
        } label: {
            HStack(spacing: 10) {
                // Icon
                Image(systemName: "flowchart.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Color.purple.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Workflow")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        if payload.nodeCount > 0 {
                            Text("\(payload.nodeCount) steps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let goal = payload.goal {
                        Text(goal)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                    } else {
                        Text(payload.workflowID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Status + error preview
                    HStack(spacing: 6) {
                        statusLabel
                        if let error = payload.error {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.purple.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch payload.status {
        case .pending:
            Label("Pending", systemImage: "circle.dotted")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        case .running:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                Text("Running").font(.caption2)
            }
            .foregroundStyle(.blue)
        case .suspended:
            Label("Suspended", systemImage: "pause.circle.fill")
                .font(.caption2).foregroundStyle(.orange).labelStyle(.titleAndIcon)
        case .success:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption2).foregroundStyle(.red).labelStyle(.titleAndIcon)
        case .canceled:
            Label("Canceled", systemImage: "stop.circle.fill")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        case .unknown(let v):
            Label(v, systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
    }
}
