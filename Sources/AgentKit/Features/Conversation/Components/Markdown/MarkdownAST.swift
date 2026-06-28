//
//  MarkdownAST.swift
//  AgentKit
//
//  Bridge between swift-markdown's CommonMark AST and our application-level types.
//  No SwiftUI dependency — pure data transformation.
//

import Foundation
import Markdown

// MARK: - Application-Level Block Types

/// A parsed Markdown block element, decoupled from swift-markdown's AST.
enum MarkdownBlock: Equatable, Identifiable {
    case paragraph([InlineContent])
    case heading(level: Int, content: [InlineContent])
    case codeBlock(language: String, code: String)
    case blockquote(blocks: [MarkdownBlock])
    case unorderedList(items: [MarkdownListItem])
    case orderedList(items: [MarkdownListItem], startIndex: UInt)
    case thematicBreak
    case table(head: [TableCell], body: [[TableCell]])

    // MARK: Identifiable

    var id: String {
        switch self {
        case .paragraph(let c):
            return "p:\(c.map(\.storageHash).joined())"
        case .heading(let l, let c):
            return "h\(l):\(c.map(\.storageHash).joined())"
        case .codeBlock(let lang, let code):
            return "cb:\(lang):\(code.hashValue)"
        case .blockquote(let blocks):
            return "bq:\(blocks.map(\.id).joined(separator: ","))"
        case .unorderedList(let items):
            return "ul:\(items.map(\.id).joined(separator: ","))"
        case .orderedList(let items, let start):
            return "ol\(start):\(items.map(\.id).joined(separator: ","))"
        case .thematicBreak:
            return "hr"
        case .table(let head, let body):
            let hh = head.map(\.storageHash).joined()
            let bh = body.flatMap({ $0 }).map(\.storageHash).joined()
            return "tbl:\(hh):\(bh)"
        }
    }

    /// Whether this block should be rendered as inline flow text
    /// (can be concatenated with adjacent flow blocks for continuous text selection).
    var isFlowBlock: Bool {
        switch self {
        case .paragraph, .heading, .blockquote, .unorderedList, .orderedList:
            return true
        case .codeBlock, .thematicBreak, .table:
            return false
        }
    }
}

// MARK: - List & Table Sub-types

struct MarkdownListItem: Equatable, Identifiable {
    let blocks: [MarkdownBlock]
    /// Non-nil for GFM task list items (e.g. `- [x] item`).
    let checkbox: MarkdownCheckbox?
    var id: String { "li:\(checkbox.map { $0 == .checked ? "✓" : "○" } ?? "")-\(blocks.map(\.id).joined(separator: ","))" }
}

enum MarkdownCheckbox: Equatable {
    case checked
    case unchecked
}

struct TableCell: Equatable {
    let content: [InlineContent]
    let alignment: TableCellAlignment

    var storageHash: String {
        "tc:\(alignment.rawValue):\(content.map(\.storageHash).joined())"
    }
}

enum TableCellAlignment: String, Equatable {
    case left, center, right
}

// MARK: - Inline Content Types

enum InlineContent: Equatable {
    case text(String)
    case strong([InlineContent])
    case emphasis([InlineContent])
    case strikethrough([InlineContent])
    case inlineCode(String)
    case link(destination: String?, text: [InlineContent])
    case image(source: String?, altText: String)
    case softBreak
    case lineBreak

    /// Short hash for structural comparison (used in diff).
    var storageHash: String {
        switch self {
        case .text(let s): return "t\(s.hashValue)"
        case .strong(let c): return "s(\(c.map(\.storageHash).joined()))"
        case .emphasis(let c): return "e(\(c.map(\.storageHash).joined()))"
        case .strikethrough(let c): return "st(\(c.map(\.storageHash).joined()))"
        case .inlineCode(let s): return "ic\(s.hashValue)"
        case .link(let d, let c): return "l[\(d ?? "")](\(c.map(\.storageHash).joined()))"
        case .image(let s, let a): return "img[\(s ?? "")][\(a.hashValue)]"
        case .softBreak: return "sb"
        case .lineBreak: return "lb"
        }
    }
}

