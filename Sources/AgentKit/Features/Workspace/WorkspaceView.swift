//
//  WorkspaceView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import SwiftUI

/// 跨平台的三栏工作区外壳：
/// 左 `SidebarView`（Tab + 列表） | 中 `ConversationDetailView`（对话详情） | 右 `.inspector`（点击详情）。
///
/// - macOS：`NavigationSplitView` 呈现并排三栏，右栏为可收起的 inspector。
/// - iOS：`NavigationSplitView` 自动折叠为导航栈，inspector 自动变为 sheet。
///
/// 平台 Root 视图只需 `WorkspaceView(dependencies:)` 一行接入。
public struct WorkspaceView: View {

    private let dependencies: AgentDependencies

    @State private var router = AgentRouter()
    @State private var store: WorkspaceStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(dependencies: AgentDependencies) {
        self.dependencies = dependencies
        // 从依赖注入 RuntimeClient + ToolRegistry 到 WorkspaceStore
        self._store = State(initialValue: WorkspaceStore(client: dependencies.client, toolRegistry: dependencies.toolRegistry))
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            NavigationStack(path: $router.path) {
                ConversationDetailView(conversation: store.selectedConversation)
                    .withAgentNavigationDestinations(router: router, dependencies: dependencies)
            }
            .inspector(isPresented: $store.isInspectorPresented) {
                InspectorView(selection: store.inspectorSelection)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
            }
        }
        .withAgentSheetDestinations(sheetDestinations: $router.presentedSheet, dependencies: dependencies)
        .withAgentCoverDestinations(coverDestinations: $router.presentedCover, dependencies: dependencies)
        .environment(router)
        .environment(store)
    }
}
