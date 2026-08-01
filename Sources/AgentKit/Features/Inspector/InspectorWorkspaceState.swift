//
//  InspectorWorkspaceState.swift
//  AgentKit
//
//  Created by Codex on 2026/8/1.
//

import Foundation
import Observation

/// 宿主长生命周期资源与 Inspector 标签之间的稳定绑定点。
///
/// `hostResourceID` 可在终端、浏览器和侧边聊天接入时记录宿主资源标识；切换 SwiftUI
/// 视图不会改变 session 身份。
@MainActor
@Observable
public final class InspectorSessionState: Identifiable {
    public let id: UUID
    public let entry: InspectorEntry
    public var hostResourceID: String?
    /// 文件入口当前选中的实时工作区路径；与时间线 `FilePayload` 快照分离。
    public var selectedFilePath: String?

    public init(
        id: UUID = UUID(),
        entry: InspectorEntry,
        hostResourceID: String? = nil,
        selectedFilePath: String? = nil
    ) {
        self.id = id
        self.entry = entry
        self.hostResourceID = hostResourceID
        self.selectedFilePath = selectedFilePath
    }
}

/// 单个 Inspector 标签的长期状态。
///
/// 标签对象由 conversation 对应的 `InspectorWorkspaceState` 持有；Inspector 隐藏或
/// 切换标签时对象不会销毁，因此入口内部的导航路径可以稳定恢复。
@MainActor
@Observable
public final class InspectorTabState: Identifiable {
    public let id: UUID
    public let session: InspectorSessionState
    public let pathState: InspectorPathState

    public var entry: InspectorEntry { session.entry }

    public init(
        id: UUID = UUID(),
        entry: InspectorEntry,
        session: InspectorSessionState? = nil,
        pathState: InspectorPathState = InspectorPathState()
    ) {
        self.id = id
        if let session {
            precondition(session.entry == entry, "Inspector tab and session entries must match")
            self.session = session
        } else {
            self.session = InspectorSessionState(entry: entry)
        }
        self.pathState = pathState
    }
}

/// 一个 conversation 对应的 Inspector 工作台状态。
///
/// 资源本体（PTY、WebView、辅助 conversation）仍由宿主持有；这里保存稳定的标签身份、
/// 选择关系与 Inspector 内部导航状态。
@MainActor
@Observable
public final class InspectorWorkspaceState {
    public let conversationID: String?
    public private(set) var tabs: [InspectorTabState]
    public var selectedTabID: InspectorTabState.ID?
    public var isPresented: Bool
    public var selection: InspectorSelection?

    /// 时间线产物详情使用独立 path，避免覆盖任一长期入口标签的导航历史。
    public let selectionPathState: InspectorPathState

    public init(
        conversationID: String? = nil,
        tabs: [InspectorTabState] = [],
        selectedTabID: InspectorTabState.ID? = nil,
        isPresented: Bool = false,
        selection: InspectorSelection? = nil,
        selectionPathState: InspectorPathState = InspectorPathState()
    ) {
        self.conversationID = conversationID
        self.tabs = tabs
        self.selectedTabID = selectedTabID.flatMap { selectedID in
            tabs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        self.isPresented = isPresented
        self.selection = selection
        self.selectionPathState = selectionPathState
    }

    public var selectedTab: InspectorTabState? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    /// 打开入口。默认复用同类标签，避免主入口反复点击产生重复会话。
    @discardableResult
    public func open(_ entry: InspectorEntry, reusingExisting: Bool = true) -> InspectorTabState {
        if reusingExisting, let existing = tabs.first(where: { $0.entry == entry }) {
            selectedTabID = existing.id
            return existing
        }

        let tab = InspectorTabState(entry: entry)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    public func select(tabID: InspectorTabState.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
    }

    /// 回到主入口页，但保留所有标签与各自导航状态。
    public func showLanding() {
        selectedTabID = nil
    }

    public func close(tabID: InspectorTabState.ID) {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasSelected = selectedTabID == tabID
        tabs.remove(at: closingIndex)

        guard wasSelected else { return }
        guard !tabs.isEmpty else {
            selectedTabID = nil
            return
        }

        selectedTabID = tabs[min(closingIndex, tabs.count - 1)].id
    }
}
