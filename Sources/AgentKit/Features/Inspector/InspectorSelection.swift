//
//  InspectorSelection.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import Foundation
import ClientToolProtocol

public enum InspectorSelection: Hashable {
    case file(FilePayload)
    case directory(DirectoryPayload)
    case diff(DiffPayload)
    case terminal(TerminalPayload)
    case asset(AssetPreviewPayload)
    case assets(AssetPanelPayload)
    case todo(String)
    case tool(String)
    case plan(String)
    case childStream(ChildStreamSelection)
    case workflowDAG(WorkflowDAGSelection)
    case timelineDocument(TimelineWebDocument)
    case conversationTrajectory(TrajectorySelection)
}

/// P8.9 — 调用轨迹查看器的选择载荷（DSH 式调用过程展示）。
/// `turnID` 非 nil = 只看那一轮的调用轨迹；nil = 全会话跨 turn 汇总。
/// 数据从 `WorkspaceStore.activeConversationViewModel.snapshot.turns` 实时读取，
/// 载荷只携带定位信息（轻量、Hashable，live 流变化时视图自动刷新）。
public struct TrajectorySelection: Sendable, Hashable {
    public let turnID: String?
    /// 面板标题：轮次摘要或会话标题。
    public let title: String

    public init(turnID: String?, title: String) {
        self.turnID = turnID
        self.title = title
    }
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

/// v1.3 — Workflow DAG 查看器的选择载荷。
public struct WorkflowDAGSelection: Sendable, Hashable {
    public let workflowID: String
    /// DAG 目标描述，用作面板标题。
    public let title: String?
    /// Phase 4：加载 snapshot 所需的 conversation ID。
    public let conversationID: String?

    public init(workflowID: String, title: String? = nil, conversationID: String? = nil) {
        self.workflowID = workflowID
        self.title = title
        self.conversationID = conversationID
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
