//
//  WorkflowNodeDetailView.swift
//  AgentKit
//
//  v1.3 — 单个 Workflow 节点的详情 popup/sheet。
//  显示输入、输出、错误、耗时和 stream 输出。
//

import SwiftUI
import ClientToolProtocol

/// 节点详情 Sheet。
public struct WorkflowNodeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let node: WorkflowNode

    public init(node: WorkflowNode) {
        self.node = node
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drag indicator (iOS)
            #if os(iOS)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.quaternary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
            #endif

            // Header
            headerView
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.regularMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // State + progress
                    stateSection

                    // Input mapping（来自 plan_ready 的 $from 表达式）
                    if let mapping = node.inputMapping, case .object(let dict) = mapping, !dict.isEmpty {
                        collapsibleSection(
                            "Input Mapping", systemImage: "arrow.triangle.branch",
                            isExpanded: true
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(dict.keys.sorted()), id: \.self) { key in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(key)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 80, alignment: .trailing)
                                        Text(dict[key]?.stringValue ?? "\(dict[key] ?? .null)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if key != dict.keys.sorted().last {
                                        Divider()
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Output
                    if let output = node.output {
                        collapsibleSection(
                            "Output", systemImage: "arrow.up.doc.fill",
                            isExpanded: true
                        ) {
                            Text(output.prettyJSONString ?? "\(output)")
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Error
                    if let error = node.error, !error.isEmpty {
                        collapsibleSection(
                            "Error", systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        ) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Stream output
                    if !node.streamOutput.isEmpty {
                        collapsibleSection(
                            "Stream Output", systemImage: "text.alignleft",
                            isExpanded: false
                        ) {
                            ScrollView {
                                Text(node.streamOutput)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 160)
                        }
                    }

                    // Details
                    detailSection
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        #endif
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 10) {
            nodeIcon
                .font(.title2)
                .foregroundStyle(stateColor)
                .frame(width: 36, height: 36)
                .background(stateColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(node.typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let toolName = node.toolName {
                        Text("· \(toolName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            stateBadge
        }
    }

    private var nodeIcon: some View {
        switch node.type.lowercased() {
        case "start":
            return Image(systemName: "play.fill")
        case "end":
            return Image(systemName: "flag.checkered")
        case let t where t.contains("tool"):
            return Image(systemName: "wrench.adjustable.fill")
        case let t where t.contains("client"):
            return Image(systemName: "iphone.gen3")
        default:
            return Image(systemName: "square.stack.3d.up.fill")
        }
    }

    // MARK: - State section

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Progress bar
            ProgressView(value: node.progress) {
                HStack {
                    Text("Progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(node.progress * 100))%")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                }
            }
            .tint(stateColor)

            // State transition label
            HStack(spacing: 8) {
                Label("Status", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
        }
    }

    // MARK: - Detail section

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Details", systemImage: "info.circle.fill")

            VStack(spacing: 6) {
                detailRow("State", value: stateLabel, color: stateColor)
                detailRow("Terminal", value: node.terminal ? "Yes" : "No")
                if let ms = node.elapsedMs {
                    detailRow("Elapsed", value: ms >= 60_000
                        ? "\(ms / 60_000)m \((ms % 60_000) / 1000)s"
                        : ms >= 1000
                            ? String(format: "%.1fs", Double(ms) / 1000)
                            : "\(ms)ms")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func detailRow(_ label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(color ?? .primary)
        }
    }

    // MARK: - Reusable section

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.bottom, 2)
    }

    private func collapsibleSection<Content: View>(
        _ title: String, systemImage: String,
        tint: Color? = nil,
        isExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint ?? .primary)
            content()
        }
    }

    // MARK: - Helpers

    private var typeLabel: String {
        switch node.type.lowercased() {
        case "start":  return "Entry"
        case "end":    return "Exit"
        case "tool":   return "Tool"
        case "client": return "Client Tool"
        case "mcp":    return "MCP Tool"
        default:       return node.type
        }
    }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(stateColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var stateLabel: String {
        switch node.state {
        case .pending:               return "Pending"
        case .ready:                 return "Ready"
        case .running:               return "Running"
        case .awaiting:              return "Awaiting"
        case .retrying:              return "Retrying"
        case .successPendingEdges:   return "S‑Pending"
        case .failedPendingEdges:    return "F‑Pending"
        case .success:               return "Success"
        case .failed:                return "Failed"
        case .skipped:               return "Skipped"
        case .canceled:              return "Canceled"
        case .unknown(let v):        return v
        }
    }

    private var stateColor: Color {
        switch node.state {
        case .pending, .ready:       return .gray
        case .running, .retrying:    return .blue
        case .awaiting:              return .orange
        case .successPendingEdges:   return .teal
        case .failedPendingEdges:    return .red.opacity(0.6)
        case .success:               return .green
        case .failed:                return .red
        case .skipped:               return .gray.opacity(0.3)
        case .canceled:              return .gray.opacity(0.5)
        case .unknown:               return node.terminal ? .secondary : .blue
        }
    }
}
