//
//  FlowTextBlock.swift
//  AgentKit
//
//  Concatenates consecutive flow blocks (paragraphs, headings, lists, blockquotes)
//  into a single Text view for continuous multi-line text selection.
//  Mirrors Claude Code's ability to select across multiple rendered lines.
//

import SwiftUI

/// Renders a sequence of flow blocks as one concatenated Text,
/// enabling continuous text selection across block boundaries.
struct FlowTextBlock: View {
    let blocks: [MarkdownBlock]
    var baseFont: Font = .body
    var fillWidth: Bool = true

    var body: some View {
        flowText
            .textSelection(.enabled)
            .lineSpacing(4)
            .frame(
                maxWidth: fillWidth ? .infinity : nil,
                alignment: fillWidth ? .leading : .center
            )
    }

    // MARK: - Text Concatenation

    @ViewBuilder
    private var flowText: some View {
        if blocks.isEmpty {
            EmptyView()
        } else {
            concatenatedText
        }
    }

    var concatenatedText: Text {
        var text = blockToText(blocks[0])
        for block in blocks.dropFirst() {
            text = text + Text("\n") + blockToText(block)
        }
        return text
    }

    // MARK: - Block to Text Conversion

    private func blockToText(_ block: MarkdownBlock) -> Text {
        switch block {
        case .paragraph(let inlines):
            return Text(MarkdownInlineRenderer.render(inlines, baseFont: baseFont))

        case .heading(let level, let inlines):
            return Text(MarkdownInlineRenderer.render(inlines, baseFont: baseFont))
                .font(headingFont(level))
                .foregroundColor(.primary)

        case .blockquote(let innerBlocks):
            let innerText = FlowTextBlock(blocks: innerBlocks, baseFont: baseFont, fillWidth: fillWidth).concatenatedText
            return innerText
                .italic()
                .foregroundColor(.secondary)

        case .unorderedList(let items):
            return listItemsToText(items, marker: { _ in "•" })

        case .orderedList(let items, let startIndex):
            return listItemsToText(items, marker: { i in "\(Int(startIndex) + i)." })

        default:
            return Text("")
        }
    }

    private func listItemsToText(_ items: [MarkdownListItem], marker: (Int) -> String) -> Text {
        guard !items.isEmpty else { return Text("") }

        var text = listItemToText(items[0], marker: marker(0))
        for (i, item) in items.dropFirst().enumerated() {
            text = text + Text("\n") + listItemToText(item, marker: marker(i + 1))
        }
        return text
    }

    private func listItemToText(_ item: MarkdownListItem, marker: String) -> Text {
        let innerBlocks = item.blocks
        guard !innerBlocks.isEmpty else { return Text(marker) }

        let contentText = FlowTextBlock(blocks: innerBlocks, baseFont: baseFont, fillWidth: fillWidth).concatenatedText

        let fullText = Text(marker + " ").foregroundColor(.secondary) + contentText

        if item.checkbox == .checked {
            return fullText.strikethrough()
        }
        return fullText
    }

    // MARK: - Font Helpers

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.medium)
        }
    }
}
