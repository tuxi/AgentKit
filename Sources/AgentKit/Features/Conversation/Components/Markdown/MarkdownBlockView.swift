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

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            Text(MarkdownInlineRenderer.render(inlines))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let inlines):
            Text(MarkdownInlineRenderer.render(inlines))
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
                        MarkdownBlockView(block: innerBlock)
                    }
                }
                .foregroundStyle(Color.blockquoteText)
                .italic()
                .padding(.leading, 8)
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListItemView(item: item, index: nil)
                }
            }

        case .orderedList(let items, let startIndex):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    MarkdownListItemView(item: item, index: Int(startIndex) + i)
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
}

// MARK: - List Item View

/// Renders a single list item — ordered, unordered, or task.
private struct MarkdownListItemView: View {
    let item: MarkdownListItem
    /// The item number for ordered lists (nil → use bullet).
    let index: Int?

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
                    MarkdownBlockView(block: block)
                        .strikethrough(item.checkbox == .checked)
                }
            }
        }
    }
}

// MARK: - Table View

/// Renders a markdown table as a single monospaced Text block.
/// Uses ASCII column alignment like terminal tables (Claude Code style),
/// enabling continuous multi-line text selection across all rows.
private struct MarkdownTableView: View {
    let head: [TableCell]
    let rows: [[TableCell]]

    var body: some View {
        let rendered = TableTextRenderer.renderText(head: head, rows: rows)
        ScrollView(.horizontal, showsIndicators: false) {
            Text(rendered)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.primary)
                .padding(12)
        }
        .background(Color.codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.codeBlockBorder, lineWidth: 1)
        )
    }
}

// MARK: - Table Text Renderer

/// Formats a table as monospaced plain text with aligned columns.
/// Produces terminal-style output: | Col1 | Col2 | ... with separator lines.
private enum TableTextRenderer {

    static func renderText(head: [TableCell], rows: [[TableCell]]) -> AttributedString {
        let allRows = head.isEmpty ? rows : [head] + rows
        let columnCount = (allRows.map(\.count).max()) ?? 0

        // 1. Compute plain text for each cell
        let cellTexts: [[String]] = allRows.map { row in
            (0..<columnCount).map { col in
                col < row.count ? row[col].plainText : ""
            }
        }

        // 2. Calculate column widths
        var colWidths = Array(repeating: 3, count: columnCount) // minimum width
        for row in cellTexts {
            for (col, text) in row.enumerated() {
                colWidths[col] = max(colWidths[col], text.displayWidth + 2) // +2 for padding
            }
        }

        // 3. Build monospaced text lines
        var lines: [String] = []

        // Build a row string
        func formatRow(_ cells: [String], isHeader: Bool) -> String {
            let parts = cells.enumerated().map { col, text -> String in
                let width = col < colWidths.count ? colWidths[col] : 4
                let align = col < head.count ? head[col].alignment : TableCellAlignment.left
                return pad(text, toWidth: width - 2, alignment: align)
            }
            return "| " + parts.joined(separator: " | ") + " |"
        }

        // Header row
        if !head.isEmpty {
            lines.append(formatRow(cellTexts[0], isHeader: true))
            // Separator line: |:---|:---:|---:|
            let sep = colWidths.map { w -> String in
                "-" + String(repeating: "-", count: max(0, w - 2)) + "-"
            }
            lines.append("|" + sep.joined(separator: "|") + "|")

            // Body rows
            for i in 1..<cellTexts.count {
                lines.append(formatRow(cellTexts[i], isHeader: false))
            }
        } else {
            for rowTexts in cellTexts {
                lines.append(formatRow(rowTexts, isHeader: false))
            }
        }

        var result = AttributedString(lines.joined(separator: "\n"))
        result.font = .system(size: 12, weight: .regular, design: .monospaced)
        result.foregroundColor = .primary
        return result
    }

    /// Pad text within a column width, respecting alignment.
    private static func pad(_ text: String, toWidth width: Int, alignment: TableCellAlignment) -> String {
        let textWidth = text.displayWidth
        let padding = max(0, width - textWidth)
        switch alignment {
        case .left:
            return text + String(repeating: " ", count: padding)
        case .center:
            let left = padding / 2
            let right = padding - left
            return String(repeating: " ", count: left) + text + String(repeating: " ", count: right)
        case .right:
            return String(repeating: " ", count: padding) + text
        }
    }
}

// MARK: - Cell Plain Text

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

// MARK: - Display Width Helper

private extension String {
    /// Approximate display width for monospaced rendering.
    /// CJK characters count as 2, ASCII as 1.
    var displayWidth: Int {
        var width = 0
        for scalar in unicodeScalars {
            if scalar.value >= 0x1100 &&
                (scalar.value <= 0x115F || scalar.value == 0x2329 || scalar.value == 0x232A ||
                 (scalar.value >= 0x2E80 && scalar.value <= 0xA4CF) ||
                 (scalar.value >= 0xAC00 && scalar.value <= 0xD7A3) ||
                 (scalar.value >= 0xF900 && scalar.value <= 0xFAFF) ||
                 (scalar.value >= 0xFE10 && scalar.value <= 0xFE19) ||
                 (scalar.value >= 0xFE30 && scalar.value <= 0xFE6F) ||
                 (scalar.value >= 0xFF01 && scalar.value <= 0xFF60) ||
                 (scalar.value >= 0xFFE0 && scalar.value <= 0xFFE6) ||
                 (scalar.value >= 0x20000 && scalar.value <= 0x2FFFD) ||
                 (scalar.value >= 0x30000 && scalar.value <= 0x3FFFD)) {
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }
}
