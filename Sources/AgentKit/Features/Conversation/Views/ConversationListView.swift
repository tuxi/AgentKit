//
//  ConversationListView.swift
//  AgentKit
//
//  会话列表 — 侧栏内容。从 `ConversationListViewModel` 读取数据。
//

import SwiftUI

struct ConversationListView: View {

    @State private var viewModel: ConversationListViewModel
    @Environment(WorkspaceStore.self) private var store
    @Binding var selected: ConversationRef?

    init(viewModel: ConversationListViewModel, selected: Binding<ConversationRef?>) {
        self.viewModel = viewModel
        self._selected = selected
    }

    var body: some View {
        List(selection: $selected) {
            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            ForEach(viewModel.conversations) { ref in
                ConversationRow(ref: ref)
                    .tag(ref)
            }
        }
        .listStyle(.sidebar)
        .task {
            await viewModel.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    // P5.0：不立即创建会话，只开一个本地草稿，等首条消息再创建。
                    store.beginDraft()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                }
            }
        }
    }
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let ref: ConversationRef

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ref.id)
                .font(.body)
                .lineLimit(1)
            Text("v1 — 无 metadata")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
