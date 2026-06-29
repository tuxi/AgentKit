//
//  ToolGroupView.swift
//  AgentKit
//
//  Renders a ToolGroup (a run of consecutive same-name tools) with a STABLE
//  footprint across its whole lifecycle — no "growing list → sudden ×N collapse"
//  thrash. Eager merge:
//  • single tool → one stable ToolCard (target shown inline, output on tap).
//  • a run of N → one compact block: "read_file ×N" + a single inline status
//    line for the currently-running tool ("→ design.md ⟳"). Tap to expand the
//    full list. Completed tools fold into the count; nothing auto-expands into
//    variable-height output, so the layout never jumps.
//

import SwiftUI

struct ToolGroupView: View {
    let group: ToolGroup
    let store: WorkspaceStore

    @State private var isExpanded = false

    private var running: ToolNodePayload? { group.tools.last { $0.status == .running } }
    private var hasFailure: Bool { group.tools.contains { $0.status == .failed } }

    var body: some View {
        if group.tools.count == 1 {
            ToolCard(tool: group.tools[0], store: store)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: headerIcon)
                            .font(.caption)
                            .foregroundStyle(headerColor)

                        // Summary + inline "current action". The whole text run
                        // shimmers while a tool is running — the line animates
                        // ("it's here now") instead of expanding.
                        HStack(spacing: 6) {
                            Text(group.summary)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)

                            if let running {
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if !running.argsSummary.isEmpty {
                                    Text(running.argsSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .shimmering(active: running != nil)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(group.tools, id: \.callID) { tool in
                        ToolCard(tool: tool, store: store)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var headerIcon: String {
        if running != nil { return "hourglass" }
        return hasFailure ? "xmark.circle" : "checkmark.circle"
    }

    private var headerColor: Color {
        if running != nil { return .secondary }
        return hasFailure ? .red : .green
    }
}
