//
//  TurnView.swift
//  AgentKit
//
//  Renders one ConversationTurn as a single continuous message:
//  user prompt → ordered assistant blocks (text / thinking / tools) → footer.
//  Lifecycle noise (model invoked/finished) never appears — it's in the footer.
//

import SwiftUI

struct TurnView: View {
    let turn: ConversationTurn
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var documentState = TranscriptDocumentState()

    var body: some View {
        if hasRunningTool {
            TimelineView(.periodic(from: .now, by: 0.32)) { context in
                transcriptBody(animationFrame: animationFrame(for: context.date))
            }
        } else {
            transcriptBody(animationFrame: 0)
        }
    }

    @ViewBuilder
    private func transcriptBody(animationFrame: Int) -> some View {
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: documentState,
            animationFrame: animationFrame
        )
        VStack(alignment: .leading, spacing: 6) {
            NativeTranscriptView(transcript: transcript) { action in
                handleTranscriptAction(action)
            }

            bottomRow(copyText: transcript.copyText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One copy button per turn. The selectable transcript already contains the
    /// turn footer, so this row stays quiet.
    @ViewBuilder
    private func bottomRow(copyText: String) -> some View {
        // Show copy once there's text that isn't actively streaming — NOT gated
        // on session liveness (turn.isLive stays true for the whole live
        // session, which hid the button until you reloaded into history).
        let canCopy = !copyText.isEmpty && !isAnswerStreaming
        if canCopy {
            HStack(spacing: 12) {
                TurnCopyButton(text: copyText)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var hasRunningTool: Bool {
        turn.blocks.contains { block in
            guard case .toolGroup(let group) = block else { return false }
            return group.tools.contains { $0.status == .running }
        }
    }

    private func animationFrame(for date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate * 3.0)
    }

    /// True while the latest text block is still streaming in.
    private var isAnswerStreaming: Bool {
        for block in turn.blocks.reversed() {
            if case .text(_, let p) = block { return p.isStreaming }
        }
        return false
    }

    private func handleTranscriptAction(_ action: TranscriptAction) {
        switch action {
        case .toggleTool(let callID):
            documentState.toggleTool(callID: callID)

        case .openArtifact(let callID):
            guard let artifact = artifact(callID: callID) else { return }
            openInInspector(artifact)

        case .openAsset(let reference):
            openAsset(reference)

        case .openURL(let raw):
            guard let url = URL(string: raw) else { return }
            openURL(url)

        case .openPath(let path):
            if let artifact = artifact(path: path) {
                openInInspector(artifact)
            } else {
                Clipboard.copy(path)
            }
        }
    }

    private func openAsset(_ reference: AssetReference) {
        switch reference.kind {
        case .url:
            guard let url = URL(string: reference.target) else { return }
            openURL(url)

        case .artifact:
            if let callID = reference.resolvedArtifactCallID,
               let artifact = artifact(callID: callID) {
                openInInspector(artifact)
            } else if let artifact = artifact(path: reference.target) {
                openInInspector(artifact)
            } else {
                Clipboard.copy(reference.target)
            }

        case .filePath:
            if let artifact = artifact(path: reference.target) {
                openInInspector(artifact)
            } else {
                Clipboard.copy(reference.target)
            }
        }
    }

    private func artifact(callID: String) -> ArtifactNode? {
        for block in turn.blocks {
            switch block {
            case .toolGroup(let group):
                for tool in group.tools where tool.callID == callID {
                    return tool.artifact
                }
            case .artifact(_, let node) where node.callID == callID:
                return node
            default:
                break
            }
        }
        return nil
    }

    private func artifact(path: String) -> ArtifactNode? {
        for block in turn.blocks {
            switch block {
            case .toolGroup(let group):
                for tool in group.tools {
                    if let artifact = tool.artifact, artifact.path == path {
                        return artifact
                    }
                }
            case .artifact(_, let node) where node.path == path:
                return node
            default:
                break
            }
        }
        return nil
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

// MARK: - TurnCopyButton

/// One copy button per turn — copies the whole assistant reply.
private struct TurnCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("复制回复")
    }
}
