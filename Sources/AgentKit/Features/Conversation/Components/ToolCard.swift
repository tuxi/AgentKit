//
//  ToolCard.swift
//  AgentKit
//
//  Chronological tool execution card.
//  Shows spinner while running, output on expand, Inspector link for artifacts.
//

import SwiftUI

struct ToolCard: View {
    let tool: ToolNodePayload
    let store: WorkspaceStore
    /// The callID of the tool the parent timeline wants expanded. Read-only —
    /// only one tool is expanded at a time, matching Claude Code behaviour. The
    /// card never writes this back or coordinates with its siblings; the
    /// projection (TimelineProjection.activeToolCallID) owns all the rules.
    let activeToolCallID: String?
    @State private var isExpanded: Bool

    init(tool: ToolNodePayload, store: WorkspaceStore, activeToolCallID: String?) {
        self.tool = tool
        self.store = store
        self.activeToolCallID = activeToolCallID
        // Expand iff the parent designated this card as the active one.
        self._isExpanded = State(initialValue: tool.callID == activeToolCallID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ── Header ──
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    Text(tool.toolName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if tool.status == .running {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }

                    if tool.isAutoApproved {
                        Text("auto")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 3)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }

                    if let elapsed = tool.elapsedMs {
                        Text(formatElapsed(elapsed))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let code = tool.exitCode, code != 0 {
                        Text("exit \(code)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // ── Expanded content ──
            if isExpanded {
                Divider()
                    .padding(.vertical, 2)

                // Args
                if let args = tool.args, case .object(let dict) = args, !dict.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(dict.keys.sorted()), id: \.self) { key in
                            Text("\(key): \(dict[key]?.stringValue ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Output
                if !tool.output.isEmpty {
                    Text(tool.output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                        .textSelection(.enabled)
                }

                // Artifact
                if let artifact = tool.artifact {
                    Divider()
                        .padding(.vertical, 2)

                    // Diff artifacts: render inline with green/red coloring
                    if case .diff(let diffPayload) = artifact.content {
                        DiffInlineView(diff: diffPayload, artifact: artifact, store: store)
                    } else {
                        // File/terminal artifacts: Inspector link
                        Button {
                            openInInspector(artifact)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: artifactIcon(for: artifact))
                                    .font(.caption2)
                                Text(SummaryRenderer.summary(for: artifact))
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: activeToolCallID) { _, newID in
            // The parent re-designated the active tool: expand iff it's me,
            // collapse otherwise. This single read-only reaction covers every
            // case the old @Binding coordination tried to handle — a tool
            // starting (I become active), the slot moving to the next tool, and
            // the assistant answer arriving (parent clears the slot → collapse
            // all). A user's manual tap still toggles isExpanded freely between
            // these events.
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = (newID == tool.callID)
            }
        }
    }

    // MARK: - Helpers

    private var statusIcon: String {
        if tool.isAutoApproved { return "bolt.fill" }
        switch tool.status {
        case .running: return "hourglass"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .autoApproved: return "bolt.fill"
        }
    }

    private var statusColor: Color {
        if tool.isAutoApproved { return .blue }
        switch tool.status {
        case .running: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .autoApproved: return .blue
        }
    }

    private func formatElapsed(_ ms: Int) -> String {
        if ms >= 1000 {
            String(format: "%.1fs", Double(ms) / 1000.0)
        } else {
            "\(ms)ms"
        }
    }

    private func artifactIcon(for artifact: ArtifactNode) -> String {
        switch artifact.kind {
        case .fileRead: return "doc.text"
        case .fileCreated: return "doc.badge.plus"
        case .fileEdited: return "arrow.triangle.swap"
        case .commandRun: return "terminal"
        case .listFiles: return "folder.fill"
        }
    }

    private func openInInspector(_ artifact: ArtifactNode) {
        switch artifact.content {
        case .file(let payload):
            store.showInspector(.file(payload))
        case .diff(let payload):
            store.showInspector(.diff(payload))
        case .terminal(let payload):
            store.showInspector(.terminal(payload))
        }
    }
}

// MARK: - DiffInlineView

/// Renders unified diff lines in place — green for additions, red for removals.
/// Avoids requiring the user to open the right-side Inspector for quick diffs.
private struct DiffInlineView: View {
    let diff: DiffPayload
    let artifact: ArtifactNode
    let store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Summary header with Inspector link
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(SummaryRenderer.summary(for: artifact))
                    .font(.caption2.weight(.medium))

                Spacer()

                Button {
                    store.showInspector(.diff(diff))
                } label: {
                    HStack(spacing: 2) {
                        Text("Full diff")
                            .font(.caption2)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Diff stats
            HStack(spacing: 8) {
                if diff.addedLines > 0 {
                    Label("+\(diff.addedLines)", systemImage: "plus.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if diff.removedLines > 0 {
                    Label("-\(diff.removedLines)", systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            // Inline diff content — green/red per line
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.codeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private var diffLines: [String] {
        diff.diffContent.components(separatedBy: "\n")
    }
}

/// Single line in a diff view — colored by type.
private struct DiffLineView: View {
    let line: String

    private var style: (color: Color, bg: Color) {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return (.green, .green.opacity(0.08))
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
            return (.red, .red.opacity(0.08))
        } else if line.hasPrefix("@@") {
            return (.blue, .blue.opacity(0.06))
        } else {
            return (.secondary, .clear)
        }
    }

    var body: some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(style.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 0.5)
            .background(style.bg)
    }
}