// MARK: - AST Conversion

/// Converts swift-markdown's Document into our [MarkdownBlock] array.
enum MarkdownASTConverter {

    /// Parse markdown text into application-level blocks.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let document = Document(parsing: text)
        return convertBlocks(document.children)
    }

    // MARK: - Block Conversion

    private static func convertBlocks(_ children: some Sequence<Markup>) -> [MarkdownBlock] {
        children.compactMap { convertBlock($0) }
    }

    private static func convertBlock(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let p as Paragraph:
            let inlines = convertInlines(p.children)
            guard !inlines.isEmpty else { return nil }
            return .paragraph(inlines)

        case let h as Heading:
            let inlines = convertInlines(h.children)
            return .heading(level: h.level, content: inlines)

        case let cb as CodeBlock:
            let lang = SyntaxHighlighter.inferLanguage(from: cb.language)
            return .codeBlock(language: lang, code: cb.code)

        case let bq as BlockQuote:
            let blocks = convertBlocks(bq.children)
            guard !blocks.isEmpty else { return nil }
            return .blockquote(blocks: blocks)

        case let ul as UnorderedList:
            let items = ul.children.compactMap { convertListItem($0) }
            guard !items.isEmpty else { return nil }
            return .unorderedList(items: items)

        case let ol as OrderedList:
            let items = ol.children.compactMap { convertListItem($0) }
            guard !items.isEmpty else { return nil }
            return .orderedList(items: items, startIndex: ol.startIndex)

        case is ThematicBreak:
            return .thematicBreak

        case let table as Markdown.Table:
            return convertTable(table)

        default:
            return nil
        }
    }

    private static func convertListItem(_ markup: Markup) -> MarkdownListItem? {
        guard let li = markup as? ListItem else { return nil }
        let blocks = convertBlocks(li.children)
        let checkbox: MarkdownCheckbox? = {
            switch li.checkbox {
            case .checked: return .checked
            case .unchecked: return .unchecked
            case .none: return nil
            }
        }()
        return MarkdownListItem(blocks: blocks, checkbox: checkbox)
    }

    private static func convertTable(_ table: Markdown.Table) -> MarkdownBlock {
        let alignments: [TableCellAlignment] = table.columnAlignments.map { align in
            guard let align else { return .left }
            switch align {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        let headCells: [TableCell] = table.head.cells.enumerated().map { i, cell in
            let a = i < alignments.count ? alignments[i] : .left
            return TableCell(content: convertInlines(cell.children), alignment: a)
        }

        let bodyRows: [[TableCell]] = table.body.rows.map { row in
            row.cells.enumerated().map { i, cell in
                let a = i < alignments.count ? alignments[i] : .left
                return TableCell(content: convertInlines(cell.children), alignment: a)
            }
        }

        return .table(head: headCells, body: bodyRows)
    }

    // MARK: - Inline Conversion

    private static func convertInlines(_ children: some Sequence<Markup>) -> [InlineContent] {
        children.compactMap { convertInline($0) }
    }

    private static func convertInline(_ markup: Markup) -> InlineContent? {
        switch markup {
        case let t as Markdown.Text:
            return .text(t.string)

        case let s as Strong:
            return .strong(convertInlines(s.children))

        case let e as Emphasis:
            return .emphasis(convertInlines(e.children))

        case let s as Strikethrough:
            return .strikethrough(convertInlines(s.children))

        case let ic as InlineCode:
            return .inlineCode(ic.code)

        case let link as Markdown.Link:
            return .link(destination: link.destination, text: convertInlines(link.children))

        case let img as Markdown.Image:
            return .image(source: img.source, altText: img.plainText)

        case is SoftBreak:
            return .softBreak

        case is LineBreak:
            return .lineBreak

        case is InlineHTML:
            return nil

        default:
            if let plain = (markup as? InlineMarkup)?.plainText, !plain.isEmpty {
                return .text(plain)
            }
            return nil
        }
    }
}
