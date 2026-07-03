//
//  AssetInspectorView.swift
//  AgentKit
//
//  Inspector views for structured agent-wire asset references.
//

import SwiftUI
import AVKit

#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
private typealias PlatformImage = UIImage
#endif

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
    @State private var loadedMetadata: [String: JSONValue]?
    @State private var isTruncated = false
    @State private var source: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var contentLoadError: String?
    @State private var focusRevision = 0

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
                    Button {
                        focusRevision += 1
                    } label: {
                        chip(range)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to focused line")
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

            if shouldShowReadNotice {
                readNotice
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
        } else if displayAsset.isImageAsset {
            MediaImageAssetPreview(
                asset: displayAsset,
                mediaURL: mediaURL,
                thumbnailURL: thumbnailURL
            )
                .padding()
        } else if displayAsset.isVideoAsset {
            MediaVideoAssetPreview(
                asset: displayAsset,
                mediaURL: mediaURL
            )
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No Preview", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileArtifactBody(
                        filePath: displayAsset.assetPath ?? displayAsset.id,
                        content: displayedTextContent,
                        language: loadedLanguageHint,
                        maxHeight: nil,
                        focusLine: displayAsset.range?.startLine,
                        focusID: displayAsset.id,
                        focusRevision: focusRevision
                    )
                }
            }
            .padding()
        }
    }

    private var displayAsset: AgentAssetRef {
        guard let loadedAsset else { return payload.asset }
        return loadedAsset.mergedForDisplay(fallback: payload.asset)
    }

    private var displayContent: String {
        if let loadedContent, !loadedContent.isEmpty {
            if let localContent = displayAsset.localTextContent,
               shouldPreferLocalContent(localContent, over: loadedContent) {
                return localContent
            }
            return loadedContent
        }
        return displayAsset.previewContent
    }

    private var displayedTextContent: String {
        guard shouldUseClientPreviewWindow else { return displayContent }
        return clientPreviewWindow.text
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

    private var shouldShowReadNotice: Bool {
        isTruncated || contentLoadError != nil || shouldUseClientPreviewWindow
    }

    private var shouldUseClientPreviewWindow: Bool {
        !isDisplayingLoadedContent && displayContent.utf8.count > AssetPreviewLimits.clientPreviewBytes
    }

    private var clientPreviewWindow: AssetTextWindow {
        AssetTextWindow(content: displayContent, maxBytes: AssetPreviewLimits.clientPreviewBytes)
    }

    private var mediaURL: URL? {
        displayAsset.mediaURL ?? resolvedPreviewURL(for: "media_url")
    }

    private var thumbnailURL: URL? {
        resolvedPreviewURL(for: "thumbnail_url")
    }

    private var previewMetadata: [String: JSONValue]? {
        loadedMetadata ?? displayAsset.metadata
    }

    private var isDisplayingLoadedContent: Bool {
        guard let loadedContent, !loadedContent.isEmpty else { return false }
        return displayContent == loadedContent
    }

    private var readNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: readNoticeIconName)
                .font(.caption)
                .foregroundStyle(readNoticeColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(readNoticeTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(readNoticeColor)
                Text(readNoticeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(8)
        .background(readNoticeColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var readNoticeIconName: String {
        if contentLoadError != nil { return "exclamationmark.triangle" }
        if isTruncated { return "scissors" }
        return "speedometer"
    }

    private var readNoticeColor: Color {
        contentLoadError != nil ? .orange : .secondary
    }

    private var readNoticeTitle: String {
        if contentLoadError != nil { return "Preview Only" }
        if isTruncated { return "Content Truncated" }
        return "Large Preview Window"
    }

    private var readNoticeDetail: String {
        if let contentLoadError {
            return "Full content could not be loaded: \(contentLoadError)"
        }
        if isTruncated {
            if let loadedSizeBytes {
                return "Runtime returned a capped text response for a \(byteCount(loadedSizeBytes)) asset."
            }
            return "Runtime returned a capped text response."
        }
        let window = clientPreviewWindow
        return "Showing the first \(byteCount(Int64(window.byteCount))) locally to keep the inspector responsive."
    }

    private func loadRuntimePreview() async {
        guard let conversationID = payload.conversationID else { return }
        resetLoadedStateForNewAsset()
        isLoading = true
        errorMessage = nil
        contentLoadError = nil
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
            loadedMetadata = preview.metadata
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
                contentLoadError = error.localizedDescription
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
        loadedMetadata = nil
        isTruncated = false
        source = payload.asset.fallbackPreviewSource
        contentLoadError = nil
    }

    private func shouldLoadFullContent(asset: AgentAssetRef, mimeType: String?) -> Bool {
        let candidate = asset.mergedForDisplay(fallback: payload.asset)
        guard candidate.assetPath != nil else { return false }
        guard !candidate.isImageAsset, !candidate.isVideoAsset else { return false }
        switch candidate.kind {
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

    private func shouldPreferLocalContent(_ localContent: String, over loadedContent: String) -> Bool {
        let localTrimmed = localContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadedTrimmed = loadedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localTrimmed.isEmpty, localTrimmed != loadedTrimmed else { return false }

        // Runtime preview responses can legitimately be tiny summaries, e.g. a
        // read_file asset whose event preview is only the first line. When a
        // local workspace file is available, use the richer on-disk text.
        return localContent.utf8.count > loadedContent.utf8.count
    }

    private func resolvedPreviewURL(for key: String) -> URL? {
        guard let value = previewMetadata?[key]?.string, !value.isEmpty else { return nil }
        return store.client.resolveRuntimeURL(value)
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

private extension AgentAssetRef {
    func mergedForDisplay(fallback: AgentAssetRef) -> AgentAssetRef {
        guard id == fallback.id else { return self }
        return AgentAssetRef(
            id: id,
            kind: kind,
            uri: nonEmpty(uri) ?? fallback.uri,
            displayName: nonEmpty(displayName) ?? fallback.displayName,
            workspaceID: nonEmpty(workspaceID) ?? fallback.workspaceID,
            workspaceRelativePath: nonEmpty(workspaceRelativePath) ?? fallback.workspaceRelativePath,
            absolutePath: nonEmpty(absolutePath) ?? fallback.absolutePath,
            range: range ?? fallback.range,
            preview: nonEmpty(preview) ?? fallback.preview,
            mimeType: nonEmpty(mimeType) ?? fallback.mimeType,
            sourceTurnID: nonEmpty(sourceTurnID) ?? fallback.sourceTurnID,
            sourceCallID: nonEmpty(sourceCallID) ?? fallback.sourceCallID,
            metadata: metadata ?? fallback.metadata
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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

private struct MediaImageAssetPreview: View {
    let asset: AgentAssetRef
    let mediaURL: URL?
    let thumbnailURL: URL?
    @Environment(\.openURL) private var openURL
    @State private var localImage: PlatformImage?
    @State private var useFullMedia = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = displayURL {
                mediaFrame(url: url)
                HStack(spacing: 8) {
                    Button {
                        if let mediaURL {
                            openURL(mediaURL)
                        }
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .disabled(mediaURL == nil)

                    Text(asset.assetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "photo")
            }
            Spacer()
        }
        .task(id: displayURL) {
            await loadLocalImage()
        }
    }

    private var displayURL: URL? {
        if let thumbnailURL, !useFullMedia {
            return thumbnailURL
        }
        return mediaURL
    }

    @ViewBuilder
    private func mediaFrame(url: URL) -> some View {
        if url.isFileURL {
            if let localImage {
                platformImageView(localImage)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    if thumbnailURL != nil, !useFullMedia, mediaURL != nil {
                        ProgressView()
                            .task { useFullMedia = true }
                    } else {
                        ContentUnavailableView("Image Unavailable", systemImage: "photo")
                    }
                case .empty:
                    ProgressView()
                @unknown default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #elseif os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }

    @MainActor
    private func loadLocalImage() async {
        localImage = nil
        guard let url = displayURL, url.isFileURL else { return }
        #if os(macOS)
        localImage = NSImage(contentsOf: url)
        #elseif os(iOS)
        localImage = UIImage(contentsOfFile: url.path)
        #endif
    }
}

private struct MediaVideoAssetPreview: View {
    let asset: AgentAssetRef
    let mediaURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = mediaURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)

                    Text(asset.assetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("Video Unavailable", systemImage: "film")
            }
            Spacer()
        }
    }
}

private enum AssetPreviewLimits {
    static let clientPreviewBytes = 512_000
}

private struct AssetTextWindow: Hashable {
    let text: String
    let byteCount: Int
    let totalBytes: Int

    init(content: String, maxBytes: Int) {
        totalBytes = content.utf8.count
        guard totalBytes > maxBytes else {
            text = content
            byteCount = totalBytes
            return
        }

        var consumed = 0
        var scalars = String.UnicodeScalarView()
        for scalar in content.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard consumed + scalarBytes <= maxBytes else { break }
            scalars.append(scalar)
            consumed += scalarBytes
        }

        text = String(scalars)
        byteCount = consumed
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
        if let content = localTextContent {
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

    var localTextContent: String? {
        guard kind != "directory",
              !isImageAsset,
              !isVideoAsset,
              let absolutePath,
              !absolutePath.isEmpty else { return nil }
        return try? String(contentsOfFile: absolutePath, encoding: .utf8)
    }

    var isImageAsset: Bool {
        if kind == "image" { return true }
        if let mimeType, mimeType.lowercased().hasPrefix("image/") { return true }
        return Self.imageExtensions.contains(assetExtension)
    }

    var isVideoAsset: Bool {
        if kind == "video" { return true }
        if let mimeType, mimeType.lowercased().hasPrefix("video/") { return true }
        return Self.videoExtensions.contains(assetExtension)
    }

    var mediaURL: URL? {
        if let absolutePath, !absolutePath.isEmpty {
            return URL(fileURLWithPath: absolutePath)
        }
        if let uri, let url = URL(string: uri), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        return nil
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
            if isImageAsset { return "photo" }
            if isVideoAsset { return "film" }
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
        case "video":
            return "film"
        default:
            return "paperclip"
        }
    }

    var assetAccentColor: Color {
        switch kind {
        case "file", "file_location", "search_result", "symbol":
            if isImageAsset { return .pink }
            if isVideoAsset { return .indigo }
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
        case "video":
            return .indigo
        default:
            return .secondary
        }
    }

    private var assetExtension: String {
        let candidate = absolutePath ?? workspaceRelativePath ?? uri ?? displayName ?? ""
        return (candidate as NSString).pathExtension.lowercased()
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm"
    ]
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
