//
//  TranscriptDocument.swift
//  AgentKit
//
//  Native-text transcript model for selectable conversation turns.
//

import Foundation

#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont
#endif

// MARK: - Transcript Actions

enum TranscriptAction: Hashable {
    case toggleTool(callID: String)
    case openArtifact(callID: String)
    case openAsset(AssetReference)
    case openURL(String)
    case openPath(String)
    case openChildStream(childID: String)
    case copyBlock(text: String)
}

struct TranscriptDocumentState: Hashable {
    var expandedToolIDs: Set<String> = []

    mutating func toggleTool(callID: String) {
        if expandedToolIDs.contains(callID) {
            expandedToolIDs.remove(callID)
        } else {
            expandedToolIDs.insert(callID)
        }
    }
}

struct AttributedTranscript {
    let attributedString: NSAttributedString
    let actions: [String: TranscriptAction]
    let copyText: String
}

// MARK: - Builder

enum TurnTranscriptBuilder {

    static func build(
        turn: ConversationTurn,
        state: TranscriptDocumentState,
        animationFrame: Int = 0
    ) -> AttributedTranscript {
        let assetIndex = AssetIndex(turn: turn)
        var builder = TranscriptAttributedBuilder(
            assetIndex: assetIndex,
            animationFrame: animationFrame
        )

        if let user = turn.userPrompt {
            builder.appendHeading("You")
            builder.appendMarkdown(user.text)
            builder.appendBlankLine()
        }

        builder.appendHeading("Agent")

        for (index, block) in turn.blocks.enumerated() {
            switch block {
            case .text(_, let payload):
                builder.appendMarkdown(payload.text, textAnnotations: payload.textAnnotations)

            case .toolGroup(let group):
                appendToolGroup(group, state: state, to: &builder)

            case .artifact(_, let artifact):
                appendArtifact(artifact, to: &builder)

            case .system(_, let payload):
                appendSystem(payload, to: &builder)

            case .childStream(_, let payload):
                builder.appendChildStreamRow(
                    payload,
                    action: .openChildStream(childID: payload.childID)
                )
            }

            if index < turn.blocks.count - 1 {
                builder.appendBlankLine()
            }
        }

        if let footer = turn.footer {
            builder.appendBlankLine()
            let invocations = footer.invocationCount > 1 ? " | \(footer.invocationCount)x" : ""
            builder.appendMeta("\(footer.formattedTokens) tokens | \(footer.formattedElapsed)\(invocations)")
        }

        return builder.finish()
    }

    private static func appendToolGroup(
        _ group: ToolGroup,
        state: TranscriptDocumentState,
        to builder: inout TranscriptAttributedBuilder
    ) {
        if group.tools.count > 1 {
            appendMergedToolGroup(group, state: state, to: &builder)
            return
        }

        for tool in group.tools {
            appendSingleTool(tool, state: state, to: &builder)
        }
    }

    private static func appendMergedToolGroup(
        _ group: ToolGroup,
        state: TranscriptDocumentState,
        to builder: inout TranscriptAttributedBuilder
    ) {
        let expansionID = groupExpansionID(for: group)
        let expanded = state.expandedToolIDs.contains(expansionID)
        let presentation = ToolTranscriptPresenter.groupPresentation(for: group)

        builder.appendToolGroupSummary(
            presentation,
            expanded: expanded,
            action: .toggleTool(callID: expansionID)
        )
        if expanded {
            for tool in group.tools {
                let toolPresentation = ToolTranscriptPresenter.presentation(for: tool)
                let toolExpanded = state.expandedToolIDs.contains(tool.callID)
                builder.appendToolRow(
                    toolPresentation,
                    expanded: toolExpanded,
                    action: .toggleTool(callID: tool.callID),
                    nested: true
                )
                if toolExpanded {
                    appendExpandedTool(tool, presentation: toolPresentation, to: &builder)
                }
            }
        }
    }

    private static func appendSingleTool(
        _ tool: ToolNodePayload,
        state: TranscriptDocumentState,
        to builder: inout TranscriptAttributedBuilder
    ) {
        let expanded = state.expandedToolIDs.contains(tool.callID)
        let presentation = ToolTranscriptPresenter.presentation(for: tool)

        builder.appendToolRow(
            presentation,
            expanded: expanded,
            action: .toggleTool(callID: tool.callID),
            nested: false
        )

        if expanded {
            appendExpandedTool(tool, presentation: presentation, to: &builder)
        }
    }

    private static func appendExpandedTool(
        _ tool: ToolNodePayload,
        presentation: ToolTranscriptPresentation,
        to builder: inout TranscriptAttributedBuilder
    ) {
        if let argsText = formattedArgs(tool.args) {
            builder.appendIndentedLabel("Input")
            builder.appendCode(argsText, language: "json")
        }

        if !tool.output.isEmpty {
            builder.appendIndentedLabel("Output")
            switch presentation.outputKind {
            case .diff:
                builder.appendDiff(tool.output)
            case .json:
                builder.appendCode(tool.output, language: "json")
            case .code(let language):
                builder.appendCode(tool.output, language: language)
            case .terminal:
                builder.appendCode(tool.output, language: "shell")
            case .text:
                builder.appendCode(tool.output, language: "text")
            }
        }

        if let artifact = tool.artifact {
            builder.appendIndentedLabel("Artifact")
            builder.appendActionLine(
                SummaryRenderer.summary(for: artifact),
                action: .openArtifact(callID: tool.callID),
                style: .artifact
            )
            if case .diff(let payload) = artifact.content, !payload.diffContent.isEmpty {
                builder.appendDiff(payload.diffContent)
            }
        }
    }

