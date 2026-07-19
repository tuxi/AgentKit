//
//  MarkdownBlockView.swift
//  AgentKit
//
//  Renders a single MarkdownBlock as a SwiftUI View.
//  Walks the application-level AST types — no parsing logic here.
//

import SwiftUI

// MARK: - MarkdownBlockView

/// Renders a single MarkdownBlock element.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var baseFont: Font = .body
    var fillWidth: Bool = true

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            if let image = standaloneImage(from: inlines) {
                TranscriptImageView(urlString: image.source, altText: image.altText)
            } else {
                Text(MarkdownInlineRenderer.render(inlines, baseFont: baseFont))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: fillWidth ? .infinity : nil,
                        alignment: fillWidth ? .leading : .center
                    )
            }

        case .heading(let level, let inlines):
            Text(MarkdownInlineRenderer.render(inlines, baseFont: baseFont))
                .textSelection(.enabled)
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 6 : 2)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .blockquote(let blocks):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blockquoteAccent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, innerBlock in
                        MarkdownBlockView(block: innerBlock, baseFont: baseFont, fillWidth: fillWidth)
                    }
                }
                .foregroundStyle(Color.blockquoteText)
                .italic()
                .padding(.leading, 8)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListItemView(item: item, index: nil, baseFont: baseFont, fillWidth: fillWidth)
                }
            }

        case .orderedList(let items, let startIndex):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    MarkdownListItemView(item: item, index: Int(startIndex) + i, baseFont: baseFont, fillWidth: fillWidth)
                }
            }

        case .thematicBreak:
            Divider()
                .padding(.vertical, 2)

        case .table(let head, let body):
            MarkdownTableView(head: head, rows: body)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.medium)
        }
    }

    /// Returns the image info when `inlines` represents a standalone image
    /// (a paragraph whose only meaningful content is a single image).
    /// Returns nil for text paragraphs, multi-image paragraphs, or mixed content.
    private func standaloneImage(from inlines: [InlineContent]) -> (source: String?, altText: String)? {
        var image: (source: String?, altText: String)?
        for inline in inlines {
            switch inline {
            case .image(let source, let altText):
                if image != nil { return nil } // multiple images — render as text
                image = (source, altText)
            case .text(let s):
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            case .softBreak, .lineBreak:
                break // whitespace around the image is fine
            default:
                return nil
            }
        }
        return image
    }
}

// MARK: - List Item View

/// Renders a single list item — ordered, unordered, or task.
private struct MarkdownListItemView: View {
    let item: MarkdownListItem
    /// The item number for ordered lists (nil → use bullet).
    let index: Int?
    var baseFont: Font = .body
    var fillWidth: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // Marker: checkbox, number, or bullet
            if let checkbox = item.checkbox {
                Image(systemName: checkbox == .checked ? "checkmark.square" : "square")
                    .foregroundStyle(checkbox == .checked ? .green : .secondary)
            } else if let idx = index {
                Text("\(idx).")
                    .foregroundStyle(Color.listMarker)
            } else {
                Text("•")
                    .foregroundStyle(Color.listMarker)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, baseFont: baseFont)
                        .strikethrough(item.checkbox == .checked)
                }
            }
        }
    }
}

// MARK: - Table View

/// Renders a markdown table with native SwiftUI `Grid` layout — proportional
/// font, auto-aligned columns, and horizontal scroll on overflow.
private struct MarkdownTableView: View {
    let head: [TableCell]
    let rows: [[TableCell]]
    @State private var showCopied = false

    private var columnCount: Int {
        max(head.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Copy button header
            HStack {
                Spacer()
                copyButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(horizontalSpacing: 0, verticalSpacing: 1) {
                // Header
                if !head.isEmpty {
                    GridRow {
                        ForEach(paddedCells(head), id: \.offset) { _, cell in
                            cellView(cell, isHeader: true)
                        }
                    }
                    .background(Color.secondary.opacity(0.06))

                    // Header separator
                    GridRow {
                        Rectangle()
                            .fill(Color.codeBlockBorder)
                            .frame(height: 1)
                            .gridCellColumns(columnCount)
                    }
                }

                // Body
                ForEach(rows.indices, id: \.self) { rowIdx in
                    GridRow {
                        ForEach(paddedCells(rows[rowIdx]), id: \.offset) { _, cell in
                            cellView(cell, isHeader: false)
                        }
                    }

                    if rowIdx < rows.count - 1 {
                        GridRow {
                            Rectangle()
                                .fill(Color.codeBlockBorder.opacity(0.5))
                                .frame(height: 1)
                                .gridCellColumns(columnCount)
                        }
                    }
                }
            }
            .padding(8)
        } // ScrollView
        } // VStack
        .frame(minWidth: 200)
        .background(Color.codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.codeBlockBorder, lineWidth: 1)
        )
    }

    // MARK: - Cell

    private func cellView(_ cell: TableCell, isHeader: Bool) -> some View {
        let rendered = MarkdownInlineRenderer.render(cell.content, baseFont: .caption)
        return Text(rendered)
            .textSelection(.enabled)
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(isHeader ? .secondary : .primary)
            .frame(minWidth: 52, maxWidth: 220, alignment: cell.alignment.swiftAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    // MARK: - Copy

    private var tablePlainText: String {
        var lines: [String] = []
        let allRows = head.isEmpty ? rows : [head] + rows
        for row in allRows {
            let parts = row.map { $0.plainText }
            lines.append(parts.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private var copyButton: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tablePlainText, forType: .string)
            #else
            UIPasteboard.general.string = tablePlainText
            #endif
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        } label: {
            Label(
                showCopied ? "Copied" : "Copy",
                systemImage: showCopied ? "checkmark" : "doc.on.doc"
            )
            .font(.caption2)
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Padding helper

    /// Pads a row to `columnCount` with empty left-aligned cells.
    private func paddedCells(_ cells: [TableCell]) -> [(offset: Int, element: TableCell)] {
        var result: [(Int, TableCell)] = []
        for col in 0..<columnCount {
            if col < cells.count {
                result.append((col, cells[col]))
            } else {
                result.append((col, TableCell(content: [], alignment: .left)))
            }
        }
        return result
    }
}

private extension TableCellAlignment {
    var swiftAlignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

private extension TableCell {
    var plainText: String {
        content.compactMap { $0.plainText }.joined()
    }
}

private extension InlineContent {
    var plainText: String {
        switch self {
        case .text(let s): return s
        case .strong(let c): return c.compactMap(\.plainText).joined()
        case .emphasis(let c): return c.compactMap(\.plainText).joined()
        case .strikethrough(let c): return c.compactMap(\.plainText).joined()
        case .inlineCode(let s): return s
        case .link(_, let c): return c.compactMap(\.plainText).joined()
        case .image(_, let alt): return alt
        case .softBreak: return " "
        case .lineBreak: return " "
        }
    }
}
