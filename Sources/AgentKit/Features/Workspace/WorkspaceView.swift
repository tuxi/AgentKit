//
//  WorkspaceView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import SwiftUI

/// 跨平台的三栏工作区外壳：
///
/// - **macOS / iPad (regular)**：`NavigationSplitView` 并排二栏，右侧 inspector 可收起。
/// - **iPhone (compact)**：`NavigationStack` — 侧栏为根视图，选中会话/新建草稿时 push 到详情，
///   inspector 自动变为 sheet。这是 iOS 聊天应用的标准导航模式。
///
/// 平台 Root 视图只需 `WorkspaceView(dependencies:)` 一行接入。
public struct WorkspaceView: View {

    private let dependencies: AgentDependencies

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    @State private var router = AgentRouter()
    @State private var store: WorkspaceStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(dependencies: AgentDependencies) {
        self.dependencies = dependencies
        self._store = State(initialValue: WorkspaceStore(client: dependencies.client, toolRegistry: dependencies.toolRegistry))
    }

    public var body: some View {
        content
            #if os(iOS)
            .task {
                store.startLifecycleNetworkMonitor()
                await store.handleAppBecameActive()
            }
            .onChange(of: scenePhase) { _, newValue in
                switch newValue {
                case .active:
                    Task { await store.handleAppBecameActive() }
                case .background:
                    store.handleAppEnteredBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .compact {
            iOSCompactLayout
        } else {
            standardLayout
        }
    }

    // MARK: - iPhone (compact) — NavigationStack

    @ViewBuilder
    private var iOSCompactLayout: some View {
        NavigationStack(path: $router.path) {
            SidebarView()
                .navigationDestination(for: AgentNavigationDestination.self) { destination in
                    Group {
                        switch destination {
                        case .conversationDetail(let conversation):
                            ConversationDetailView(conversation: conversation)
                        case .draft:
                            ConversationDetailView(conversation: nil)
                        }
                    }
                    .inspector(isPresented: $store.isInspectorPresented) {
                        InspectorView(selection: store.inspectorSelection)
                    }
                }
        }
        .withAgentSheetDestinations(sheetDestinations: $router.presentedSheet, dependencies: dependencies)
        .withAgentCoverDestinations(coverDestinations: $router.presentedCover, dependencies: dependencies)
        .onChange(of: store.selectedConversation) { _, newValue in
            guard let ref = newValue else { return }
            // 选中会话 → push 到详情
            pushToDetailIfNeeded(.conversationDetail(conversation: ref))
        }
        .onChange(of: store.draftNavigationRevision) { _, _ in
            if store.draft != nil {
                // 新建草稿 → push 到详情
                pushToDetailIfNeeded(.draft)
            }
        }
        .onChange(of: router.path) { _, newPath in
            // 用户返回侧栏时清除选中态，确保再次点同一行仍可触发 push
            if newPath.isEmpty {
                store.selectedConversation = nil
            }
        }
        .environment(router)
        .environment(store)
    }

    /// 仅在当前 path 为空时 push（避免重复压栈）。
    private func pushToDetailIfNeeded(_ destination: AgentNavigationDestination) {
        guard router.path.isEmpty else { return }
        router.navigate(to: destination)
    }

    // MARK: - iPad / macOS (regular) — NavigationSplitView

    @ViewBuilder
    private var standardLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .platformSidebarColumnWidth()
        } detail: {
            NavigationStack(path: $router.path) {
                ConversationDetailView(conversation: store.selectedConversation)
                    .withAgentNavigationDestinations(router: router, dependencies: dependencies)
            }
            .inspector(isPresented: $store.isInspectorPresented) {
                InspectorView(selection: store.inspectorSelection)
                    .platformInspectorColumnWidth()
            }
        }
        .withAgentSheetDestinations(sheetDestinations: $router.presentedSheet, dependencies: dependencies)
        .withAgentCoverDestinations(coverDestinations: $router.presentedCover, dependencies: dependencies)
        .environment(router)
        .environment(store)
    }
}

// MARK: - Platform-Adaptive Column Widths

private extension View {
    /// 跨平台的侧栏列宽：macOS 用 min/max 范围，iOS 用固定值。
    @ViewBuilder
    func platformSidebarColumnWidth() -> some View {
        #if os(iOS)
        self.navigationSplitViewColumnWidth(320)
        #else
        self.navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        #endif
    }

    /// 跨平台的 inspector 列宽：macOS 用 min/max 范围，iOS 用固定值。
    @ViewBuilder
    func platformInspectorColumnWidth() -> some View {
        #if os(iOS)
        self.inspectorColumnWidth(320)
        #else
        self.inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        #endif
    }
}