    private static func appendArtifact(_ artifact: ArtifactNode, to builder: inout TranscriptAttributedBuilder) {
        builder.appendActionLine(
            "[artifact] \(SummaryRenderer.summary(for: artifact))",
            action: .openArtifact(callID: artifact.callID),
            style: .artifact
        )
        if let path = artifact.path, !path.isEmpty {
            builder.appendActionLine(
                path,
                action: .openPath(path),
                style: .path
            )
        }
    }

    private static func appendSystem(
        _ payload: SystemNodePayload,
        to builder: inout TranscriptAttributedBuilder
    ) {
        if payload.isTranscriptError {
            builder.appendSystemError(payload.text)
        } else {
            builder.appendMeta("[\(payload.kind.rawValue)] \(payload.text)")
        }
    }

    private static func formattedArgs(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let pretty = value.prettyJSONString, !pretty.isEmpty {
            return pretty
        }
        let raw = value.stringValue
        return raw.isEmpty ? nil : raw
    }

    private static func groupExpansionID(for group: ToolGroup) -> String {
        "group:\(group.id)"
    }
}

private extension SystemNodePayload {
    var isTranscriptError: Bool {
        if kind == .error { return true }
        guard kind == .observation else { return false }
        let lower = text.lowercased()
        return lower.contains("tool error")
            || lower.contains("error:")
            || lower.contains("failed")
            || lower.contains("http 4")
            || lower.contains("http 5")
    }
}

// MARK: - Attributed Builder

private struct TranscriptAttributedBuilder {
    enum ActionStyle {
        case tool
        case artifact
        case path
    }

    private var attributed = NSMutableAttributedString()
    private let assetIndex: AssetIndex
    private let animationFrame: Int
    private(set) var actions: [String: TranscriptAction] = [:]
    private var copyParts: [String] = []
    private var nextActionIndex = 0
    private var nextBlockRunID = 0
    private var listDepth = 0
    private var quoteDepth = 0
    private var activeTextAnnotations: [AgentTextAnnotation] = []
    private var consumedTextAnnotationKeys = Set<String>()

    init(assetIndex: AssetIndex, animationFrame: Int) {
        self.assetIndex = assetIndex
        self.animationFrame = animationFrame
    }

    mutating func appendHeading(_ text: String) {
        append(text + "\n", attributes: headingAttributes)
        copyParts.append(text)
    }

    mutating func appendBody(_ text: String) {
        appendTextWithAssetLinks(text, attributes: bodyAttributes)
        copyParts.append(text)
    }

    mutating func appendMarkdown(_ text: String, textAnnotations: [AgentTextAnnotation] = []) {
        let previousAnnotations = activeTextAnnotations
        let previousConsumedKeys = consumedTextAnnotationKeys
        activeTextAnnotations = textAnnotations.resolvingNearbyLineNumberAssets(assetIndex: assetIndex)
        consumedTextAnnotationKeys = []
        defer {
            activeTextAnnotations = previousAnnotations
            consumedTextAnnotationKeys = previousConsumedKeys
        }

        let blocks = MarkdownASTConverter.parse(text)
        guard !blocks.isEmpty else {
            appendBody(text)
            return
        }

        for (index, block) in blocks.enumerated() {
            appendMarkdownBlock(block)
            if index < blocks.count - 1 {
                append("\n", attributes: bodyAttributes)
            }
        }
        copyParts.append(text)
    }

    mutating func appendMeta(_ text: String) {
        append(text, attributes: metaAttributes)
        copyParts.append(text)
    }

    mutating func appendSystemError(_ text: String) {
        let block = makeBlock(.error)
        var labelAttrs = systemErrorLabelAttributes
        labelAttrs[.transcriptBlock] = block
        var bodyAttrs = systemErrorBodyAttributes
        bodyAttrs[.transcriptBlock] = block
        append("! Error  ", attributes: labelAttrs)
        append(text, attributes: bodyAttrs)
        copyParts.append("Error: \(text)")
    }

    mutating func appendIndentedLabel(_ text: String) {
        append("\n  \(text)\n", attributes: labelAttributes)
        copyParts.append(text)
    }

    mutating func appendToolTargetList(_ targets: [String]) {
        for target in targets {
            append("\n  - ", attributes: metaAttributes)
            appendTextWithAssetLinks(target, attributes: toolTargetAttributes)
            copyParts.append(target)
        }
    }

    mutating func appendToolGroupSummary(
        _ presentation: ToolTranscriptGroupPresentation,
        expanded: Bool,
        action: TranscriptAction
    ) {
        let id = register(action)
        let indicator = expanded ? "⌄" : "›"
        appendLinked(toolIcon(for: .other, tone: presentation.statusTone), id: id, attributes: toolIconAttributes(for: .other, tone: presentation.statusTone))
        appendLinked(" \(presentation.summary)", id: id, attributes: toolSummaryAttributes(for: presentation.statusTone))
        appendLinked(" \(indicator)", id: id, attributes: toolChevronAttributes)
        copyParts.append("\(presentation.summary) \(indicator)")
    }

