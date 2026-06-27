//
//  WorkbenchState.swift
//  AgentKit
//
//  P4.5: Workbench 状态机 — 独立于 ConversationViewModel 的状态树。
//  Timeline 是导航栏，Workbench 是内容面板。
//

import SwiftUI

// MARK: - WorkbenchState

/// Workbench 预览面板的 UI 状态。
/// 不挂靠 ConversationViewModel — 独立状态树，未来可扩展 Preview/Inspector/Graph/Tabs。
@MainActor
@Observable
public final class WorkbenchState {

    /// 当前选中的 WorkProduct ID（即 callID）。
    public var selectedWorkProductID: String?

    /// 当前选中的 Turn ID（为 Next/Previous/Graph Navigation 预留）。
    public var selectedTurnID: String?

    // MARK: - Init

    public init() {}

    // MARK: - Actions

    public func select(workProductID: String, turnID: String?) {
        // Toggle: 再次点击同一项取消选中
        if selectedWorkProductID == workProductID {
            selectedWorkProductID = nil
            selectedTurnID = nil
        } else {
            selectedWorkProductID = workProductID
            selectedTurnID = turnID
        }
    }

    public func deselect() {
        selectedWorkProductID = nil
        selectedTurnID = nil
    }
}
