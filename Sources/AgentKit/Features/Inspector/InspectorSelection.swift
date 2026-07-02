//
//  InspectorSelection.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import Foundation

public enum InspectorSelection: Hashable {
    case file(FilePayload)
    case diff(DiffPayload)
    case terminal(TerminalPayload)
    case asset(AssetPreviewPayload)
    case assets(AssetPanelPayload)
    case todo(String)
    case tool(String)
    case plan(String)
    case childStream(ChildStreamSelection)
}

/// P8.7 — 子流查看器（task 子agent / 后台 job）的选择载荷。
/// macOS 走右侧 `.inspector` 面板，iPhone 上系统自动降级为 sheet。
public struct ChildStreamSelection: Sendable, Hashable {
    public let childID: String
    public let kind: ChildStreamKind
    /// task 的委派 prompt / job 的 command，用作面板标题。
    public let title: String

    public init(childID: String, kind: ChildStreamKind, title: String) {
        self.childID = childID
        self.kind = kind
        self.title = title
    }
}

public struct AssetPreviewPayload: Sendable, Hashable {
    public let asset: AgentAssetRef
    public let conversationID: String?
    public let workspace: WorkspaceAnchor?

    public init(
        asset: AgentAssetRef,
        conversationID: String? = nil,
        workspace: WorkspaceAnchor? = nil
    ) {
        self.asset = asset
        self.conversationID = conversationID
        self.workspace = workspace
    }
}

public struct AssetPanelPayload: Sendable, Hashable {
    public let title: String
    public let assets: [AgentAssetRef]
    public let conversationID: String?
    public let workspace: WorkspaceAnchor?

    public init(
        title: String,
        assets: [AgentAssetRef],
        conversationID: String? = nil,
        workspace: WorkspaceAnchor? = nil
    ) {
        self.title = title
        self.assets = assets
        self.conversationID = conversationID
        self.workspace = workspace
    }
}
