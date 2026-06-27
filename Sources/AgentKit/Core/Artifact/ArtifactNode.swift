//
//  ArtifactNode.swift
//  AgentKit
//
//  Work Product 语义图节点 — P4.4 work-product-centric 模型。
//  三层 UI 结构：summary（运行时渲染）→ path（元数据）→ content（可滚动详情）。
//  双 kind 模型：WorkProductKind（语义层）+ ArtifactKind（渲染层）。
//

import Foundation

// MARK: - ArtifactNode

/// 工具执行产生的 Work Product 节点。
///
/// Identity = `callID`（协议级 tool identity）。
///
/// 双 kind 设计：
/// - `kind: WorkProductKind` — 语义层（fileEdited/fileCreated/commandRun...），决定 icon、分组
/// - `renderKind: ArtifactKind` — 渲染层（diff/file/terminal），决定使用哪个 Body View
///
/// Summary 不存储 — 由 `SummaryRenderer` 运行时生成（i18n-ready）。
public struct ArtifactNode: Identifiable, Sendable, Hashable {

    // MARK: - Identity

    public var id: String { callID }
    public let callID: String
    public let turnID: String

    // MARK: - Dual kind

    /// 语义种类（Work Product 视角）。
    public let kind: WorkProductKind
    /// 渲染种类（View 选择）。
    public let renderKind: ArtifactKind

    // MARK: - Metadata & content

    /// 文件路径或命令（可导航的元数据，不在滚动区域内）。
    public let path: String?
    /// 可滚动详情内容。
    public let content: ArtifactContent

    // MARK: - Init

    public init(
        callID: String,
        turnID: String,
        kind: WorkProductKind,
        renderKind: ArtifactKind,
        path: String?,
        content: ArtifactContent
    ) {
        self.callID = callID
        self.turnID = turnID
        self.kind = kind
        self.renderKind = renderKind
        self.path = path
        self.content = content
    }
}
