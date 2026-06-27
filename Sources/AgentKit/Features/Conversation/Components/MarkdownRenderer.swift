//
//  MarkdownRenderer.swift
//  AgentKit
//
//  Renders Markdown text into SwiftUI views with syntax-highlighted code blocks.
//  Handles: paragraphs, code blocks (```), inline code (`), bold, italic, lists.
//  Used by MessageBubble and ThinkingCard for rich text rendering.
//

import SwiftUI

// MARK: - MarkdownRenderer

/// Parses and renders Markdown text into a vertical stack of block elements.
struct MarkdownRenderer: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

// MARK: - MarkdownBlock

/// A parsed Markdown block element.
enum MarkdownBlock {
    case paragraph(AttributedString)
    case codeBlock(language: String, code: String)
    case heading(AttributedString, level: Int)
    case listItem(AttributedString, indent: Int)
    case blockquote(AttributedString)
    case divider
}

// MARK: - MarkdownParser

/// Simple line-based Markdown parser.
/// Phase 1: handles code fences, headings, lists, blockquotes, bold, italic, inline code.
/// Full CommonMark compliance is not the goal — agent output readability is.
enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code fence start
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                let code = codeLines.joined(separator: "\n")
                let lang = SyntaxHighlighter.inferLanguage(from: language.isEmpty ? nil : language)
                blocks.append(.codeBlock(language: lang, code: code))
                continue
            }

            // Heading
            if line.hasPrefix("### ") {
                blocks.append(.heading(parseInline(String(line.dropFirst(4))), level: 3))
                i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(parseInline(String(line.dropFirst(3))), level: 2))
                i += 1; continue
            }
            if line.hasPrefix("# ") {
                blocks.append(.heading(parseInline(String(line.dropFirst(2))), level: 1))
                i += 1; continue
            }

            // Divider
            if line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }),
               line.trimmingCharacters(in: .whitespaces).count >= 3 {
                blocks.append(.divider)
                i += 1; continue
            }

            // Blockquote
            if line.hasPrefix("> ") {
                blocks.append(.blockquote(parseInline(String(line.dropFirst(2)))))
                i += 1; continue
            }

            // Unordered list
            if let match = line.captureTwoGroups(pattern: #"^(\s*)[-*+]\s+(.+)"#) {
                let indent = match.0.count
                blocks.append(.listItem(parseInline(match.1), indent: indent))
                i += 1; continue
            }

            // Ordered list
            if let match = line.captureTwoGroups(pattern: #"^(\s*)\d+\.\s+(.+)"#) {
                let indent = match.0.count
                blocks.append(.listItem(parseInline(match.1), indent: indent))
                i += 1; continue
            }

            // Empty line → skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }

            // Paragraph — collect consecutive non-empty lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.hasPrefix("```") || l.hasPrefix("#") || l.hasPrefix(">") ||
                   l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") ||
                   l.captureGroup(pattern: #"^\d+\.\s"#) != nil { break }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                let para = paraLines.joined(separator: "\n")
                blocks.append(.paragraph(parseInline(para)))
            } else {
                i += 1
            }
        }

        return blocks
    }

    // MARK: - Inline parsing

    static func parseInline(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        result.font = .body
        result.foregroundColor = .primary

        // Apply inline formatting via regex

        // Bold + Italic (***text***)
        applyInlinePattern("\\*\\*\\*(.+?)\\*\\*\\*", to: &result, in: text) { attr in
            attr.font = .body.italic().bold()
        }

        // Bold (**text**)
        applyInlinePattern("\\*\\*(.+?)\\*\\*", to: &result, in: text) { attr in
            attr.font = .body.bold()
        }

        // Italic (*text*)
        applyInlinePattern("\\*(.+?)\\*", to: &result, in: text) { attr in
            attr.font = .body.italic()
        }

        // Inline code (`text`)
        applyInlinePattern("`(.+?)`", to: &result, in: text) { attr in
            attr.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
//            attr.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.3)
            attr.foregroundColor = .systemPink
        }

        // Links [text](url) — style as underlined
        applyInlinePattern("\\[([^\\]]+)\\]\\([^)]+\\)", to: &result, in: text) { attr in
            attr.foregroundColor = .systemBlue
            attr.underlineStyle = .single
        }

        return result
    }

    private static func applyInlinePattern(
        _ pattern: String,
        to attributed: inout AttributedString,
        in source: String,
        transform: (inout AttributedString) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let innerRange = Range(match.range(at: 1), in: source) else { continue }

            let innerText = String(source[innerRange])
            var innerAttr = AttributedString(innerText)
            innerAttr.font = .body
            transform(&innerAttr)
            // Replace the full match (with delimiters) with styled inner text
            if let fullAttrRange = Range(match.range(at: 0), in: attributed) {
                attributed.replaceSubrange(fullAttrRange, with: innerAttr)
            }
        }
    }
}

// MARK: - MarkdownBlockView

/// Renders a single MarkdownBlock.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let attr):
            Text(attr)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .heading(let attr, let level):
            Text(attr)
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)

        case .listItem(let attr, let indent):
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(attr)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent * 8))

        case .blockquote(let attr):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(attr)
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(.leading, 8)
                    .textSelection(.enabled)
            }

        case .divider:
            Divider()
                .padding(.vertical, 2)
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

// MARK: - CodeBlockView

/// Renders a syntax-highlighted code block with dark background, language tag, and copy button.
struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToClipboard()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.1))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                let highlighted = SyntaxHighlighter.highlight(code, language: language)
                Text(highlighted)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

// MARK: - Regex helpers (namespaced to avoid conflict with ToolSemanticMapper)

private extension String {
    /// Capture two groups from pattern. Returns (group1, group2).
    func captureTwoGroups(pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 2,
              let r1 = Range(match.range(at: 1), in: self),
              let r2 = Range(match.range(at: 2), in: self) else { return nil }
        return (String(self[r1]), String(self[r2]))
    }

    /// Capture single group from pattern. Returns group1 or nil.
    func captureGroup(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
