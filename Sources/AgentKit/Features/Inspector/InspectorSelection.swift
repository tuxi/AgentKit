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
    case uiEvidence(UIEvidenceSelection)
    case uiLayout(UILayoutSelection)
    case uiPreview(UIPreviewSelection)
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


/// Read-only Inspector destination for the raw `ui_evidence.v1` associated
/// with one tool call. Only the stable call identity is carried; the payload is
/// re-read from the resident conversation so live/replay stay in sync.
public struct UIEvidenceSelection: Sendable, Hashable {
    public let callID: String
    public let title: String

    public init(callID: String, title: String) {
        self.callID = callID
        self.title = title
    }
}

/// Read-only Inspector destination for the metadata of one persisted
/// `ui_layout_result.v1` revision. Only the stable call identity is carried;
/// the document and assets are re-read from the resident conversation.
public struct UILayoutSelection: Sendable, Hashable {
    public let callID: String
    public let title: String

    public init(callID: String, title: String) {
        self.callID = callID
        self.title = title
    }
}

/// Read-only Inspector destination for the lineage of one `ui_preview_result.v1`
/// record. Only the stable call identity is carried; the result, the preview
/// artifact, and the related layout/evidence assets are re-read from the
/// resident conversation so live and replay stay in sync.
public struct UIPreviewSelection: Sendable, Hashable {
    public let callID: String
    public let title: String

    public init(callID: String, title: String) {
        self.callID = callID
        self.title = title
    }
}
