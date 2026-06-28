//
//  MarkdownInlineRenderer.swift
//  AgentKit
//
//  Renders inline Markdown content into AttributedString.
//  AST-based: walks InlineContent nodes via direct concatenation.
//  NO regex, NO range manipulation, NO replaceSubrange — eliminates
//  the source/attributed range-mismatch class of bugs.
//

import SwiftUI

// MARK: - Inline Renderer

enum MarkdownInlineRenderer {

    /// Render an array of inline content into a single AttributedString.
    static func render(
        _ content: [InlineContent],
        baseFont: Font = .body
    ) -> AttributedString {
        var result = AttributedString()
        for node in content {
            let part = renderNode(node, baseFont: baseFont)
            result.append(part)
        }
        return result
    }

    // MARK: - Node Rendering

    private static func renderNode(_ node: InlineContent, baseFont: Font) -> AttributedString {
        switch node {
        case .text(let string):
            var attr = AttributedString(string)
            attr.font = baseFont
            attr.foregroundColor = .primary
            return attr

        case .strong(let children):
            return render(children, baseFont: baseFont.bold())

        case .emphasis(let children):
            return render(children, baseFont: baseFont.italic())

        case .strikethrough(let children):
            var result = render(children, baseFont: baseFont)
            result.strikethroughStyle = .single
            return result

        case .inlineCode(let code):
            var attr = AttributedString(code)
            attr.font = MarkdownFont.inlineCode
            attr.foregroundColor = Color.inlineCodeForeground
            return attr

        case .link(let destination, let text):
            var result = render(text, baseFont: baseFont)
            result.foregroundColor = Color.linkForeground
            result.underlineStyle = .single
            if let url = destination.flatMap(URL.init(string:)) {
                result.link = url
            }
            return result

        case .image(_, let altText):
            var attr = AttributedString("[Image: \(altText)]")
            attr.font = baseFont.italic()
            attr.foregroundColor = .secondary
            return attr

        case .softBreak:
            var attr = AttributedString(" ")
            attr.font = baseFont
            return attr

        case .lineBreak:
            var attr = AttributedString("\n")
            attr.font = baseFont
            return attr
        }
    }
}
