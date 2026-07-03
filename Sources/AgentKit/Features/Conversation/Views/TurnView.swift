//
//  TurnView.swift
//  AgentKit
//
//  Renders one ConversationTurn as a single continuous message:
//  user prompt → ordered assistant blocks (text / thinking / tools) → footer.
//  Lifecycle noise (model invoked/finished) never appears — it's in the footer.
//

import SwiftUI

struct TurnView: View, Equatable {
    let turn: ConversationTurn
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var documentState = TranscriptDocumentState()

    /// With `.equatable()` at the call site, SwiftUI skips body entirely for
    /// turns whose content didn't change — the common case while another turn
    /// streams. (Environment is only read inside action closures, and @State
    /// changes invalidate independently, so comparing `turn` is sufficient.)
    nonisolated static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn
    }

    // NOTE: no TimelineView(.periodic) here. Rebuilding the transcript on a
    // timer replaced the NSTextView's text storage every 320ms, which reset
    // the user's text selection while a tool was running. The running state
    // is shown with a static glyph instead.
    var body: some View {
        let transcript = TranscriptCache.shared.transcript(
            for: turn,
            state: documentState
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
        let assets = turnAssets
        if canCopy || !assets.isEmpty {
            HStack(spacing: 12) {
                if canCopy {
                    TurnCopyButton(text: copyText)
                }
                if !assets.isEmpty {
                    Button {
                        store.showInspector(.assets(AssetPanelPayload(
                            title: "Turn Assets",
                            assets: assets,
                            conversationID: store.activeConversationViewModel?.conversation?.id,
                            workspace: store.activeConversationViewModel?.workspaceAnchor
                        )))
                    } label: {
                        Label("\(assets.count)", systemImage: "tray.full")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("查看本轮资产")
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    /// True while the latest text block is still streaming in.
    private var isAnswerStreaming: Bool {
        for block in turn.blocks.reversed() {
            if case .text(_, let p) = block { return p.isStreaming }
        }
        return false
    }

    private var turnAssets: [AgentAssetRef] {
        var assets: [AgentAssetRef] = []
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools {
                assets.append(contentsOf: tool.assets)
            }
        }
        return AgentAssetDisplayIndex.unique(assets)
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

        case .openChildStream(let childID):
            guard let payload = childStreamPayload(childID: childID) else { return }
            store.showInspector(.childStream(ChildStreamSelection(
                childID: payload.childID,
                kind: payload.kind,
                title: payload.title
            )))

        case .copyBlock(let text):
            Clipboard.copy(text)
        }
    }

    private func childStreamPayload(childID: String) -> ChildStreamNodePayload? {
        for block in turn.blocks {
            if case .childStream(_, let payload) = block, payload.childID == childID {
                return payload
            }
        }
        return nil
    }

    private func openAsset(_ reference: AssetReference) {
        switch reference.kind {
        case .structured:
            guard let asset = reference.structuredAsset else {
                Clipboard.copy(reference.target)
                return
            }
            openStructuredAsset(asset)

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
            } else if let asset = AssetIndex(turn: turn).structuredAsset(path: reference.target) {
                openStructuredAsset(asset)
            } else {
                Clipboard.copy(reference.target)
            }
        }
    }

    private func openStructuredAsset(_ asset: AgentAssetRef) {
        switch asset.kind {
        case "file", "file_location", "symbol", "search_result":
            store.showInspector(.asset(AssetPreviewPayload(
                asset: asset,
                conversationID: store.activeConversationViewModel?.conversation?.id,
                workspace: store.activeConversationViewModel?.workspaceAnchor
            )))

        case "url":
            if let uri = asset.uri, let url = URL(string: uri) {
                openURL(url)
            } else {
                Clipboard.copy(asset.displayName ?? asset.id)
            }

        default:
            store.showInspector(.asset(AssetPreviewPayload(
                asset: asset,
                conversationID: store.activeConversationViewModel?.conversation?.id,
                workspace: store.activeConversationViewModel?.workspaceAnchor
            )))
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
        case .directory(let payload):
            store.showInspector(.directory(payload))
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
