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
        NavigationStack {
            List {
                // Header
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name)
                                .font(.headline)
                            Text(node.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let toolName = node.toolName {
                                Text("Tool: \(toolName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        stateBadge
                    }
                }

                // Progress
                Section("Progress") {
                    ProgressView(value: node.progress) {
                        Text("\(Int(node.progress * 100))%")
                    }
                }

                // Output
                if let output = node.output {
                    Section("Output") {
                        Text(output.prettyJSONString ?? "\(output)")
                            .font(.caption.monospaced())
                    }
                }

                // Error
                if let error = node.error {
                    Section("Error") {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Stream output (transient)
                if !node.streamOutput.isEmpty {
                    Section("Stream Output") {
                        ScrollView {
                            Text(node.streamOutput)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                }

                // Metadata
                Section("Details") {
                    LabeledContent("State", value: stateLabel)
                    LabeledContent("Terminal", value: node.terminal ? "Yes" : "No")
                    if let ms = node.elapsedMs {
                        LabeledContent("Elapsed", value: ms >= 1000
                            ? String(format: "%.1fs", Double(ms) / 1000)
                            : "\(ms)ms")
                    }
                }
            }
            .navigationTitle("Node Detail")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: platformToolbarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16))
                            .clipShape(Circle())
                    }

                }

            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private var platformToolbarTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .cancellationAction
        #endif
    }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        case .successPendingEdges:   return "Success (Pending Edges)"
        case .failedPendingEdges:    return "Failed (Pending Edges)"
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