    mutating func appendToolRow(
        _ presentation: ToolTranscriptPresentation,
        expanded: Bool,
        action: TranscriptAction,
        nested: Bool
    ) {
        let id = register(action)
        let indicator = expanded ? "⌄" : "›"
        if nested {
            append("\n  ", attributes: toolRailAttributes)
        }

        appendLinked(toolIcon(for: presentation.family, tone: presentation.statusTone), id: id, attributes: toolIconAttributes(for: presentation.family, tone: presentation.statusTone))
        appendLinked(" \(presentation.title)", id: id, attributes: toolTitleAttributes(for: presentation.statusTone, nested: nested))

        if let changeSummary = presentation.changeSummary {
            appendChangeSummary(changeSummary, id: id)
        }
        if let detail = presentation.detail {
            appendLinked("  \(detail)", id: id, attributes: toolDetailAttributes)
        }
        if let statusText = presentation.statusText {
            appendLinked("  \(statusText)", id: id, attributes: toolStatusTextAttributes(for: presentation.statusTone))
        }
        if let elapsed = presentation.elapsed {
            appendLinked("  \(elapsed)", id: id, attributes: toolDetailAttributes)
        }
        appendLinked(" \(indicator)", id: id, attributes: toolChevronAttributes)
        copyParts.append(presentation.compactLine)
    }

    /// P8.7 — 子流入口卡行（task 子agent / 后台 job）：
    /// 图标 + 类别 + 一句话摘要 + 状态，整行可点，点击展开子流查看器。
    /// 结束后追加一行结果摘要（dim）。
    mutating func appendChildStreamRow(_ payload: ChildStreamNodePayload, action: TranscriptAction) {
        let id = register(action)
        let tone: ToolTranscriptStatusTone = {
            switch payload.status {
            case .running: return .running
            case .failed: return .failed
            case .completed, .canceled: return .completed
            }
        }()

        let label = payload.kind == .task ? "Subagent" : "Job"
        let summary = singleLineSummary(payload.title, limit: 60)
        let statusText: String? = {
            switch payload.status {
            case .running: return "running"
            case .failed:
                // §8.5：-1 = 启动失败/被信号杀死；>0 = 命令非零退出。
                if let code = payload.exitCode, code == -1 { return "killed" }
                if let code = payload.exitCode, code > 0 { return "exit \(code)" }
                return "failed"
            case .canceled: return "canceled"
            case .completed: return "done"
            }
        }()

        appendLinked(toolIcon(for: .other, tone: tone), id: id,
                     attributes: toolIconAttributes(for: .other, tone: tone))
        appendLinked(" \(label)", id: id, attributes: toolTitleAttributes(for: tone, nested: false))
        if !summary.isEmpty {
            appendLinked("  \(summary)", id: id, attributes: toolDetailAttributes)
        }
        if let statusText {
            appendLinked("  \(statusText)", id: id, attributes: toolStatusTextAttributes(for: tone))
        }
        if let elapsed = payload.formattedElapsed {
            appendLinked("  \(elapsed)", id: id, attributes: toolDetailAttributes)
        }
        appendLinked(" ›", id: id, attributes: toolChevronAttributes)
        copyParts.append("\(label): \(summary)")

        if payload.status != .running,
           let result = payload.result?.trimmingCharacters(in: .whitespacesAndNewlines),
           !result.isEmpty {
            let resultLine = singleLineSummary(result, limit: 120)
            append("\n", attributes: metaAttributes)
            appendLinked("  \(resultLine)", id: id, attributes: metaAttributes)
            copyParts.append(resultLine)
        }
    }

    private func singleLineSummary(_ text: String, limit: Int) -> String {
        let firstLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .first ?? ""
        if firstLine.count > limit {
            return String(firstLine.prefix(limit - 1)) + "…"
        }
        return firstLine
    }

    /// Code blocks are tagged with `.transcriptBlock` so the text view can
    /// draw a full-width rounded background; horizontal padding comes from
    /// paragraph indents, so the copied text stays clean of manual indents.
    mutating func appendCode(_ text: String, language: String? = nil, recordCopy: Bool = true) {
        let block = makeBlock(.code)
        if let language, !language.isEmpty {
            var labelAttrs = codeLabelAttributes
            labelAttrs[.transcriptBlock] = block
            append(language.uppercased(), attributes: labelAttrs)
            appendCopyGlyph(for: text, block: block)
            append("\n", attributes: labelAttrs)
        }
        var attrs = codeAttributes
        attrs[.transcriptBlock] = block
        appendHighlightedCode(text, language: language, attributes: attrs)
        if recordCopy {
            copyParts.append(text)
        }
    }

    mutating func appendDiff(_ text: String, recordCopy: Bool = true) {
        let lines = text.components(separatedBy: "\n")
        var runBlock: TranscriptBlockValue?
        for (index, line) in lines.enumerated() {
            let kind = diffBlockKind(for: line)
            if runBlock?.kind != kind {
                runBlock = makeBlock(kind)
            }
            var attrs = diffAttributes(for: line)
            attrs[.transcriptBlock] = runBlock
            appendTextWithAssetLinks(line, attributes: attrs)
            if index < lines.count - 1 {
                append("\n", attributes: attrs)
            }
        }
        if recordCopy {
            copyParts.append(text)
        }
    }

    private mutating func appendCopyGlyph(for text: String, block: TranscriptBlockValue) {
        let id = register(.copyBlock(text: text))
        var attrs = toolChevronAttributes
        attrs[.transcriptBlock] = block
        appendLinked("  ⧉", id: id, attributes: attrs)
    }

    private mutating func makeBlock(_ kind: TranscriptBlockKind) -> TranscriptBlockValue {
        let block = TranscriptBlockValue(kind: kind, runID: nextBlockRunID)
        nextBlockRunID += 1
        return block
    }

