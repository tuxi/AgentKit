//
//  AssetInspectorView.swift
//  AgentKit
//
//  Inspector views for structured agent-wire asset references.
//

import SwiftUI

struct AssetListInspectorView: View {
    let payload: AssetPanelPayload
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if payload.assets.isEmpty {
                ContentUnavailableView("No Assets", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(payload.assets) { asset in
                            Button {
                                store.showInspector(.asset(AssetPreviewPayload(
                                    asset: asset,
                                    conversationID: payload.conversationID,
                                    workspace: payload.workspace
                                )))
                            } label: {
                                AssetRow(asset: asset)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.secondary)
                Text(payload.title)
                    .font(.headline)
                Spacer()
                Text("\(payload.assets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            if let workspace = payload.workspace {
                Label(workspace.displayName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct AssetPreviewInspectorView: View {
    let payload: AssetPreviewPayload
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var loadedAsset: AgentAssetRef?
    @State private var loadedContent: String?
    @State private var loadedMIMEType: String?
    @State private var loadedSizeBytes: Int64?
    @State private var isTruncated = false
    @State private var source: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: loadTaskID) {
            await loadRuntimePreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: displayAsset.assetIconName)
                    .foregroundStyle(displayAsset.assetAccentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayAsset.assetTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(displayAsset.assetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                chip(displayAsset.kind)
                if let range = displayAsset.range?.displayText {
                    chip(range)
                }
                if let source {
                    chip(source)
                }
                if let mime = loadedMIMEType ?? displayAsset.mimeType {
                    chip(mime)
                }
                if isTruncated {
                    chip("truncated")
                }
                if let loadedSizeBytes {
                    chip(byteCount(loadedSizeBytes))
                }
                if let workspace = payload.workspace {
                    chip(workspace.displayName)
                } else if let workspaceID = displayAsset.workspaceID {
                    chip(workspaceID)
                }
            }

            if let errorMessage, !hasDisplayableContent {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if displayAsset.kind == "url",
           let uri = displayAsset.uri,
           let url = URL(string: uri) {
            VStack(alignment: .leading, spacing: 12) {
                Text(uri)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button {
                    openURL(url)
                } label: {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
        } else if displayAsset.kind == "directory" {
            DirectoryAssetPreview(
                asset: displayAsset,
                content: displayContent
            )
            .padding()
        } else {
            FileArtifactBody(
                filePath: displayAsset.assetPath ?? displayAsset.id,
                content: displayContent,
                language: loadedLanguageHint,
                maxHeight: nil,
                focusLine: displayAsset.range?.startLine,
                focusID: displayAsset.id
            )
            .padding()
        }
    }

    private var displayAsset: AgentAssetRef {
        loadedAsset ?? payload.asset
    }

    private var displayContent: String {
        if let loadedContent, !loadedContent.isEmpty {
            return loadedContent
        }
        return displayAsset.previewContent
    }

    private var hasDisplayableContent: Bool {
        let trimmed = displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != displayAsset.assetSubtitle
    }

    private var loadedLanguageHint: String? {
        if let loadedMIMEType {
            return AgentAssetRef.languageHint(mimeType: loadedMIMEType, path: displayAsset.assetPath ?? displayAsset.uri)
        }
        return displayAsset.languageHint
    }

    private var loadTaskID: String {
        "\(payload.conversationID ?? "local"):\(payload.asset.id)"
    }

    private func loadRuntimePreview() async {
        guard let conversationID = payload.conversationID else { return }
        resetLoadedStateForNewAsset()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let preview = try await store.client.getAssetPreview(
                conversationID: conversationID,
                assetID: payload.asset.id
            )
            loadedAsset = preview.asset
            if let content = preview.content, !content.isEmpty {
                loadedContent = content
            }
            loadedMIMEType = preview.mimeType
            loadedSizeBytes = preview.sizeBytes
            isTruncated = preview.truncated
            source = preview.source

            guard shouldLoadFullContent(asset: preview.asset, mimeType: preview.mimeType) else { return }
            do {
                let full = try await store.client.getAssetContent(
                    conversationID: conversationID,
                    assetID: payload.asset.id
                )
                loadedAsset = full.asset
                loadedContent = full.content
                loadedMIMEType = full.mimeType
                loadedSizeBytes = full.sizeBytes
                isTruncated = full.truncated
                source = "content"
            } catch {
                // Preview is still useful; content can be rejected for directories,
                // non-text assets, or server-side caps.
            }
        } catch {
            if hasDisplayableContent {
                source = source ?? displayAsset.fallbackPreviewSource
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetLoadedStateForNewAsset() {
        loadedAsset = nil
        loadedContent = nil
        loadedMIMEType = nil
        loadedSizeBytes = nil
        isTruncated = false
        source = payload.asset.fallbackPreviewSource
    }

    private func shouldLoadFullContent(asset: AgentAssetRef, mimeType: String?) -> Bool {
        guard asset.assetPath != nil else { return false }
        switch asset.kind {
        case "file", "file_location", "symbol", "search_result", "markdown", "diff":
            return true
        case "directory", "url", "image", "audio":
            return false
        default:
            if let mimeType {
                return AgentAssetRef.isTextMIMEType(mimeType)
            }
            return false
        }
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary)
            .clipShape(Capsule())
    }
}

private struct AssetRow: View {
    let asset: AgentAssetRef

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: asset.assetIconName)
                .foregroundStyle(asset.assetAccentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(asset.assetTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(asset.kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                Text(asset.assetSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let preview = asset.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct DirectoryAssetPreview: View {
    let asset: AgentAssetRef
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.blue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.assetTitle)
                        .font(.headline)
                    Text(asset.assetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            if !trimmedContent.isEmpty, trimmedContent != asset.assetSubtitle {
                Text(trimmedContent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ContentUnavailableView("Directory", systemImage: "folder")
            }

            Spacer()
        }
    }

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AgentAssetRef {
    var assetTitle: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let path = assetPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let uri, !uri.isEmpty { return uri }
        return id
    }

    var assetSubtitle: String {
        var parts: [String] = []
        if let path = assetPath {
            parts.append(path)
        } else if let uri {
            parts.append(uri)
        }
        if let range = range?.displayText {
            parts.append(range)
        }
        return parts.isEmpty ? id : parts.joined(separator: " · ")
    }

    var assetPath: String? {
        if let workspaceRelativePath, !workspaceRelativePath.isEmpty {
            return workspaceRelativePath
        }
        if let absolutePath, !absolutePath.isEmpty {
            return absolutePath
        }
        return nil
    }

    var previewContent: String {
        if kind == "directory" {
            if let preview, !preview.isEmpty {
                return preview
            }
            if let metadata, !metadata.isEmpty,
               let text = JSONValue.object(metadata).prettyJSONString {
                return text
            }
            return assetSubtitle
        }
        if let absolutePath,
           let content = try? String(contentsOfFile: absolutePath, encoding: .utf8) {
            return content
        }
        if let preview, !preview.isEmpty {
            return preview
        }
        if let metadata, !metadata.isEmpty,
           let text = JSONValue.object(metadata).prettyJSONString {
            return text
        }
        return assetSubtitle
    }

    var fallbackPreviewSource: String? {
        if let absolutePath,
           FileManager.default.fileExists(atPath: absolutePath) {
            return "local"
        }
        if preview?.isEmpty == false {
            return "event"
        }
        if metadata?.isEmpty == false {
            return "metadata"
        }
        return nil
    }

    var languageHint: String? {
        Self.languageHint(mimeType: mimeType, path: assetPath ?? uri)
    }

    static func languageHint(mimeType: String?, path: String?) -> String? {
        if let mimeType {
            let mime = mimeType.lowercased()
            if mime.contains("swift") { return "swift" }
            if mime.contains("json") { return "json" }
            if mime.contains("markdown") { return "markdown" }
            if mime.contains("javascript") { return "javascript" }
            if mime.contains("typescript") { return "javascript" }
            if mime.contains("python") { return "python" }
            if mime.contains("go") { return "go" }
            if mime.contains("rust") { return "rust" }
        }

        let ext = ((path ?? "") as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "js", "mjs", "ts", "tsx": return "javascript"
        case "py": return "python"
        case "go": return "go"
        case "rs": return "rust"
        default: return nil
        }
    }

    static func isTextMIMEType(_ mimeType: String) -> Bool {
        let mime = mimeType.lowercased()
        return mime.hasPrefix("text/")
            || mime.contains("json")
            || mime.contains("xml")
            || mime.contains("javascript")
            || mime.contains("typescript")
            || mime.contains("swift")
            || mime.contains("rust")
    }

    var assetIconName: String {
        switch kind {
        case "file", "file_location", "search_result":
            return "doc.text"
        case "symbol":
            return "curlybraces"
        case "directory":
            return "folder"
        case "url":
            return "link"
        case "diff":
            return "plus.forwardslash.minus"
        case "terminal":
            return "terminal"
        case "image":
            return "photo"
        default:
            return "paperclip"
        }
    }

    var assetAccentColor: Color {
        switch kind {
        case "file", "file_location", "search_result", "symbol":
            return .blue
        case "directory":
            return .blue
        case "url":
            return .purple
        case "diff":
            return .green
        case "terminal":
            return .orange
        case "image":
            return .pink
        default:
            return .secondary
        }
    }
}

extension AgentAssetRange {
    var displayText: String? {
        guard let startLine else { return nil }
        if let endLine, endLine != startLine {
            return "L\(startLine)-L\(endLine)"
        }
        if let startColumn {
            return "L\(startLine):\(startColumn)"
        }
        return "L\(startLine)"
    }
}
