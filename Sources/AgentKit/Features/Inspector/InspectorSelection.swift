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
