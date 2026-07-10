#if os(macOS)
import SwiftUI

/// AppKit timeline counterpart of TurnView's action routing. Keeping this
/// outside the cell makes reuse model-driven and prevents closures from an old
/// row surviving after NSTableView assigns the cell to another turn.
@MainActor
final class TurnActionDispatcher {
    private let turn: ConversationTurn
    private unowned let store: WorkspaceStore
    private let openURL: OpenURLAction

    init(turn: ConversationTurn, store: WorkspaceStore, openURL: OpenURLAction) {
        self.turn = turn
        self.store = store
        self.openURL = openURL
    }

    func handle(_ action: TranscriptAction) {
        switch action {
        case .toggleTool:
            break // NativeTurnTableCellView owns expand/collapse state.
        case .openArtifact(let callID):
            guard let artifact = artifact(callID: callID) else { return }
            openInInspector(artifact)
        case .openAsset(let reference):
            openAsset(reference)
        case .openURL(let raw):
            openExternalURL(raw)
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

    func showTurnAssets() {
        let assets = turnAssets
        guard !assets.isEmpty else { return }
        store.showInspector(.assets(AssetPanelPayload(
            title: "Turn Assets",
            assets: assets,
            conversationID: store.activeConversationViewModel?.conversation?.id,
            workspace: store.activeConversationViewModel?.workspaceAnchor
        )))
    }

    var turnAssets: [AgentAssetRef] {
        var assets: [AgentAssetRef] = []
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools { assets.append(contentsOf: tool.assets) }
        }
        return AgentAssetDisplayIndex.unique(assets)
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
            if !openExternalURL(reference.target) {
                openStructuredAsset(runtimeResourceAsset(
                    uri: reference.target,
                    displayName: reference.display
                ))
            }
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
        case "file", "file_location", "symbol", "search_result",
             "image", "video", "audio", "pdf", "mcp_resource":
            showAssetInspector(asset)
        case "url":
            if let uri = asset.uri, openExternalURL(uri) { return }
            if asset.uri != nil {
                showAssetInspector(asset)
            } else {
                Clipboard.copy(asset.displayName ?? asset.id)
            }
        default:
            showAssetInspector(asset)
        }
    }

    private func showAssetInspector(_ asset: AgentAssetRef) {
        store.showInspector(.asset(AssetPreviewPayload(
            asset: asset,
            conversationID: store.activeConversationViewModel?.conversation?.id,
            workspace: store.activeConversationViewModel?.workspaceAnchor
        )))
    }

    private func runtimeResourceAsset(uri: String, displayName: String) -> AgentAssetRef {
        let safeID = uri.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return AgentAssetRef(
            id: "resource_\(turn.id)_\(String(safeID).prefix(96))",
            kind: "mcp_resource",
            uri: uri,
            displayName: displayName
        )
    }

    @discardableResult
    private func openExternalURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        openURL(url)
        return true
    }

    private func artifact(callID: String) -> ArtifactNode? {
        for block in turn.blocks {
            switch block {
            case .toolGroup(let group):
                for tool in group.tools where tool.callID == callID { return tool.artifact }
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
                for tool in group.tools where tool.artifact?.path == path { return tool.artifact }
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
        case .file(let payload): store.showInspector(.file(payload))
        case .directory(let payload): store.showInspector(.directory(payload))
        case .diff(let payload): store.showInspector(.diff(payload))
        case .terminal(let payload): store.showInspector(.terminal(payload))
        }
    }
}
#endif
