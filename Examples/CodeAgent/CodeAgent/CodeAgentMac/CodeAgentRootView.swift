//
//  CodeAgentRootView.swift
//  CodeAgent
//
//  轻量示例：演示 AgentKit 最小集成。
//  完整 Shell（Sidebar + Settings + Account）见独立 CodeAgent 仓库。
//

#if os(macOS)

import SwiftUI
import AgentKit

struct CodeAgentRootView: View {

    @State private var store: WorkspaceStore
    @State private var router = AgentRouter()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(dependencies: AgentDependencies) {
        self._store = State(initialValue: WorkspaceStore(
            client: dependencies.client,
            toolRegistry: dependencies.toolRegistry,
            timelineExtensions: dependencies.timelineExtensions,
            conversationRendererMode: dependencies.conversationRendererMode,
            onAuthExpired: dependencies.onAuthExpired,
            localStateStore: dependencies.localStateStore,
            attentionReadStore: dependencies.attentionReadStore,
            onAttentionEvent: dependencies.onAttentionEvent
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(
                viewModel: store.listViewModel,
                selected: $store.selectedConversation
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            ConversationDetailView(conversation: store.selectedConversation)
                .inspector(isPresented: $store.isInspectorPresented) {
                    InspectorView(selection: store.inspectorSelection)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
                }
        }
        .environment(store)
        .environment(router)
    }
}

#endif
