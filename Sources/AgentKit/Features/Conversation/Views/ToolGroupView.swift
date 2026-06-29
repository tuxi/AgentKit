//
//  ToolGroupView.swift
//  AgentKit
//
//  Renders a ToolGroup (a run of consecutive same-name tools).
//  • A single tool, or any tool still running → individual ToolCard(s), so the
//    active tool stays visible while it executes.
//  • A finished run of 2+ → one compact "name ×N" row, expandable to the list.
//

import SwiftUI

struct ToolGroupView: View {
    let group: ToolGroup
    let store: WorkspaceStore

    @State private var isExpanded = false

    private var anyRunning: Bool { group.tools.contains { $0.status == .running } }
    private var canMerge: Bool { group.tools.count > 1 && !anyRunning }

    var body: some View {
        if canMerge {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mergedIcon)
                            .font(.caption)
                            .foregroundStyle(mergedColor)
                        Text(group.summary)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(group.tools, id: \.callID) { tool in
                        ToolCard(tool: tool, store: store, activeToolCallID: nil)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ForEach(group.tools, id: \.callID) { tool in
                ToolCard(tool: tool, store: store, activeToolCallID: group.activeToolCallID)
            }
        }
    }

    private var hasFailure: Bool { group.tools.contains { $0.status == .failed } }
    private var mergedIcon: String { hasFailure ? "xmark.circle" : "checkmark.circle" }
    private var mergedColor: Color { hasFailure ? .red : .green }
}
