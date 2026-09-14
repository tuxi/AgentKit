//
//  AssetPreviewViewer.swift
//  AgentKit
//
//  Cross-platform full-size preview for user-attached conversation images.
//  One viewer implementation serves both presentation paths:
//  - macOS Web workbench: thumbnail click crosses the native bridge and the
//    Coordinator presents this view as a sheet (see ConversationWebWorkbenchView).
//  - Native timeline (iOS, macOS fallback): the strip presents it directly via
//    fullScreenCover / sheet on tap.
//
//  Items always carry the turn's mixed image order (remote assets first, then
//  image local assets) so the clicked index matches the strip layout on both
//  platforms. Failed resolutions keep their slot with a nil URL and render a
//  placeholder, never dropping out of the pager.
//

import SwiftUI

// MARK: - Model

/// One image slot in the shared previewer.
struct AssetPreviewItem: Identifiable, Hashable {
    /// Stable identity across the Web bridge and native strip: remote assets
    /// are keyed by gateway assetID, local assets by their staging UUID.
    enum Source: Hashable {
        case userAsset(Int64)
        case localAsset(String)
    }

    let id: Source
    let filename: String
    /// `nil` means the host could not produce a display URL; the viewer shows
    /// a placeholder so paging indices stay stable.
    let url: URL?
}

/// Identifiable presentation payload for `.sheet(item:)` / `.fullScreenCover(item:)`.
struct AssetPreviewPresentation: Identifiable {
    let id = UUID()
    let items: [AssetPreviewItem]
    let initialIndex: Int
}

// MARK: - Mixed list construction

enum UserAssetPreviewCollection {
    /// Pure ordering/filtering used by both renderers: remote assets first
    /// (the protocol restricts them to images), then `image/*` local assets.
    static func imageSources(
        userAssets: [UserAssetRef],
        localAssets: [LocalUserAssetRef]
    ) -> [AssetPreviewItem.Source] {
        userAssets.map { .userAsset($0.assetID) }
            + localAssets
                .filter { $0.mimeType.hasPrefix("image/") }
                .map { .localAsset($0.id) }
    }

    /// Resolves display URLs for the mixed list. Remote URLs come from the
    /// gateway preview resolver (signed https); local URLs come from the
    /// staging resolver (file URL). A failing resolver leaves that slot as a
    /// placeholder instead of dropping it.
    static func resolveItems(
        userAssets: [UserAssetRef],
        localAssets: [LocalUserAssetRef],
        userResolver: (any UserAssetPreviewResolving)?,
        localResolver: (any LocalUserAssetPreviewResolving)?,
        conversationID: String?,
        workspaceRoot: URL?
    ) async -> [AssetPreviewItem] {
        let userByID = Dictionary(
            userAssets.map { (AssetPreviewItem.Source.userAsset($0.assetID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localByID = Dictionary(
            localAssets.map { (AssetPreviewItem.Source.localAsset($0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [AssetPreviewItem] = []
        for source in imageSources(userAssets: userAssets, localAssets: localAssets) {
            switch source {
            case .userAsset(let assetID):
                guard let asset = userByID[source] else { continue }
                let url = try? await userResolver?.previewURL(for: asset)
                items.append(AssetPreviewItem(id: .userAsset(assetID), filename: asset.filename, url: url))
            case .localAsset(let id):
                guard let asset = localByID[source] else { continue }
                var url: URL?
                if let localResolver, let conversationID, let workspaceRoot {
                    url = try? await localResolver.previewURL(
                        for: asset,
                        conversationID: conversationID,
                        workspaceRoot: workspaceRoot
                    )
                }
                items.append(AssetPreviewItem(id: .localAsset(id), filename: asset.filename, url: url))
            }
        }
        return items
    }
}

// MARK: - Viewer

struct AssetPreviewViewer: View {
    let items: [AssetPreviewItem]
    private let onClose: () -> Void
    @State private var index: Int

    init(
        items: [AssetPreviewItem],
        initialIndex: Int,
        onClose: @escaping () -> Void
    ) {
        self.items = items
        self.onClose = onClose
        _index = State(initialValue: min(max(initialIndex, 0), max(items.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                caption
                    .padding(.top, 8)

                imagePage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())

                controlBar
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 16)
        }
        .foregroundStyle(.white)
        .gesture(horizontalSwipe)
    }

    private var current: AssetPreviewItem? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    private var caption: some View {
        VStack(spacing: 2) {
            Text(current?.filename ?? "")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(index + 1) / \(items.count)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private var imagePage: some View {
        if let current {
            Group {
                if let url = current.url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            placeholder(for: current)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            placeholder(for: current)
                        }
                    }
                } else {
                    placeholder(for: current)
                }
            }
            .id(current.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: current.id)
        }
    }

    private func placeholder(for item: AssetPreviewItem) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text(item.filename)
                .font(.caption)
            Text("无法加载预览")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private var controlBar: some View {
        HStack(spacing: 44) {
            toolbarButton(
                systemImage: "chevron.left",
                label: "上一张",
                disabled: index <= 0
            ) { step(-1) }
            .keyboardShortcut(.leftArrow, modifiers: [])

            toolbarButton(
                systemImage: "xmark.circle",
                label: "关闭",
                disabled: false
            ) { onClose() }
            .keyboardShortcut(.cancelAction)

            toolbarButton(
                systemImage: "chevron.right",
                label: "下一张",
                disabled: index >= items.count - 1
            ) { step(1) }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .font(.title2)
    }

    private func toolbarButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
        .help(label)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        index = next
    }

    private var horizontalSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -40 { step(1) }
                else if value.translation.width > 40 { step(-1) }
            }
    }
}
