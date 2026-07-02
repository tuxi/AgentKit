//
//  FileArtifactView.swift
//  AgentKit
//
//  File artifact 渲染 — 代码查看器风格（等宽、深色背景、行号）。
//

import SwiftUI

// MARK: - FileArtifactBody (content only, used by UnifiedToolCard)

/// 文件内容渲染体 — 无标题栏、无折叠控件，纯内容。
/// 由 `UnifiedToolCard` 或 `FileArtifactView` 内嵌使用。
struct FileArtifactBody: View {
    let filePath: String
    let content: String
    let language: String?
    var maxHeight: CGFloat? = 400
    var focusLine: Int?
    var focusID: String?
    var focusRevision = 0

    #if os(macOS)
    @State private var searchQuery = ""
    @State private var searchRevision = 0
    @State private var searchDirection = 1
    #endif

    var body: some View {
        #if os(macOS)
        nativePreview
        #else
        legacyLinePreview
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var nativePreview: some View {
        let preview = VStack(spacing: 0) {
            codeSearchBar
            NativeCodePreviewView(
                filePath: filePath,
                content: content,
                language: language,
                focusLine: focusLine,
                focusID: focusID,
                focusRevision: focusRevision,
                searchQuery: searchQuery,
                searchRevision: searchRevision,
                searchDirection: searchDirection
            )
        }
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        if let maxHeight {
            preview.frame(maxHeight: maxHeight)
        } else {
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var codeSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            Text(searchStatusText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 42, alignment: .trailing)
            Button {
                searchDirection = -1
                searchRevision += 1
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(searchMatchCount == 0)
            .help("Previous match")
            Button {
                searchDirection = 1
                searchRevision += 1
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(searchMatchCount == 0)
            .help("Next match")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help("Clear search")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45))
    }

    private var searchStatusText: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(searchMatchCount)"
    }

    private var searchMatchCount: Int {
        CodePreviewSearch.matchCount(in: content, query: searchQuery)
    }
    #endif

    #if !os(macOS)
    @ViewBuilder
    private var legacyLinePreview: some View {
        let scroll = ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(numberedLines.enumerated()), id: \.offset) { index, line in
                        let lineNumber = index + 1
                        HStack(spacing: 8) {
                            Text("\(lineNumber)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(lineNumber == focusLine ? .primary : .tertiary)
                                .frame(width: 32, alignment: .trailing)
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 1)
                        .background(lineNumber == focusLine ? Color.accentColor.opacity(0.14) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .id(lineNumber)
                    }
                }
                .padding(8)
            }
            .onAppear {
                scrollToFocusLine(proxy)
            }
            .onChange(of: focusToken) { _, _ in
                scrollToFocusLine(proxy)
            }
        }
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        if let maxHeight {
            scroll.frame(maxHeight: maxHeight)
        } else {
            scroll
        }
    }
    #endif

    private var numberedLines: [String] {
        content.components(separatedBy: "\n")
    }

    private var focusToken: String {
        "\(focusID ?? filePath):\(focusLine ?? 0):\(focusRevision):\(numberedLines.count)"
    }

    private func scrollToFocusLine(_ proxy: ScrollViewProxy) {
        guard let focusLine, focusLine > 0 else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(focusLine, anchor: .center)
            }
        }
    }
}

// MARK: - FileArtifactView (standalone, with chrome)

/// 文件内容 artifact 的独立渲染视图（带标题栏和折叠控件）。
struct FileArtifactView: View {
    let filePath: String
    let content: String
    let language: String?

    @State private var isExpanded = false

    private let maxCollapsedLines = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                    Text("📄 \(shortFileName)")
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                    if let lang = language {
                        Text(lang)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text("\(lineCount) lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                FileArtifactBody(filePath: filePath, content: content, language: language)
            } else {
                let preview = content.components(separatedBy: "\n").prefix(maxCollapsedLines).joined(separator: "\n")
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(10)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var shortFileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var lineCount: Int {
        content.components(separatedBy: "\n").count
    }
}

// MARK: - DirectoryArtifactView

struct DirectoryArtifactView: View {
    let payload: DirectoryPayload

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(directoryName)
                            .font(.caption.monospaced().weight(.medium))
                            .lineLimit(1)
                        Text(payload.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(entryCount) items")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded, !trimmedListing.isEmpty {
                Text(trimmedListing)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var directoryName: String {
        let name = (payload.path as NSString).lastPathComponent
        return name.isEmpty ? payload.path : name + "/"
    }

    private var trimmedListing: String {
        payload.listing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var entryCount: Int {
        trimmedListing.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}
