//
//  AgentStateDetailView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import SwiftUI

/// Agent 状态详情视图。
///
/// 展示当前选中会话的 agent 运行状态：
/// - 模型、生命周期、turn 活跃状态
/// - Token 消耗、调用次数、耗时等模型统计
struct AgentStateDetailView: View {
    @Environment(WorkspaceStore.self) private var store

    private var vm: ConversationViewModel? {
        store.activeConversationViewModel
    }

    var body: some View {
        Group {
            if let vm {
                contentView(vm)
            } else {
                ContentUnavailableView("无活跃会话", systemImage: "sparkles")
            }
        }
        .navigationTitle("Agent 状态")
    }

    // MARK: - Content

    private func contentView(_ vm: ConversationViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Session identity
                sessionSection(vm)

                Divider()

                // Agent lifecycle
                lifecycleSection(vm)

                Divider()

                // Model stats
                if let stats = vm.snapshot.modelStats {
                    modelStatsSection(stats, snapshot: vm.snapshot)
                } else {
                    Text("暂无模型统计")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Session Section

    private func sessionSection(_ vm: ConversationViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("会话信息")
                    .font(.title2.weight(.semibold))
            }

            if let conversation = vm.conversation {
                rowView("会话 ID", icon: "number") {
                    Text(conversation.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            rowView("模型", icon: "cpu") {
                Text(vm.selectedModel.isEmpty ? "—" : vm.selectedModel)
            }
        }
    }

    // MARK: - Lifecycle Section

    private func lifecycleSection(_ vm: ConversationViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("运行状态")
                    .font(.title2.weight(.semibold))
            }

            rowView("生命周期", icon: "circle.dotted") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(lifecycleColor(vm))
                        .frame(width: 8, height: 8)
                    Text(lifecycleStatusLabel(vm))
                }
            }

            rowView("Turn", icon: "play.circle") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.isTurnActive ? Color.orange : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(vm.isTurnActive ? "活跃中" : "空闲")
                }
            }

            rowView("连接状态", icon: "antenna.radiowaves.left.and.right") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(vm.isConnected ? "已连接" : "未连接")
                }
            }

            if vm.isArchived {
                Label("已归档", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Model Stats Section

    private func modelStatsSection(_ stats: ModelStats, snapshot: RuntimeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("模型统计")
                    .font(.title2.weight(.semibold))
            }

            rowView("上下文 Token", icon: "text.alignleft") {
                Text(stats.formattedContextTokens)
            }

            rowView("总计 Token", icon: "sum") {
                Text(stats.formattedTotalTokens)
            }

            if stats.hasUsageUnits {
                rowView("用量单位", icon: "dollarsign.circle") {
                    Text(stats.formattedUsageUnits)
                }
            }

            rowView("调用次数", icon: "repeat") {
                Text("\(stats.invocationCount)")
            }

            rowView("耗时", icon: "clock") {
                Text(stats.formattedElapsed)
            }

            if let startedAt = snapshot.turnStartedAt {
                rowView("Turn 开始", icon: "calendar") {
                    Text(startedAt, style: .time)
                }
            }

            if let modelStartedAt = snapshot.modelStartedAt {
                rowView("模型开始", icon: "clock.badge") {
                    Text(modelStartedAt, style: .time)
                }
            }
        }
    }

    // MARK: - Helpers

    private func rowView(_ label: String, icon: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tertiary)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            value()
        }
        .font(.subheadline)
    }

    private func lifecycleColor(_ vm: ConversationViewModel) -> Color {
        switch vm.lifecycleStatus {
        case "running", "resuming": return .green
        case "queued", "accepted":  return .orange
        case "paused":              return .yellow
        case "failed":              return .red
        case "done":                return .gray
        default:                    return .gray
        }
    }

    private func lifecycleStatusLabel(_ vm: ConversationViewModel) -> String {
        switch vm.lifecycleStatus {
        case "running":   return "运行中"
        case "resuming":  return "恢复中"
        case "queued":    return "排队中"
        case "accepted":  return "已接受"
        case "paused":    return "已暂停"
        case "failed":    return "失败"
        case "done":      return "完成"
        case "cancelled": return "已取消"
        case .some(let s): return s
        case .none:       return "未知"
        }
    }
}
