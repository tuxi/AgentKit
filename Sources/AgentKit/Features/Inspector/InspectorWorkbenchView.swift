//
//  InspectorWorkbenchView.swift
//  AgentKit
//
//  Created by Codex on 2026/8/1.
//

import SwiftUI

/// Inspector 的推荐主入口。
///
/// 无选中内容时展示稳定的五入口工作台；从时间线打开产物后，继续复用
/// `InspectorNavigationView` 或旧的 `InspectorView` 内容链路。
///
/// 工作台通过 `InspectorWorkspaceState` 保存入口标签和各自的导航状态；宿主继续通过
/// `onOpenEntry` 创建或唤醒 PTY、WebView、文件浏览器与辅助 conversation 等资源。
public struct InspectorWorkbenchView: View {
    public let selection: InspectorSelection?
    public let fileProvider: (any FileContentProvider)?
    public let usesNavigationStack: Bool
    public let onOpenEntry: (InspectorEntry) -> Void
    public let onOpenTab: ((InspectorTabState) -> Void)?
    public let tabContent: (InspectorTabState) -> AnyView?

    private let workspaceState: InspectorWorkspaceState?
    @State private var ownedWorkspaceState = InspectorWorkspaceState()

    public init(
        selection: InspectorSelection?,
        fileProvider: (any FileContentProvider)? = nil,
        usesNavigationStack: Bool = true,
        workspaceState: InspectorWorkspaceState? = nil,
        onOpenEntry: @escaping (InspectorEntry) -> Void,
        onOpenTab: ((InspectorTabState) -> Void)? = nil,
        tabContent: @escaping (InspectorTabState) -> AnyView? = { _ in nil }
    ) {
        self.selection = selection
        self.fileProvider = fileProvider
        self.usesNavigationStack = usesNavigationStack
        self.workspaceState = workspaceState
        self.onOpenEntry = onOpenEntry
        self.onOpenTab = onOpenTab
        self.tabContent = tabContent
    }

    public var body: some View {
        let state = workspaceState ?? ownedWorkspaceState

        Group {
            if let selection, usesNavigationStack {
                InspectorNavigationView(
                    initialSelection: selection,
                    fileProvider: fileProvider,
                    pathState: state.selectionPathState
                )
            } else if let selection {
                InspectorView(selection: selection)
            } else {
                InspectorTabWorkbench(
                    state: state,
                    usesNavigationStack: usesNavigationStack,
                    onOpenEntry: onOpenEntry,
                    onOpenTab: onOpenTab,
                    tabContent: tabContent
                )
            }
        }
    }
}

private struct InspectorTabWorkbench: View {
    let state: InspectorWorkspaceState
    let usesNavigationStack: Bool
    let onOpenEntry: (InspectorEntry) -> Void
    let onOpenTab: ((InspectorTabState) -> Void)?
    let tabContent: (InspectorTabState) -> AnyView?

    var body: some View {
        VStack(spacing: 0) {
            if !state.tabs.isEmpty {
                InspectorTabBar(state: state)
                Divider()
            }

            if let tab = state.selectedTab {
                InspectorEntryPane(
                    tab: tab,
                    usesNavigationStack: usesNavigationStack,
                    content: tabContent(tab) ?? AnyView(
                        InspectorEntryUnavailableView(entry: tab.entry)
                    )
                )
                .id(tab.id)
            } else {
                InspectorLandingView { entry in
                    let tab = state.open(entry, reusingExisting: false)
                    onOpenEntry(entry)
                    onOpenTab?(tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorTabBar: View {
    let state: InspectorWorkspaceState

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(state.tabs) { tab in
                        HStack(spacing: 6) {
                            Button {
                                state.select(tabID: tab.id)
                            } label: {
                                Label(tab.entry.title, systemImage: tab.entry.systemImage)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)

                            Button {
                                state.close(tabID: tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭\(tab.entry.title)")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            state.selectedTabID == tab.id
                                ? Color.secondary.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .accessibilityIdentifier("inspector.tab.\(tab.id.uuidString)")
                    }
                }
            }
            .scrollIndicators(.hidden)

            Button {
                state.showLanding()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建 Inspector 标签")
            .accessibilityIdentifier("inspector.tab.new")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }
}

private struct InspectorEntryPane: View {
    let tab: InspectorTabState
    let usesNavigationStack: Bool
    let content: AnyView

    var body: some View {
        if usesNavigationStack {
            InspectorEntryNavigationContent(tab: tab, content: content)
        } else {
            content
                .environment(\.inspectorPathState, tab.pathState)
        }
    }
}

private struct InspectorEntryNavigationContent: View {
    let tab: InspectorTabState
    let content: AnyView

    var body: some View {
        @Bindable var path = tab.pathState

        NavigationStack(path: $path.path) {
            content
        }
        .environment(\.inspectorPathState, path)
        .onAppear { path.isActive = true }
        .onDisappear { path.isActive = false }
    }
}

private struct InspectorEntryUnavailableView: View {
    let entry: InspectorEntry

    var body: some View {
        ContentUnavailableView(
            "\(entry.title)正在接入",
            systemImage: entry.systemImage,
            description: Text("标签会话已经保留，具体工具将在后续阶段接入。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorLandingView: View {
    let onOpenEntry: (InspectorEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 4) {
                ForEach(InspectorEntry.allCases) { entry in
                    Button {
                        onOpenEntry(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.systemImage)
                                .frame(width: 20)

                            Text(entry.title)

                            Spacer(minLength: 24)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inspector.entry.\(entry.rawValue)")
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.landing")
    }
}

#Preview("Inspector Workbench Landing") {
    InspectorWorkbenchView(selection: nil) { _ in }
        .frame(width: 520, height: 640)
}
