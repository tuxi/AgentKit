//
//  ExecutionNodeViews.swift
//  AgentKit
//
//  Per-node-type card views for the chronological timeline.
//  ExecutionNodeCardView dispatches by ExecutionNodeKind.
//

import SwiftUI

// MARK: - ExecutionNodeCardView

/// Dispatcher: renders one ExecutionPresentation as the appropriate card.
struct ExecutionNodeCardView: View {
    let presentation: ExecutionPresentation
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        Group {
            switch presentation.node.kind {
            case .message(let payload):
                VStack {
                    MessageBubble(
                        text: payload.text,
                        role: payload.role,
                        isStreaming: payload.isStreaming
                    )
                    if payload.role == .assistant {
                        HStack {
                            Button {
                                Clipboard.copy(payload.text)
                            } label: {
                                Image(systemName: "document.on.document")
                            }
                            Spacer()
                        }
                    }
                    if payload.role == .user {
                        if payload.role == .user {
                            HStack {
                                Spacer()
                                Button {
                                    Clipboard.copy(payload.text)
                                } label: {
                                    Image(systemName: "document.on.document")
                                }
                            }
                        }
                    }
                }
            case .thinking(let payload):
                ThinkingCard(
                    text: payload.text,
                    isStreaming: payload.isStreaming
                )
                .padding(.leading, 8)

            case .tool(let payload):
                ToolCard(tool: payload, store: store)
                    .padding(.leading, 8)

            case .artifact(let payload):
                ArtifactCard(artifact: payload.node, store: store)
                    .padding(.leading, 8)

            case .system(let payload):
                SystemEventRow(payload: payload)
            }
        }
    }
}

// MARK: - SystemEventRow

/// Renders system events. Narrative events (observation, reflection, error)
/// are always visible with a left accent bar. Meta events are compact one-liners.
struct SystemEventRow: View {
    let payload: SystemNodePayload

    var body: some View {
        if isNarrative {
            narrativeCard
        } else {
            metaChip
        }
    }

    // MARK: - Narrative (observation / reflection / error)

    private var isNarrative: Bool {
        payload.kind == .observation || payload.kind == .reflection || payload.kind == .error
    }

    private var narrativeCard: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(narrativeAccent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: narrativeIcon)
                        .font(.caption2)
                        .foregroundStyle(narrativeAccent)

                    Text(narrativeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(narrativeAccent)
                        .textCase(.uppercase)

                    Spacer()
                }

                Text(payload.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(narrativeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Meta (compact one-liner)

    private var metaChip: some View {
        HStack(spacing: 4) {
            Image(systemName: metaIcon)
                .font(.caption2)
            Text(payload.text)
                .font(.caption2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Narrative properties

    private var narrativeIcon: String {
        switch payload.kind {
        case .observation: return "eye"
        case .reflection: return "arrow.triangle.branch"
        case .error: return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    private var narrativeLabel: String {
        switch payload.kind {
        case .observation: return "Observed"
        case .reflection: return "Reflecting"
        case .error: return "Error"
        default: return "Note"
        }
    }

    private var narrativeAccent: Color {
        switch payload.kind {
        case .observation: return .blue
        case .reflection: return .purple
        case .error: return .red
        default: return .secondary
        }
    }

    private var narrativeBackground: Color {
        switch payload.kind {
        case .observation: return .blue.opacity(0.04)
        case .reflection: return .purple.opacity(0.04)
        case .error: return .red.opacity(0.06)
        default: return .clear
        }
    }

    // MARK: - Meta properties

    private var metaIcon: String {
        switch payload.kind {
        case .modelActivity: return "cpu"
        case .contextCompact: return "compress"
        case .skillLoaded: return "sparkles"
        default: return "info.circle"
        }
    }
}

// MARK: - ArtifactCard

/// Displays an artifact node inline with a link to the Inspector.
struct ArtifactCard: View {
    let artifact: ArtifactNode
    let store: WorkspaceStore

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: artifactIcon)
                        .font(.caption)

                    Text(SummaryRenderer.summary(for: artifact))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Spacer()

                    Button {
                        openInInspector()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.vertical, 2)

                if let path = artifact.path {
                    Button {
                        openInInspector()
                    } label: {
                        Label(path, systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }

                switch artifact.content {
                case .file(let p):
                    Text(p.content)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(15)
                        .textSelection(.enabled)

                case .diff(let p):
                    VStack(alignment: .leading, spacing: 2) {
                        if p.addedLines > 0 {
                            Text("+\(p.addedLines) added").font(.caption2).foregroundStyle(.green)
                        }
                        if p.removedLines > 0 {
                            Text("-\(p.removedLines) removed").font(.caption2).foregroundStyle(.red)
                        }
                    }

                case .terminal(let p):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("$ \(p.command)").font(.caption2.weight(.medium))
                        if !p.output.isEmpty {
                            Text(p.output)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(10)
                                .textSelection(.enabled)
                        }
                        if let code = p.exitCode {
                            Text("Exit: \(code)")
                                .font(.caption2)
                                .foregroundStyle(code == 0 ? .green : .red)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var artifactIcon: String {
        switch artifact.kind {
        case .fileRead: return "doc.text"
        case .fileCreated: return "doc.badge.plus"
        case .fileEdited: return "arrow.triangle.swap"
        case .commandRun: return "terminal"
        case .listFiles: return "folder.fill"
        }
    }

    private func openInInspector() {
        switch artifact.content {
        case .file(let payload): store.showInspector(.file(payload))
        case .diff(let payload): store.showInspector(.diff(payload))
        case .terminal(let payload): store.showInspector(.terminal(payload))
        }
    }
}
