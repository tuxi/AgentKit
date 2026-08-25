//
//  AutomationSessionPicker.swift
//  AgentKit
//
//  「回到会话」模式下的会话选择器：列出当前工作区（workspace）对应的全部会话，
//  显示标题 + 会话 id，替代手动输入 session_id。
//
//  过滤逻辑与侧栏分组一致：用 `workspaceGroupingID`（`path:<canonicalPath>`）匹配，
//  worktree 会话也会归组到源项目下。
//

import SwiftUI

struct AutomationSessionPicker: View {
    @Environment(WorkspaceStore.self) private var workspaceStore

    /// 当前选中的工作区（nil 时提示先选工作区）。
    let workspace: Workspace?
    /// 选中的会话 id（chat 模式的 `session_id`）。
    @Binding var sessionID: String

    @State private var contentWidth: CGFloat = 0

    var body: some View {
        Menu {
            if workspace == nil {
                Text("请先选择工作区")
            } else if sessions.isEmpty {
                Text("该工作区暂无会话")
            } else {
                ForEach(sessions) { conversation in
                    Button {
                        sessionID = conversation.id
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.name ?? "未命名会话")
                                    .lineLimit(1)
                                Text(conversation.id)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if conversation.id == sessionID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .medium))
//                if contentWidth >= 100 {
                    Text(labelText)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
//                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectedConversation == nil ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            )
            .foregroundStyle(selectedConversation == nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(workspace == nil || sessions.isEmpty)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, newValue in
            contentWidth = newValue
        }
        .task {
            // 会话列表尚未加载时先拉取一次。
            if !workspaceStore.listViewModel.hasLoadedConversations {
                await workspaceStore.listViewModel.refresh()
            }
        }
    }

    // MARK: - Data

    /// 当前工作区下的会话（与侧栏分组一致）。
    private var sessions: [ConversationRef] {
        guard let workspace else { return [] }
        let groupingID = "path:\(workspace.url.canonicalPathForGrouping)"
        return workspaceStore.listViewModel.conversations.filter { $0.workspaceGroupingID == groupingID }
    }

    /// 已选会话（从全部会话里找，避免已选会话不在当前工作区时显示为空）。
    private var selectedConversation: ConversationRef? {
        workspaceStore.listViewModel.conversations.first { $0.id == sessionID }
    }

    private var labelText: String {
        if let selected = selectedConversation {
            let title = selected.name ?? "未命名会话"
            return "\(title) · \(selected.id.prefix(8))"
        }
        return "选择会话"
    }
}
