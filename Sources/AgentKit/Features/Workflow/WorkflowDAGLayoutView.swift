//
//  WorkflowDAGLayoutView.swift
//  AgentKit
//
//  v1.3 — DAG 拓扑渲染视图。
//  分层布局（简化 Sugiyama）：BFS 按依赖关系分层，层内居中对齐。
//  节点颜色按 WorkflowNodeState 着色，遵循协议 spec。
//

import SwiftUI

// MARK: - DAG Layout View

/// DAG 拓扑图 — 分层布局、箭头连线、节点状态着色。
public struct WorkflowDAGLayoutView: View {
    let nodes: [WorkflowNode]
    let edges: [WorkflowEdge]

    @State private var selectedNode: WorkflowNode?

    // 布局参数
    private let nodeWidth: CGFloat = 148
    private let nodeHeight: CGFloat = 60
    private let hGap: CGFloat = 32
    private let vGap: CGFloat = 64

    public init(nodes: [WorkflowNode], edges: [WorkflowEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public var body: some View {
        let layers = computeLayers()
        let positions = layoutPositions(layers: layers)

        let maxX = positions.values.map(\.x).max() ?? 0
        let maxY = positions.values.map(\.y).max() ?? 0
        let canvasWidth = max(maxX + nodeWidth + 24, 200)
        let canvasHeight = max(maxY + nodeHeight + 24, 100)

        ZStack(alignment: .topLeading) {
            // Edges — 画在底层
            ForEach(edges, id: \.self) { edge in
                if let fromPos = positions[edge.from],
                   let toPos = positions[edge.to] {
                    let fromCenter = CGPoint(x: fromPos.x + nodeWidth / 2,
                                             y: fromPos.y + nodeHeight)
                    let toCenter = CGPoint(x: toPos.x + nodeWidth / 2,
                                           y: toPos.y)
                    EdgeLine(from: fromCenter, to: toCenter)
                        .stroke(
                            Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1.5, dash: [])
                        )
                }
            }

            // Nodes
            ForEach(nodes) { node in
                if let pos = positions[node.name] {
                    WorkflowNodeCardView(node: node)
                        .frame(width: nodeWidth, height: nodeHeight)
                        .position(x: pos.x + nodeWidth / 2, y: pos.y + nodeHeight / 2)
                        .onTapGesture { selectedNode = node }
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .padding(4)
        .sheet(item: $selectedNode) { node in
            WorkflowNodeDetailView(node: node)
            #if os(macOS)
                .frame(minWidth: 320, idealWidth: 360, minHeight: 480)
            #endif
        }
    }

    // MARK: - Layout algorithm

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

        // BFS 分层
        var queue: [String] = inDegree.filter { $0.value == 0 }.map(\.key)
        var layerIndex: [String: Int] = [:]
        for name in queue { layerIndex[name] = 0 }

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let curLayer = layerIndex[current] ?? 0
            for neighbor in adjacency[current] ?? [] {
                let newLayer = curLayer + 1
                if layerIndex[neighbor, default: -1] < newLayer {
                    layerIndex[neighbor] = newLayer
                }
                inDegree[neighbor, default: 1] -= 1
                if inDegree[neighbor] == 0 { queue.append(neighbor) }
            }
        }

        // 孤立节点放最后一层
        for name in nodeNames where layerIndex[name] == nil {
            layerIndex[name] = (layerIndex.values.max() ?? 0) + 1
        }

        var layers: [[String]] = []
        for (name, layer) in layerIndex {
            while layers.count <= layer { layers.append([]) }
            layers[layer].append(name)
        }
        return layers
    }

    private func layoutPositions(layers: [[String]]) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let maxLayerWidth = CGFloat(layers.map(\.count).max() ?? 1) * nodeWidth
            + CGFloat(max(0, (layers.map(\.count).max() ?? 1) - 1)) * hGap

        for (layerIdx, layer) in layers.enumerated() {
            let layerWidth = CGFloat(layer.count) * nodeWidth
                + CGFloat(max(0, layer.count - 1)) * hGap
            // 每层在最大层宽内居中
            let layerStartX = (maxLayerWidth - layerWidth) / 2

            for (nodeIdx, name) in layer.enumerated() {
                let x = layerStartX + CGFloat(nodeIdx) * (nodeWidth + hGap)
                let y = CGFloat(layerIdx) * (nodeHeight + vGap)
                positions[name] = CGPoint(x: x, y: y)
            }
        }
        return positions
    }
}

// MARK: - Edge Line Shape

private struct EdgeLine: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)

        // 垂直方向的贝塞尔，带自然曲率
        let dy = abs(to.y - from.y)
        let curvature = min(dy * 0.4, 40)
        let midY = (from.y + to.y) / 2

        p.addCurve(
            to: to,
            control1: CGPoint(x: from.x, y: from.y + curvature),
            control2: CGPoint(x: to.x, y: to.y - curvature)
        )

        // Arrowhead at `to`
        let dx = to.x - from.x
        let dy2 = to.y - from.y
        let angle: CGFloat = dx == 0 && dy2 == 0 ? -.pi / 2
            : dy2 < 0 ? atan2(dy2, dx) - .pi / 2
            : atan2(dy2, dx)
        let arrowLen: CGFloat = 7
        let arrowA: CGFloat = .pi / 7

        let tip = to
        let p1 = CGPoint(
            x: tip.x - arrowLen * cos(angle - arrowA),
            y: tip.y - arrowLen * sin(angle - arrowA)
        )
        let p2 = CGPoint(
            x: tip.x - arrowLen * cos(angle + arrowA),
            y: tip.y - arrowLen * sin(angle + arrowA)
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

// MARK: - Node Card

/// DAG 中的单个节点卡片。
struct WorkflowNodeCardView: View {
    let node: WorkflowNode

    /// 是否在「活跃」状态（需要动态效果）。
    private var isActive: Bool {
        switch node.state {
        case .running, .retrying: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            // Icon + name
            HStack(spacing: 5) {
                nodeIcon
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(nodeStateColor)
                Text(node.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            // Type label
            Text(node.typeLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Progress bar (running nodes)
            if node.progress > 0 && node.progress < 1.0 {
                ProgressView(value: node.progress)
                    .tint(nodeStateColor)
                    .scaleEffect(0.7)
                    .frame(height: 3)
            }

            // State text for non-idle
            if !isIdleState {
                Text(stateAbbreviation)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(nodeStateColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(nodeStateColor.opacity(isActive ? 0.18 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(nodeStateColor.opacity(isActive ? 0.5 : 0.25), lineWidth: 1.5)
        )
        .shadow(color: nodeStateColor.opacity(isActive ? 0.15 : 0),
                radius: isActive ? 4 : 1, y: 1)
        .animation(.easeInOut(duration: 0.3), value: node.state)
    }

    // MARK: - Helpers

    private var nodeIcon: some View {
        switch node.type.lowercased() {
        case "start":
            return Image(systemName: "play.fill")
        case "end":
            return Image(systemName: "flag.checkered")
        case let t where t.contains("tool"):
            return Image(systemName: "wrench.adjustable.fill")
        case let t where t.contains("client"):
            return Image(systemName: "iphone")
        case let t where t.contains("mcp"):
            return Image(systemName: "globe")
        default:
            return Image(systemName: "square.stack.3d.up")
        }
    }

    private var isIdleState: Bool {
        switch node.state {
        case .pending, .ready, .success, .skipped, .canceled: return true
        default: return false
        }
    }

    private var stateAbbreviation: String {
        switch node.state {
        case .pending:              return "WAIT"
        case .ready:                return "RDY"
        case .running:              return "RUN"
        case .awaiting:             return "AWAIT"
        case .retrying:             return "RETRY"
        case .successPendingEdges:  return "S-PEND"
        case .failedPendingEdges:   return "F-PEND"
        case .success:              return ""
        case .failed:               return "FAIL"
        case .skipped:              return "SKIP"
        case .canceled:             return "CANCEL"
        case .unknown(let v):       return v.prefix(6).uppercased()
        }
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
            return .gray.opacity(0.35)
        case .canceled:
            return .gray.opacity(0.5)
        case .unknown:
            return node.terminal ? .secondary : .blue
        }
    }
}

// MARK: - Node type label

extension WorkflowNode {
    var typeLabel: String {
        switch type.lowercased() {
        case "start":  return "Entry"
        case "end":    return "Exit"
        case "tool":   return toolName ?? "Tool"
        case "client": return toolName ?? "Client"
        case "mcp":    return toolName ?? "MCP"
        default:       return type
        }
    }

    /// 输入映射的 key 列表，用于在节点卡片上紧凑展示。例如 "↳ content, path"。
    var inputMappingKeys: String? {
        guard let mapping = inputMapping, case .object(let dict) = mapping, !dict.isEmpty else {
            return nil
        }
        let keys = Array(dict.keys).sorted().prefix(4)
        let tail = dict.keys.count > 4 ? "…" : ""
        return "↳ " + keys.joined(separator: ", ") + tail
    }
}
