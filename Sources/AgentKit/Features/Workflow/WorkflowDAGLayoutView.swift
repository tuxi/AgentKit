//
//  WorkflowDAGLayoutView.swift
//  AgentKit
//
//  v1.3 — DAG 拓扑渲染视图。
//  分层布局（简化 Sugiyama）：BFS 按依赖关系分层，层内居中对齐。
//  节点颜色按 WorkflowNodeState 着色，遵循协议 spec。
//

import SwiftUI

/// DAG 拓扑图 — 分层布局、箭头连线、节点状态着色。
public struct WorkflowDAGLayoutView: View {
    let nodes: [WorkflowNode]
    let edges: [WorkflowEdge]

    @State private var selectedNode: WorkflowNode?

    // 布局参数
    private let nodeWidth: CGFloat = 140
    private let nodeHeight: CGFloat = 52
    private let hGap: CGFloat = 24
    private let vGap: CGFloat = 56

    public init(nodes: [WorkflowNode], edges: [WorkflowEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public var body: some View {
        let layers = computeLayers()
        let positions = layoutPositions(layers: layers)

        // 计算画布大小
        let maxX = positions.values.map(\.x).max() ?? 0
        let maxY = positions.values.map(\.y).max() ?? 0
        let canvasWidth = maxX + nodeWidth + 20
        let canvasHeight = maxY + nodeHeight + 20

        ZStack(alignment: .topLeading) {
            // Edges
            ForEach(edges, id: \.self) { edge in
                if let fromPos = positions[edge.from],
                   let toPos = positions[edge.to] {
                    EdgeLine(from: edgeCenter(fromPos, nodeWidth: nodeWidth, nodeHeight: nodeHeight),
                             to: edgeCenter(toPos, nodeWidth: nodeWidth, nodeHeight: nodeHeight))
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                }
            }

            // Nodes
            ForEach(nodes, id: \.name) { node in
                if let pos = positions[node.name] {
                    WorkflowNodeCardView(node: node)
                        .frame(width: nodeWidth, height: nodeHeight)
                        .position(x: pos.x + nodeWidth / 2, y: pos.y + nodeHeight / 2)
                        .onTapGesture {
                            selectedNode = node
                        }
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .sheet(item: $selectedNode) { node in
            WorkflowNodeDetailView(node: node)
            #if os(macOS)
                .frame(width: 300)
                .frame(height: 500)
            #endif
        }
    }

    private func edgeCenter(_ pos: CGPoint, nodeWidth: CGFloat, nodeHeight: CGFloat) -> CGPoint {
        CGPoint(x: pos.x + nodeWidth / 2, y: pos.y + nodeHeight / 2)
    }

    // MARK: - Layout algorithm

    /// 简化 Sugiyama: BFS 按依赖关系分层。
    private func computeLayers() -> [[String]] {
        let nodeNames = Set(nodes.map(\.name))
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for name in nodeNames {
            inDegree[name] = 0
            adjacency[name] = []
        }

        for edge in edges {
            guard nodeNames.contains(edge.from), nodeNames.contains(edge.to) else { continue }
            inDegree[edge.to, default: 0] += 1
            adjacency[edge.from, default: []].append(edge.to)
        }

        // BFS from sources (in-degree 0)
        var queue: [String] = inDegree.filter { $0.value == 0 }.map(\.key)
        var layerIndex: [String: Int] = [:]
        for name in queue { layerIndex[name] = 0 }

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let currentLayer = layerIndex[current] ?? 0
            for neighbor in adjacency[current] ?? [] {
                let newLayer = currentLayer + 1
                if layerIndex[neighbor, default: -1] < newLayer {
                    layerIndex[neighbor] = newLayer
                }
                inDegree[neighbor, default: 1] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // 未到达的节点（孤立）放最后一层
        for name in nodeNames where layerIndex[name] == nil {
            layerIndex[name] = (layerIndex.values.max() ?? 0) + 1
        }

        // 按层分组
        var layers: [[String]] = []
        for (name, layer) in layerIndex {
            while layers.count <= layer { layers.append([]) }
            layers[layer].append(name)
        }

        return layers
    }

    /// 计算每个节点的绝对位置。
    private func layoutPositions(layers: [[String]]) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        for (layerIdx, layer) in layers.enumerated() {
            let totalWidth = CGFloat(layer.count) * nodeWidth + CGFloat(max(0, layer.count - 1)) * hGap
            let startX = totalWidth < nodeWidth ? 0 : -(totalWidth - nodeWidth) / 2

            // 居中整个画布偏移
            let centerOffsetX = max(0, (CGFloat(layers.map(\.count).max() ?? 1) * nodeWidth + CGFloat(max(0, (layers.map(\.count).max() ?? 1) - 1)) * hGap) / 2)

            for (nodeIdx, name) in layer.enumerated() {
                let x = centerOffsetX + startX + CGFloat(nodeIdx) * (nodeWidth + hGap)
                let y = CGFloat(layerIdx) * (nodeHeight + vGap)
                positions[name] = CGPoint(x: x, y: y)
            }
        }
        return positions
    }
}

// MARK: - Edge line shape

private struct EdgeLine: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)

        // Simple spline: horizontal → vertical → horizontal
        let midY = (from.y + to.y) / 2
        p.addCurve(
            to: to,
            control1: CGPoint(x: from.x, y: midY),
            control2: CGPoint(x: to.x, y: midY)
        )

        // Arrowhead
        let dx = to.x - from.x
        let dy = to.y - from.y
        let angle = atan2(dy, dx)
        let arrowLen: CGFloat = 8
        let arrowAngle: CGFloat = .pi / 6

        let tip = to
        let p1 = CGPoint(
            x: tip.x - arrowLen * cos(angle - arrowAngle),
            y: tip.y - arrowLen * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: tip.x - arrowLen * cos(angle + arrowAngle),
            y: tip.y - arrowLen * sin(angle + arrowAngle)
        )

        var arrowPath = Path()
        arrowPath.move(to: tip)
        arrowPath.addLine(to: p1)
        arrowPath.addLine(to: p2)
        arrowPath.closeSubpath()
        p.addPath(arrowPath)

        return p
    }
}

// MARK: - Node card

/// DAG 中的单个节点卡片。
struct WorkflowNodeCardView: View {
    let node: WorkflowNode

    var body: some View {
        VStack(spacing: 2) {
            Text(node.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(node.type)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if node.progress > 0 && node.progress < 1.0 {
                ProgressView(value: node.progress)
                    .scaleEffect(0.6)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(nodeStateColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(nodeStateColor.opacity(0.3), lineWidth: 1.5)
        )
    }

    private var nodeStateColor: Color {
        switch node.state {
        case .pending, .ready:
            return .gray
        case .running, .retrying:
            return .blue
        case .awaiting:
            return .orange
        case .successPendingEdges:
            return .teal
        case .failedPendingEdges:
            return .red.opacity(0.6)
        case .success:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .gray.opacity(0.3)
        case .canceled:
            return .gray.opacity(0.5)
        case .unknown:
            // 按 terminal 字段回退
            return node.terminal ? .secondary : .blue
        }
    }
}
