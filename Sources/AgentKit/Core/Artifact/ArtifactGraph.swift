//
//  ArtifactGraph.swift
//  AgentKit
//
//  Artifact 语义图 — nodes + typed edges。
//  v4.3: 从 flat dict 升级为 formal graph，支持关系查询和 graph viewer。
//

import Foundation

// MARK: - ArtifactGraph

/// Artifact 语义图：一个 turn 内所有 artifact 及它们之间的关系。
/// 替代 v4.1/v4.2 的 `[String: ArtifactNode]` flat dictionary。
public struct ArtifactGraph: Sendable {

    /// callID → ArtifactNode
    public var nodes: [String: ArtifactNode]

    /// 有向边列表
    public var edges: [ArtifactEdge]

    // MARK: - Init

    public init(nodes: [String: ArtifactNode] = [:], edges: [ArtifactEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    // MARK: - Accessors

    public var isEmpty: Bool { nodes.isEmpty }

    public var allNodes: [ArtifactNode] { Array(nodes.values) }

    public func node(for callID: String) -> ArtifactNode? {
        nodes[callID]
    }

    /// 从指定节点出发的边。
    public func edges(from callID: String) -> [ArtifactEdge] {
        edges.filter { $0.from == callID }
    }

    /// 指向指定节点的边。
    public func edges(to callID: String) -> [ArtifactEdge] {
        edges.filter { $0.to == callID }
    }

    /// 与指定节点相关的所有节点 callID。
    public func related(to callID: String) -> [String] {
        var ids = Set<String>()
        for edge in edges {
            if edge.from == callID { ids.insert(edge.to) }
            if edge.to == callID { ids.insert(edge.from) }
        }
        return Array(ids)
    }

    // MARK: - Mutations

    /// Upsert 一个节点（按 callID）。
    public mutating func upsert(_ node: ArtifactNode) {
        nodes[node.callID] = node
    }

    /// 添加一条边（去重：同 from+to+type 不重复添加）。
    public mutating func addEdge(_ edge: ArtifactEdge) {
        guard !edges.contains(where: {
            $0.from == edge.from && $0.to == edge.to && $0.type == edge.type
        }) else { return }
        edges.append(edge)
    }

    /// 移除指定 callID 的节点及其关联边。
    public mutating func remove(_ callID: String) {
        nodes.removeValue(forKey: callID)
        edges.removeAll { $0.from == callID || $0.to == callID }
    }
}

// MARK: - ArtifactEdge

/// Artifact 图中的有向边。
public struct ArtifactEdge: Identifiable, Sendable, Hashable {
    public var id: String { "\(from)→\(to):\(type.rawValue)" }

    /// 源节点 callID。
    public let from: String
    /// 目标节点 callID。
    public let to: String
    /// 关系类型。
    public let type: RelationType

    public init(from: String, to: String, type: RelationType) {
        self.from = from
        self.to = to
        self.type = type
    }
}

// MARK: - RelationType

/// Artifact 关系类型。
public enum RelationType: String, Sendable, CaseIterable {
    /// tool 执行直接产出此 artifact（tool → artifact）
    case produces
    /// artifact 是另一个 artifact 的预览（diff → file）
    case previews
    /// artifact 从另一个派生（write_file diff → read_file content）
    case derives
    /// artifact 引用另一个（交叉引用）
    case references
}