    private func diffBlockKind(for line: String) -> TranscriptBlockKind {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .diffAdded }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .diffRemoved }
        if line.hasPrefix("@@") { return .diffHunk }
        return .diffContext
    }

    mutating func appendActionLine(_ text: String, action: TranscriptAction, style: ActionStyle) {
        let id = register(action)
        let url = URL(string: "agentkit-transcript://\(id)")!
        var attrs = attributes(for: style)
        attrs[.link] = url
        append(text, attributes: attrs)
        copyParts.append(text)
    }

    mutating func appendBlankLine() {
        append("\n\n", attributes: bodyAttributes)
        copyParts.append("")
    }

    mutating func finish() -> AttributedTranscript {
        AttributedTranscript(
            attributedString: attributed,
            actions: actions,
            copyText: copyParts.joined(separator: "\n")
        )
    }

    private mutating func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        attributed.append(NSAttributedString(string: text, attributes: attributes))
    }

    private mutating func appendLinked(
        _ text: String,
        id: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let url = URL(string: "agentkit-transcript://\(id)")!
        var attrs = attributes
        attrs[.link] = url
        attributed.append(NSAttributedString(string: text, attributes: attrs))
    }

    private mutating func appendChangeSummary(_ summary: String, id: String) {
        let parts = summary.split(separator: " ", omittingEmptySubsequences: false)
        for part in parts {
            let text = " \(part)"
            if part.hasPrefix("+") {
                appendLinked(text, id: id, attributes: toolDiffAddedAttributes)
            } else if part.hasPrefix("-") {
                appendLinked(text, id: id, attributes: toolDiffRemovedAttributes)
            } else {
                appendLinked(text, id: id, attributes: toolDetailAttributes)
            }
        }
    }

    private mutating func appendMarkdownBlock(_ block: MarkdownBlock) {
        switch block {
        case .paragraph(let inlines):
            appendInlines(inlines, attributes: bodyAttributes)

        case .heading(let level, let inlines):
            appendInlines(inlines, attributes: markdownHeadingAttributes(level: level))

        case .codeBlock(let language, let code):
            appendCode(code, language: language.isEmpty ? "text" : language, recordCopy: false)

        case .blockquote(let blocks):
            appendBlockquote(blocks)

        case .unorderedList(let items):
            appendList(items: items) { _ in "-" }

        case .orderedList(let items, let startIndex):
            appendList(items: items) { i in "\(Int(startIndex) + i)." }

        case .thematicBreak:
            // A placeholder space keeps the paragraph in the selectable text
            // flow; the renderer draws the full-width hairline over it.
            var dividerAttrs = metaAttributes
            dividerAttrs[.transcriptBlock] = makeBlock(.divider)
            append(" ", attributes: dividerAttrs)

        case .table(let head, let body):
            appendTable(head: head, rows: body)
        }
    }

    /// Quote body renders in the secondary tone with a leading indent; the
    /// vertical bar is drawn by the layout manager from the `.quote` block tag.
    private mutating func appendBlockquote(_ blocks: [MarkdownBlock]) {
        quoteDepth += 1
        let start = attributed.length
        for (index, inner) in blocks.enumerated() {
            appendMarkdownBlock(inner)
            if index < blocks.count - 1 {
                append("\n", attributes: bodyAttributes)
            }
        }
        quoteDepth -= 1

        // Tag everything appended for the bar, without clobbering nested
        // blocks (code inside a quote keeps its code background).
        let block = makeBlock(.quote)
        let range = NSRange(location: start, length: attributed.length - start)
        guard range.length > 0 else { return }
        attributed.enumerateAttribute(.transcriptBlock, in: range) { value, subrange, _ in
            if value == nil {
                attributed.addAttribute(.transcriptBlock, value: block, range: subrange)
            }
        }
    }

    private mutating func appendList(
        items: [MarkdownListItem],
        marker: (Int) -> String
    ) {
        listDepth += 1
        defer { listDepth -= 1 }

        for (index, item) in items.enumerated() {
            let prefix: String
            if let checkbox = item.checkbox {
                prefix = checkbox == .checked ? "[x]" : "[ ]"
            } else {
                prefix = marker(index)
            }

            append("\(prefix) ", attributes: metaAttributes)
            for (blockIndex, block) in item.blocks.enumerated() {
                appendMarkdownBlock(block)
                if blockIndex < item.blocks.count - 1 {
                    append("\n", attributes: bodyAttributes)
                }
            }

            if index < items.count - 1 {
                append("\n", attributes: bodyAttributes)
            }
        }
    }

    /// Tab-stop table: each row is one paragraph with cells joined by tabs,
    /// and tab stops placed at measured column positions. Wrapped cell text
    /// hangs under the last column instead of snapping back to the margin,
    /// and selection copy yields tab-separated rows. Cells skip syntax
    /// highlighting (no stray number tinting in prose) but keep link and
    /// annotation detection.
    private mutating func appendTable(head: [TableCell], rows: [[TableCell]]) {
        // Tabs are the column separator — scrub them from cell content.
        let headTexts = head.map { inlinePlainText($0.content).replacingOccurrences(of: "\t", with: " ") }
        let bodyTexts = rows.map { row in
            row.map { inlinePlainText($0.content).replacingOccurrences(of: "\t", with: " ") }
        }
        let allRows = (headTexts.isEmpty ? [] : [headTexts]) + bodyTexts
        guard !allRows.isEmpty else { return }

        let columnCount = allRows.map(\.count).max() ?? 0
        let measureFont = PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .semibold)
        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in allRows {
            for (column, cell) in row.enumerated() {
                let width = ceil((cell as NSString).size(withAttributes: [.font: measureFont]).width)
                columnWidths[column] = max(columnWidths[column], width)
            }
        }

        let columnGap: CGFloat = 16
        var columnStarts: [CGFloat] = []
        var x: CGFloat = 0
        for width in columnWidths {
            columnStarts.append(x)
            x += width + columnGap
        }
        let lastColumnStart = columnStarts.last ?? 0

        func line(_ row: [String]) -> String {
            (0..<columnCount)
                .map { $0 < row.count ? row[$0] : "" }
                .joined(separator: "\t")
        }

        let block = makeBlock(.table)
        var headerAttrs = tableHeaderAttributes
        headerAttrs[.transcriptBlock] = block
        headerAttrs[.transcriptTableHeader] = true
        headerAttrs[.paragraphStyle] = tableRowParagraphStyle(
            spacingAfter: 5, // room for the hairline drawn under the header
            columnStarts: columnStarts,
            lastColumnStart: lastColumnStart
        )
        var rowAttrs = tableAttributes
        rowAttrs[.transcriptBlock] = block
        rowAttrs[.paragraphStyle] = tableRowParagraphStyle(
            spacingAfter: 1,
            columnStarts: columnStarts,
            lastColumnStart: lastColumnStart
        )

        if !headTexts.isEmpty {
            appendHighlightedCode(line(headTexts), language: nil, attributes: headerAttrs, highlighted: false)
            if !bodyTexts.isEmpty {
                append("\n", attributes: headerAttrs)
            }
        }
        for (index, row) in bodyTexts.enumerated() {
            appendHighlightedCode(line(row), language: nil, attributes: rowAttrs, highlighted: false)
            if index < bodyTexts.count - 1 {
                append("\n", attributes: rowAttrs)
            }
        }
    }

    /// Row paragraphs share the block inset; tab stops sit at each column's
    /// measured start, and wrapped lines hang under the last column.
    private func tableRowParagraphStyle(
        spacingAfter: CGFloat,
        columnStarts: [CGFloat],
        lastColumnStart: CGFloat
    ) -> NSParagraphStyle {
        guard let style = paragraphStyle(spacingAfter: spacingAfter, blockInset: true)
            .mutableCopy() as? NSMutableParagraphStyle else {
            return paragraphStyle(spacingAfter: spacingAfter, blockInset: true)
        }
        let base = style.firstLineHeadIndent
        style.tabStops = columnStarts.dropFirst().map {
            NSTextTab(textAlignment: .left, location: base + $0, options: [:])
        }
        style.headIndent = base + lastColumnStart
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private mutating func appendInlines(
        _ inlines: [InlineContent],
        attributes: [NSAttributedString.Key: Any]
    ) {
        for inline in inlines {
            appendInline(inline, attributes: attributes)
        }
    }

    private mutating func appendInline(
        _ inline: InlineContent,
        attributes: [NSAttributedString.Key: Any]
    ) {
        switch inline {
        case .text(let text):
            appendTextWithAssetLinks(text, attributes: attributes)

        case .strong(let children):
            var attrs = attributes
            if let font = attrs[.font] as? PlatformFont {
                attrs[.font] = boldFont(from: font)
            }
            appendInlines(children, attributes: attrs)

        case .emphasis(let children):
            var attrs = attributes
            if let font = attrs[.font] as? PlatformFont {
                attrs[.font] = italicFont(from: font)
            }
            appendInlines(children, attributes: attrs)

        case .strikethrough(let children):
            var attrs = attributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            appendInlines(children, attributes: attrs)

        case .inlineCode(let code):
            appendTextWithAssetLinks(code, attributes: inlineCodeAttributes)

        case .link(let destination, let text):
            appendLink(destination: destination, text: text, attributes: attributes)

        case .image(_, let altText):
            append("[Image: \(altText)]", attributes: metaAttributes)

        case .softBreak:
            append(" ", attributes: attributes)

        case .lineBreak:
            append("\n", attributes: attributes)
        }
    }

    private mutating func appendLink(
        destination: String?,
        text: [InlineContent],
        attributes baseAttributes: [NSAttributedString.Key: Any]
    ) {
        let display = inlinePlainText(text)
        guard let destination, !destination.isEmpty else {
            appendInlines(text, attributes: baseAttributes)
            return
        }

        let reference: AssetReference
        if destination.hasPrefix("http://") || destination.hasPrefix("https://") {
            reference = assetIndex.reference(forURL: destination)
        } else {
            reference = assetIndex.reference(forPath: destination)
        }

        let id = register(.openAsset(reference))
        let url = URL(string: "agentkit-transcript://\(id)")!
        var attrs = actionAttributes(
            base: baseAttributes,
            color: reference.kind == .url ? accentColor : pathColor,
            underlined: reference.kind == .url
        )
        attrs[.font] = baseAttributes[.font]
        attrs[.link] = url
        append(display.isEmpty ? destination : display, attributes: attrs)
    }

    private mutating func appendTextWithAssetLinks(
        _ text: String,
        attributes baseAttributes: [NSAttributedString.Key: Any]
    ) {
        let matches = referenceMatches(in: text)
        guard !matches.isEmpty else {
            append(text, attributes: baseAttributes)
            return
        }

        let nsText = text as NSString
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let plainRange = NSRange(location: cursor, length: match.range.location - cursor)
                append(nsText.substring(with: plainRange), attributes: baseAttributes)
            }

            let linked = nsText.substring(with: match.range)
            let id = register(.openAsset(match.reference))
            let url = URL(string: "agentkit-transcript://\(id)")!
            var linkAttributes = actionAttributes(
                base: baseAttributes,
                color: match.reference.kind == .url ? accentColor : pathColor,
                underlined: match.reference.kind == .url
            )
            linkAttributes[.font] = baseAttributes[.font]
            linkAttributes[.link] = url
            append(linked, attributes: linkAttributes)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            append(
                nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)),
                attributes: baseAttributes
            )
        }
    }

    private mutating func appendHighlightedCode(
        _ text: String,
        language: String?,
        attributes: [NSAttributedString.Key: Any],
        highlighted: Bool = true
    ) {
        let base = NSMutableAttributedString(string: text, attributes: attributes)
        if highlighted {
            applyCodeHighlight(to: base, language: language ?? "")
        }

        let matches = referenceMatches(in: text)
        for match in matches {
            let id = register(.openAsset(match.reference))
            let url = URL(string: "agentkit-transcript://\(id)")!
            var linkAttributes: [NSAttributedString.Key: Any] = [
                .link: url,
                .foregroundColor: match.reference.kind == .url ? accentColor : pathColor
            ]
            if match.reference.kind == .url {
                linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            base.addAttributes(linkAttributes, range: match.range)
        }

        attributed.append(base)
    }

    private mutating func referenceMatches(in text: String) -> [(range: NSRange, reference: AssetReference)] {
        let annotationMatches = TextAnnotationReferenceDetector.matches(
            in: text,
            annotations: activeTextAnnotations,
            consumedKeys: &consumedTextAnnotationKeys,
            assetIndex: assetIndex
        )
        let fallbackMatches = AssetReferenceDetector.matches(in: text, assetIndex: assetIndex)
            .filter { candidate in
                !annotationMatches.contains {
                    NSIntersectionRange($0.range, candidate.range).length > 0
                }
            }
        return (annotationMatches + fallbackMatches).sorted(by: { (
            lhs: (range: NSRange, reference: AssetReference),
            rhs: (range: NSRange, reference: AssetReference)
        ) in
            lhs.range.location < rhs.range.location
        })
    }

    private func applyCodeHighlight(to text: NSMutableAttributedString, language: String) {
        let source = text.string
        guard !source.isEmpty else { return }

        let keywordPatterns: [String]
        switch language.lowercased() {
        case "swift":
            keywordPatterns = ["import", "struct", "class", "enum", "protocol", "extension",
                               "func", "var", "let", "guard", "if", "else", "switch", "case",
                               "for", "while", "return", "throw", "throws", "try", "catch",
                               "async", "await", "public", "private", "init", "nil", "true", "false"]
        case "json":
            keywordPatterns = ["true", "false", "null"]
        case "bash", "sh", "shell", "zsh":
            keywordPatterns = ["if", "then", "else", "fi", "for", "while", "do", "done",
                               "export", "local", "return", "exit", "echo", "cd", "cat", "grep"]
        case "python", "py":
            keywordPatterns = ["import", "from", "def", "class", "return", "if", "elif", "else",
                               "for", "while", "in", "with", "as", "try", "except", "None", "True", "False"]
        case "go":
            keywordPatterns = ["package", "import", "func", "type", "struct", "interface",
                               "var", "const", "return", "if", "else", "for", "range", "nil", "true", "false"]
        default:
            keywordPatterns = []
        }

        if !keywordPatterns.isEmpty {
            let pattern = "\\b(" + keywordPatterns.joined(separator: "|") + ")\\b"
            applyRegex(pattern, to: text, color: codeKeywordColor, bold: true)
        }
        applyRegex(#""[^"\n]*""#, to: text, color: codeStringColor)
        applyRegex(#"`[^`\n]*`"#, to: text, color: codeStringColor)
        applyRegex(#"//.*"#, to: text, color: codeCommentColor)
        applyRegex(#"#.*"#, to: text, color: codeCommentColor)
        applyRegex(#"\b\d+\.?\d*\b"#, to: text, color: codeNumberColor)
    }

    private func applyRegex(
        _ pattern: String,
        to text: NSMutableAttributedString,
        color: PlatformColor,
        bold: Bool = false
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: (text.string as NSString).length)
        for match in regex.matches(in: text.string, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
            if bold {
                text.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .semibold), range: match.range)
            }
        }
    }

    private mutating func register(_ action: TranscriptAction) -> String {
        let id = "a\(nextActionIndex)"
        nextActionIndex += 1
        actions[id] = action
        return id
    }

    /// Only external URLs keep an underline; local resources (paths,
    /// artifacts, tool rows) signal interactivity through color alone.
    private func attributes(for style: ActionStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .tool:
            return actionAttributes(base: bodyAttributes, color: accentColor, underlined: false)
        case .artifact:
            return actionAttributes(base: bodyAttributes, color: artifactColor, underlined: false)
        case .path:
            return actionAttributes(base: bodyAttributes, color: pathColor, underlined: false)
        }
    }

    private func actionAttributes(
        base: [NSAttributedString.Key: Any],
        color: PlatformColor,
        underlined: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attrs = base
        attrs[.foregroundColor] = color
        if underlined {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attrs.removeValue(forKey: .underlineStyle)
        }
        return attrs
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: bodyFontSize),
            .foregroundColor: quoteDepth > 0 ? TranscriptTheme.quoteText : primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: bodySpacingAfter)
        ]
    }

    private var headingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.boldSystemFont(ofSize: headingFontSize),
            .foregroundColor: secondaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2)
        ]
    }

    private func markdownHeadingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
        let size: CGFloat
        let spacingBefore: CGFloat
        switch level {
        case 1:
            size = markdownH1FontSize
            spacingBefore = 10
        case 2:
            size = markdownH2FontSize
            spacingBefore = 8
        default:
            size = markdownH3FontSize
            spacingBefore = 6
        }
        return [
            .font: PlatformFont.boldSystemFont(ofSize: size),
            .foregroundColor: primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 4, spacingBefore: spacingBefore)
        ]
    }

    private var metaAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: metaFontSize),
            .foregroundColor: tertiaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2)
        ]
    }

    private var systemErrorLabelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolTitleFontSize, weight: .semibold),
            .foregroundColor: failedColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2, blockInset: true)
        ]
    }

    private var systemErrorBodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: bodyFontSize, weight: .medium),
            .foregroundColor: failedColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2, blockInset: true)
        ]
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.boldSystemFont(ofSize: labelFontSize),
            .foregroundColor: secondaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var toolTargetAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: metaFontSize),
            .foregroundColor: secondaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var toolRailAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolDetailFontSize),
            .foregroundColor: tertiaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private func toolIconAttributes(
        for family: ToolTranscriptFamily,
        tone: ToolTranscriptStatusTone
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolIconFontSize, weight: .semibold),
            .foregroundColor: toolColor(for: family, tone: tone),
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private func toolTitleAttributes(
        for tone: ToolTranscriptStatusTone,
        nested: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: nested ? toolNestedFontSize : toolTitleFontSize, weight: .regular),
            .foregroundColor: tone == .failed ? failedColor : primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 1)
        ]
        if nested {
            attrs[.transcriptChip] = TranscriptChipValue(kind: .nestedTool)
        }
        return attrs
    }

    private func toolSummaryAttributes(
        for tone: ToolTranscriptStatusTone
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolTitleFontSize, weight: .regular),
            .foregroundColor: tone == .failed ? failedColor : secondaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 1)
        ]
    }

    private var toolDetailAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolDetailFontSize),
            .foregroundColor: tertiaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private func toolStatusTextAttributes(
        for tone: ToolTranscriptStatusTone
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolStatusFontSize, weight: .medium),
            .foregroundColor: statusColor(for: tone),
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var toolChevronAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolDetailFontSize, weight: .regular),
            .foregroundColor: tertiaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var toolDiffAddedAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolDetailFontSize, weight: .medium),
            .foregroundColor: diffAddedColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var toolDiffRemovedAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.systemFont(ofSize: toolDetailFontSize, weight: .medium),
            .foregroundColor: diffRemovedColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0)
        ]
    }

    private var codeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
            .foregroundColor: primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2, blockInset: true, charWrap: true)
        ]
    }

    private var codeLabelAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(ofSize: codeLabelFontSize, weight: .semibold),
            .foregroundColor: secondaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 0, blockInset: true, charWrap: true)
        ]
    }

    private var tableAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
            .foregroundColor: primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 2, blockInset: true, charWrap: true)
        ]
    }

    private var tableHeaderAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .semibold),
            .foregroundColor: primaryColor,
            .paragraphStyle: paragraphStyle(spacingAfter: 3, blockInset: true)
        ]
    }

    private var inlineCodeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(ofSize: inlineCodeFontSize, weight: .regular),
            .foregroundColor: TranscriptTheme.inlineCodeText,
            .transcriptChip: TranscriptChipValue(kind: .inlineCode)
        ]
    }

    private func diffAttributes(for line: String) -> [NSAttributedString.Key: Any] {
        var attrs = codeAttributes
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            attrs[.foregroundColor] = diffAddedColor
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
            attrs[.foregroundColor] = diffRemovedColor
        } else if line.hasPrefix("@@") {
            attrs[.foregroundColor] = diffHunkColor
        } else if line.hasPrefix("+++") || line.hasPrefix("---") {
            attrs[.foregroundColor] = secondaryColor
        }
        return attrs
    }

    private func boldFont(from font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private func italicFont(from font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    /// Central paragraph geometry. List depth adds a hanging indent so
    /// wrapped lines align under the item text; quote depth indents the
    /// whole run to make room for the drawn bar; `blockInset` pads decorated
    /// blocks (code/table/error) inside their full-width background.
    /// `charWrap` is for monospaced content (code, tables, diffs) where
    /// breaking anywhere beats overflowing; prose wraps at word boundaries.
    private func paragraphStyle(
        spacingAfter: CGFloat,
        spacingBefore: CGFloat = 0,
        blockInset: Bool = false,
        charWrap: Bool = false
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore

        var firstLineIndent: CGFloat = 0
        var wrapIndent: CGFloat = 0
        if listDepth > 0 {
            let base = CGFloat(listDepth - 1) * listHangIndent
            firstLineIndent += base
            wrapIndent += base + listHangIndent
        }
        if quoteDepth > 0 {
            firstLineIndent += quoteIndent
            wrapIndent += quoteIndent
        }
        if blockInset {
            firstLineIndent += blockHorizontalPadding
            wrapIndent += blockHorizontalPadding
            style.tailIndent = -blockHorizontalPadding
        }
        style.firstLineHeadIndent = firstLineIndent
        style.headIndent = wrapIndent
        style.lineBreakMode = charWrap ? .byCharWrapping : .byWordWrapping
        return style
    }

    private var listHangIndent: CGFloat {
        #if os(iOS)
        return 18
        #else
        return 14
        #endif
    }

    private var quoteIndent: CGFloat {
        #if os(iOS)
        return 12
        #else
        return 10
        #endif
    }

    private var blockHorizontalPadding: CGFloat {
        TranscriptTheme.blockHorizontalPadding
    }

    private var bodyFontSize: CGFloat {
        #if os(iOS)
        return 17
        #else
        return 14
        #endif
    }

    private var headingFontSize: CGFloat {
        #if os(iOS)
        return 15
        #else
        return 13
        #endif
    }

    private var metaFontSize: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 12
        #endif
    }

    private var labelFontSize: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 12
        #endif
    }

    private var toolTitleFontSize: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 14
        #endif
    }

    private var toolNestedFontSize: CGFloat {
        #if os(iOS)
        return 15
        #else
        return 13
        #endif
    }

    private var toolDetailFontSize: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 13
        #endif
    }

    private var toolStatusFontSize: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 12
        #endif
    }

    private var toolIconFontSize: CGFloat {
        #if os(iOS)
        return 15
        #else
        return 13
        #endif
    }

    private var codeFontSize: CGFloat {
        #if os(iOS)
        return 15
        #else
        return 12
        #endif
    }

    private var codeLabelFontSize: CGFloat {
        #if os(iOS)
        return 13
        #else
        return 11
        #endif
    }

    private var inlineCodeFontSize: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 13
        #endif
    }

    private var markdownH1FontSize: CGFloat {
        #if os(iOS)
        return 22
        #else
        return 20
        #endif
    }

    private var markdownH2FontSize: CGFloat {
        #if os(iOS)
        return 19
        #else
        return 17
        #endif
    }

    private var markdownH3FontSize: CGFloat {
        #if os(iOS)
        return 17
        #else
        return 15
        #endif
    }

    private var lineSpacing: CGFloat {
        #if os(iOS)
        return 4
        #else
        return 2
        #endif
    }

    private var bodySpacingAfter: CGFloat {
        #if os(iOS)
        return 4
        #else
        return 2
        #endif
    }

    // Colors delegate to TranscriptTheme — the single light/dark palette.

    private var primaryColor: PlatformColor { TranscriptTheme.primaryText }
    private var secondaryColor: PlatformColor { TranscriptTheme.secondaryText }
    private var tertiaryColor: PlatformColor { TranscriptTheme.tertiaryText }
    private var accentColor: PlatformColor { TranscriptTheme.urlLink }
    private var artifactColor: PlatformColor { TranscriptTheme.artifactLink }
    private var pathColor: PlatformColor { TranscriptTheme.pathLink }
    private var runningColor: PlatformColor { TranscriptTheme.running }
    private var failedColor: PlatformColor { TranscriptTheme.failed }

    private func toolIcon(
        for family: ToolTranscriptFamily,
        tone: ToolTranscriptStatusTone
    ) -> String {
        if tone == .failed { return "!" }
        if tone == .running {
            let frames = ["◐", "◓", "◑", "◒"]
            return frames[abs(animationFrame) % frames.count]
        }
        switch family {
        case .read: return "□"
        case .list: return "≡"
        case .search: return "⌕"
        case .create: return "+"
        case .edit: return "±"
        case .terminal: return "$"
        case .other: return "◇"
        }
    }

    private func toolColor(
        for family: ToolTranscriptFamily,
        tone: ToolTranscriptStatusTone
    ) -> PlatformColor {
        switch tone {
        case .running:
            return runningColor
        case .failed:
            return failedColor
        case .autoApproved:
            return artifactColor
        case .completed:
            switch family {
            case .read, .list:
                return secondaryColor
            case .search:
                return accentColor
            case .create, .edit:
                return diffAddedColor
            case .terminal:
                return runningColor
            case .other:
                return tertiaryColor
            }
        }
    }

    private func statusColor(for tone: ToolTranscriptStatusTone) -> PlatformColor {
        switch tone {
        case .completed:
            return tertiaryColor
        case .running:
            return runningColor
        case .failed:
            return failedColor
        case .autoApproved:
            return artifactColor
        }
    }

    private var codeKeywordColor: PlatformColor { TranscriptTheme.codeKeyword }
    private var codeStringColor: PlatformColor { TranscriptTheme.codeString }
    private var codeCommentColor: PlatformColor { TranscriptTheme.codeComment }
    private var codeNumberColor: PlatformColor { TranscriptTheme.codeNumber }
    private var diffAddedColor: PlatformColor { TranscriptTheme.diffAddedText }
    private var diffRemovedColor: PlatformColor { TranscriptTheme.diffRemovedText }
    private var diffHunkColor: PlatformColor { TranscriptTheme.diffHunkText }

    private func inlinePlainText(_ inlines: [InlineContent]) -> String {
        inlines.map(inlinePlainText).joined()
    }

    private func inlinePlainText(_ inline: InlineContent) -> String {
        switch inline {
        case .text(let text): return text
        case .strong(let children): return inlinePlainText(children)
        case .emphasis(let children): return inlinePlainText(children)
        case .strikethrough(let children): return inlinePlainText(children)
        case .inlineCode(let code): return code
        case .link(_, let text): return inlinePlainText(text)
        case .image(_, let altText): return altText
        case .softBreak: return " "
        case .lineBreak: return "\n"
        }
    }
}
