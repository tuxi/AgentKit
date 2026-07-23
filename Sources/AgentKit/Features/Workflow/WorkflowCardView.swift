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
            HStack(spacing: 8) {
                Image(systemName: "flowchart")
                    .font(.caption)
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Workflow")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if let goal = payload.goal {
                        Text(goal)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    } else {
                        Text(payload.workflowID)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        statusLabel
                        if payload.nodeCount > 0 {
                            Text("\(payload.nodeCount) nodes")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
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
                    .fill(Color.purple.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch payload.status {
        case .pending:
            Label("准备中", systemImage: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .running:
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.5)
                Text("执行中").font(.caption2)
            }
            .foregroundStyle(.blue)
        case .suspended:
            Label("已暂停", systemImage: "pause.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .success:
            Label("已完成", systemImage: "checkmark.circle.fill")
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
        case .unknown(let v):
            Label(v, systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}
