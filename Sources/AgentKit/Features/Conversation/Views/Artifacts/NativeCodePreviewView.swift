//
//  NativeCodePreviewView.swift
//  AgentKit
//
//  Lightweight read-only code preview. The macOS path uses the native text
//  system (NSTextView inside NSScrollView with a line-number ruler), keeping
//  selection/copy/scrolling in AppKit instead of rebuilding an editor in
//  SwiftUI rows.
//

import SwiftUI

#if os(macOS)
import AppKit

struct NativeCodePreviewView: NSViewRepresentable {
    let filePath: String
    let content: String
    let language: String?
    let focusLine: Int?
    let focusID: String?
    let focusRevision: Int
    let searchQuery: String
    let searchRevision: Int
    let searchDirection: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = CodePreviewLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: CodePreviewMetrics.defaultContainerSize)
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

        let scrollView = CodePreviewScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodePreviewTheme.background
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = textView

        let rulerView = CodeLineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.attach(
            textView: textView,
            layoutManager: layoutManager,
            rulerView: rulerView
        )
        scrollView.onLayout = { [weak coordinator = context.coordinator, weak scrollView] in
            guard let scrollView else { return }
            coordinator?.updateDocumentWidth(in: scrollView)
        }
        context.coordinator.observeScroll(in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = CodePreviewTheme.background
        context.coordinator.update(
            filePath: filePath,
            content: content,
            language: language,
            focusLine: focusLine,
            focusID: focusID,
            focusRevision: focusRevision,
            searchQuery: searchQuery,
            searchRevision: searchRevision,
            searchDirection: searchDirection,
            in: scrollView
        )
    }

    @MainActor final class Coordinator {
        weak var textView: NSTextView?
        private weak var layoutManager: CodePreviewLayoutManager?
        private weak var rulerView: CodeLineNumberRulerView?

        private var lastContent: String?
        private var lastLanguageKey: String?
        private var lastFocusToken: String?
        private var lastSearchQuery = ""
        private var lastSearchRevision = 0
        private var searchRanges: [NSRange] = []
        private var activeSearchIndex: Int?
        private var measuredContentWidth: CGFloat = 0
        private var lineMap = CodeLineMap("")

        fileprivate func attach(
            textView: NSTextView,
            layoutManager: CodePreviewLayoutManager,
            rulerView: CodeLineNumberRulerView
        ) {
            self.textView = textView
            self.layoutManager = layoutManager
            self.rulerView = rulerView
        }

        func observeScroll(in scrollView: NSScrollView) {
            scrollView.verticalRulerView?.needsDisplay = true
        }

        func update(
            filePath: String,
            content: String,
            language: String?,
            focusLine: Int?,
            focusID: String?,
            focusRevision: Int,
            searchQuery: String,
            searchRevision: Int,
            searchDirection: Int,
            in scrollView: NSScrollView
        ) {
            guard let textView else { return }
            let languageKey = CodeLanguage.infer(language: language, filePath: filePath)
            let contentChanged = lastContent != content || lastLanguageKey != languageKey

            if contentChanged {
                lineMap = CodeLineMap(content)
                measuredContentWidth = CodePreviewMetrics.measuredContentWidth(for: content)
                let attributed = NativeCodeHighlighter.highlight(
                    content,
                    language: languageKey,
                    fontSize: CodePreviewTheme.fontSize
                )
                textView.textStorage?.setAttributedString(attributed)
                textView.typingAttributes = [
                    .font: CodePreviewTheme.font,
                    .foregroundColor: CodePreviewTheme.primaryText
                ]
                rulerView?.lineMap = lineMap
                rulerView?.needsDisplay = true
                lastContent = content
                lastLanguageKey = languageKey
            }

            updateDocumentWidth(in: scrollView)

            let focusRange = focusLine.flatMap { lineMap.lineRange(for: $0) }
            layoutManager?.focusCharacterRange = focusRange
            rulerView?.focusLine = focusLine

            let focusToken = "\(focusID ?? filePath):\(focusLine ?? 0):\(focusRevision):\(content.count)"
            if contentChanged || focusToken != lastFocusToken {
                lastFocusToken = focusToken
                scrollToFocusLine(focusRange, in: scrollView)
            }

            updateSearch(
                query: searchQuery,
                revision: searchRevision,
                direction: searchDirection,
                contentChanged: contentChanged,
                in: scrollView
            )
        }

        func updateDocumentWidth(in scrollView: NSScrollView) {
            guard let textView,
                  let textContainer = textView.textContainer
            else { return }

            let viewportWidth = scrollView.contentView.bounds.width
            let rulerWidth = scrollView.verticalRulerView?.requiredThickness ?? 0
            let usableViewport = max(0, viewportWidth - rulerWidth)
            let contentWidth = CodePreviewMetrics.documentWidth(
                measuredContentWidth: measuredContentWidth,
                visibleWidth: usableViewport,
                inset: textView.textContainerInset.width
            )

            guard abs(textView.frame.width - contentWidth) > 0.5 else { return }

            let oldVisibleOrigin = scrollView.contentView.bounds.origin
            textView.frame.size.width = contentWidth
            textView.minSize = NSSize(width: usableViewport, height: 0)
            textContainer.containerSize = NSSize(
                width: max(1, contentWidth - textView.textContainerInset.width * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager?.ensureLayout(for: textContainer)
            scrollView.contentView.scroll(to: oldVisibleOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.verticalRulerView?.needsDisplay = true
        }

        private func scrollToFocusLine(_ focusRange: NSRange?, in scrollView: NSScrollView) {
            guard let textView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager,
                  let focusRange,
                  focusRange.location != NSNotFound
            else { return }

            DispatchQueue.main.async {
                layoutManager.ensureLayout(for: textContainer)
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: focusRange,
                    actualCharacterRange: nil
                )
                guard glyphRange.location != NSNotFound else { return }
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect = rect.offsetBy(
                    dx: textView.textContainerOrigin.x,
                    dy: textView.textContainerOrigin.y
                )
                rect = rect.insetBy(dx: -12, dy: -80)
                textView.scrollToVisible(rect)
                scrollView.verticalRulerView?.needsDisplay = true
            }
        }

        private func updateSearch(
            query: String,
            revision: Int,
            direction: Int,
            contentChanged: Bool,
            in scrollView: NSScrollView
        ) {
            guard let textView else { return }
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryChanged = normalizedQuery != lastSearchQuery
            let revisionChanged = revision != lastSearchRevision

            if normalizedQuery.isEmpty {
                lastSearchQuery = normalizedQuery
                lastSearchRevision = revision
                searchRanges = []
                activeSearchIndex = nil
                layoutManager?.searchRanges = []
                layoutManager?.activeSearchRange = nil
                return
            }

            if queryChanged || contentChanged {
                searchRanges = CodePreviewSearch.ranges(in: textView.string, query: normalizedQuery)
                activeSearchIndex = searchRanges.isEmpty ? nil : 0
                lastSearchQuery = normalizedQuery
            } else if revisionChanged, !searchRanges.isEmpty {
                let current = activeSearchIndex ?? (direction >= 0 ? -1 : 0)
                let next = (current + (direction >= 0 ? 1 : -1) + searchRanges.count) % searchRanges.count
                activeSearchIndex = next
            }

            lastSearchRevision = revision
            layoutManager?.searchRanges = searchRanges
            let activeRange = activeSearchIndex.flatMap { searchRanges.indices.contains($0) ? searchRanges[$0] : nil }
            layoutManager?.activeSearchRange = activeRange

            guard queryChanged || revisionChanged || contentChanged,
                  let activeRange
            else { return }

            textView.setSelectedRange(activeRange)
            scrollToRange(activeRange, in: scrollView, verticalPadding: 70)
        }

        private func scrollToRange(_ range: NSRange, in scrollView: NSScrollView, verticalPadding: CGFloat) {
            guard let textView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else { return }

            DispatchQueue.main.async {
                layoutManager.ensureLayout(for: textContainer)
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                guard glyphRange.location != NSNotFound else { return }
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect = rect.offsetBy(
                    dx: textView.textContainerOrigin.x,
                    dy: textView.textContainerOrigin.y
                )
                rect = rect.insetBy(dx: -30, dy: -verticalPadding)
                textView.scrollToVisible(rect)
                scrollView.verticalRulerView?.needsDisplay = true
            }
        }
    }
}

private final class CodePreviewScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class CodePreviewLayoutManager: NSLayoutManager {
    var focusCharacterRange: NSRange? {
        didSet {
            if let oldValue {
                invalidateDisplay(forCharacterRange: oldValue)
            }
            if let focusCharacterRange {
                invalidateDisplay(forCharacterRange: focusCharacterRange)
            }
        }
    }
    var searchRanges: [NSRange] = [] {
        didSet { invalidateSearchDisplay(oldValue + searchRanges) }
    }
    var activeSearchRange: NSRange? {
        didSet { invalidateSearchDisplay([oldValue, activeSearchRange].compactMap(\.self)) }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawFocusedLine(in: glyphsToShow, at: origin)
        drawSearchHighlights(in: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func invalidateSearchDisplay(_ ranges: [NSRange]) {
        for range in ranges where range.location != NSNotFound && range.length > 0 {
            invalidateDisplay(forCharacterRange: range)
        }
    }

    private func drawFocusedLine(in glyphsToShow: NSRange, at origin: CGPoint) {
        guard let focusCharacterRange,
              let textContainer = textContainers.first
        else { return }

        let focusGlyphRange = glyphRange(
            forCharacterRange: focusCharacterRange,
            actualCharacterRange: nil
        )
        guard NSIntersectionRange(focusGlyphRange, glyphsToShow).length > 0 else { return }

        CodePreviewTheme.focusLineBackground.setFill()
        enumerateLineFragments(forGlyphRange: focusGlyphRange) { rect, _, _, _, _ in
            let fillRect = CGRect(
                x: origin.x,
                y: origin.y + rect.minY,
                width: max(textContainer.size.width, rect.width),
                height: rect.height
            )
            NSBezierPath(rect: fillRect).fill()
        }
    }

    private func drawSearchHighlights(in glyphsToShow: NSRange, at origin: CGPoint) {
        guard !textContainers.isEmpty else { return }
        for range in searchRanges {
            let glyphRange = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0,
                  NSIntersectionRange(glyphRange, glyphsToShow).length > 0
            else { continue }

            let isActive = activeSearchRange == range
            (isActive ? CodePreviewTheme.activeSearchBackground : CodePreviewTheme.searchBackground).setFill()
            enumerateLineFragments(forGlyphRange: glyphRange) { _, _, container, lineGlyphRange, _ in
                let intersection = NSIntersectionRange(lineGlyphRange, glyphRange)
                guard intersection.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: intersection, in: container)
                rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}

private final class CodeLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var lineMap = CodeLineMap("") {
        didSet { ruleThickness = requiredThickness }
    }
    var focusLine: Int? {
        didSet { needsDisplay = true }
    }

    private let regularFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let focusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = requiredThickness
        reservedThicknessForMarkers = 0
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat {
        let digits = max(3, String(max(1, lineMap.lineCount)).count)
        return CGFloat(digits) * 7 + 18
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        CodePreviewTheme.gutterBackground.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let textOrigin = textView.textContainerOrigin

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            guard lineGlyphRange.length > 0 else { return }
            let characterIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let lineNumber = self.lineMap.lineNumber(containing: characterIndex)
            let isFocused = lineNumber == self.focusLine
            let font = isFocused ? self.focusFont : self.regularFont
            let color = isFocused ? CodePreviewTheme.gutterFocusText : CodePreviewTheme.gutterText
            let string = "\(lineNumber)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let size = string.size(withAttributes: attributes)
            let y = textOrigin.y + lineRect.minY - visibleRect.minY + max(0, (lineRect.height - size.height) / 2)
            let point = NSPoint(x: self.bounds.width - size.width - 8, y: y)
            string.draw(at: point, withAttributes: attributes)
        }
    }
}

enum CodePreviewSearch {
    static func matchCount(in content: String, query: String) -> Int {
        ranges(in: content, query: query).count
    }

    static func ranges(in content: String, query: String) -> [NSRange] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }
        guard content.utf8.count <= CodePreviewLimits.searchableBytes else { return [] }

        let source = content as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var ranges: [NSRange] = []
        var searchRange = fullRange

        while searchRange.length > 0 {
            let found = source.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)

            let nextLocation = found.location + found.length
            guard nextLocation < source.length else { break }
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }

        return ranges
    }
}

private enum CodePreviewMetrics {
    static let defaultContainerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    private static let horizontalPadding: CGFloat = 28
    private static let maximumMeasuredLineCount = 10_000
    private static let maximumDocumentWidth: CGFloat = 20_000

    static func measuredContentWidth(for content: String) -> CGFloat {
        var widest: CGFloat = 0
        var processed = 0
        content.enumerateLines { line, stop in
            widest = max(widest, measuredLineWidth(line))
            processed += 1
            if processed >= maximumMeasuredLineCount {
                stop = true
            }
        }
        if content.isEmpty {
            widest = measuredLineWidth("")
        }
        return min(maximumDocumentWidth, ceil(widest + horizontalPadding))
    }

    static func documentWidth(
        measuredContentWidth: CGFloat,
        visibleWidth: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        let visibleFloor = max(1, visibleWidth)
        let contentTarget = measuredContentWidth + inset * 2
        return min(maximumDocumentWidth, max(visibleFloor, contentTarget))
    }

    private static func measuredLineWidth(_ line: String) -> CGFloat {
        (line as NSString).size(withAttributes: [.font: CodePreviewTheme.font]).width
    }
}

private enum CodePreviewLimits {
    static let highlightBytes = 512_000
    static let searchableBytes = 768_000
}

private struct CodeLineMap {
    private let text: NSString
    private let lineStarts: [Int]

    init(_ content: String) {
        text = content as NSString
        var starts = [0]
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            guard next > location else { break }
            if next < text.length {
                starts.append(next)
            }
            location = next
        }
        lineStarts = starts
    }

    var lineCount: Int { max(1, lineStarts.count) }

    func lineRange(for line: Int) -> NSRange? {
        guard line > 0, line <= lineStarts.count else { return nil }
        let location = lineStarts[line - 1]
        return text.lineRange(for: NSRange(location: location, length: 0))
    }

    func lineNumber(containing characterIndex: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= characterIndex {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return max(1, high + 1)
    }
}

private enum CodeLanguage {
    static func infer(language: String?, filePath: String) -> String {
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SyntaxHighlighter.inferLanguage(from: language)
        }
        let ext = (filePath as NSString).pathExtension
        return SyntaxHighlighter.inferLanguage(from: ext)
    }
}

private enum NativeCodeHighlighter {
    static func highlight(_ code: String, language: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.lineBreakMode = .byClipping

        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: CodePreviewTheme.font,
                .foregroundColor: CodePreviewTheme.primaryText,
                .paragraphStyle: paragraph
            ]
        )

        guard code.utf8.count <= CodePreviewLimits.highlightBytes else {
            return attributed
        }

        let protectedRanges = applyProtectedTokens(to: attributed, in: code, language: language)
        applyRules(rules(for: language), to: attributed, in: code, fontSize: fontSize, excluding: protectedRanges)
        return attributed
    }

    private static func rules(for language: String) -> [HighlightRule] {
        switch language {
        case "swift":
            return [
                .keywords(swiftKeywords, CodePreviewTheme.keyword),
                .regex(#"@[A-Za-z_][A-Za-z0-9_]*"#, CodePreviewTheme.attribute, false),
                .regex(#"\b[A-Z][A-Za-z0-9_]*(?=\s*[:<\(])"#, CodePreviewTheme.typeName, false),
                .regex(#"(?<=func\s)[A-Za-z_][A-Za-z0-9_]*"#, CodePreviewTheme.symbol, false),
                .number
            ]
        case "python":
            return [
                .keywords(pythonKeywords, CodePreviewTheme.keyword),
                .regex(#"@[A-Za-z_][A-Za-z0-9_\.]*"#, CodePreviewTheme.attribute, false),
                .regex(#"(?<=def\s)[A-Za-z_][A-Za-z0-9_]*"#, CodePreviewTheme.symbol, false),
                .number
            ]
        case "bash":
            return [
                .keywords(bashKeywords, CodePreviewTheme.keyword),
                .regex(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, CodePreviewTheme.typeName, false),
                .number
            ]
        case "json", "yaml":
            return [
                .regex(#""(?:\\.|[^"\\])*"\s*:"#, CodePreviewTheme.typeName, false, allowProtectedOverlap: true),
                .regex(#"^\s*[A-Za-z_][A-Za-z0-9_-]*(?=\s*:)"#, CodePreviewTheme.typeName, false, [.anchorsMatchLines]),
                .keywords(["true", "false", "null", "yes", "no"], CodePreviewTheme.number),
                .number
            ]
        case "javascript", "typescript":
            return [
                .keywords(jsKeywords, CodePreviewTheme.keyword),
                .regex(#"\b[A-Z][A-Za-z0-9_]*(?=\s*[<\(:])"#, CodePreviewTheme.typeName, false),
                .regex(#"(?<=function\s)[A-Za-z_][A-Za-z0-9_]*"#, CodePreviewTheme.symbol, false),
                .number
            ]
        case "go":
            return [
                .keywords(goKeywords, CodePreviewTheme.keyword),
                .regex(#"(?<=func\s)[A-Za-z_][A-Za-z0-9_]*"#, CodePreviewTheme.symbol, false),
                .regex(#"\b[A-Z][A-Za-z0-9_]*(?=\s*(?:\{|interface|struct|\())"#, CodePreviewTheme.typeName, false),
                .number
            ]
        default:
            return [
                .keywords(genericKeywords, CodePreviewTheme.keyword),
                .number
            ]
        }
    }

    private static func applyProtectedTokens(
        to attributed: NSMutableAttributedString,
        in source: String,
        language: String
    ) -> [NSRange] {
        let stringRanges = applyProtectedRule(
            .regex(#""(?:\\.|[^"\\])*""#, CodePreviewTheme.string, false),
            to: attributed,
            in: source
        ) + applyProtectedRule(
            .regex(#"'(?:\\.|[^'\\])*'"#, CodePreviewTheme.string, false),
            to: attributed,
            in: source
        ) + applyProtectedRule(
            .regex(#"`(?:\\.|[^`\\])*`"#, CodePreviewTheme.string, false),
            to: attributed,
            in: source
        )

        let commentRanges = applyProtectedRule(
            .regex(#"/\*[\s\S]*?\*/"#, CodePreviewTheme.comment, false),
            to: attributed,
            in: source,
            excluding: stringRanges
        ) + applyProtectedRule(
            .regex(#"//.*$"#, CodePreviewTheme.comment, false, [.anchorsMatchLines]),
            to: attributed,
            in: source,
            excluding: stringRanges
        ) + hashCommentRanges(
            language: language,
            attributed: attributed,
            source: source,
            excluding: stringRanges
        )

        return stringRanges + commentRanges
    }

    private static func hashCommentRanges(
        language: String,
        attributed: NSMutableAttributedString,
        source: String,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        guard ["python", "bash", "yaml"].contains(language) else { return [] }
        return applyProtectedRule(
            .regex(#"#.*$"#, CodePreviewTheme.comment, false, [.anchorsMatchLines]),
            to: attributed,
            in: source,
            excluding: excludedRanges
        )
    }

    private static func applyProtectedRule(
        _ rule: HighlightRule,
        to attributed: NSMutableAttributedString,
        in source: String,
        excluding excludedRanges: [NSRange] = []
    ) -> [NSRange] {
        let matches = rule.matches(in: source)
            .map(\.range)
            .filter { !intersects($0, excludedRanges) }
        for range in matches {
            applyAttributes(rule, to: attributed, range: range, fontSize: CodePreviewTheme.fontSize)
        }
        return matches
    }

    private static func applyRules(
        _ rules: [HighlightRule],
        to attributed: NSMutableAttributedString,
        in source: String,
        fontSize: CGFloat,
        excluding excludedRanges: [NSRange]
    ) {
        for rule in rules {
            for match in rule.matches(in: source)
                where rule.allowProtectedOverlap || !intersects(match.range, excludedRanges) {
                applyAttributes(rule, to: attributed, range: match.range, fontSize: fontSize)
            }
        }
    }

    private static func applyAttributes(
        _ rule: HighlightRule,
        to attributed: NSMutableAttributedString,
        range: NSRange,
        fontSize: CGFloat
    ) {
        attributed.addAttribute(.foregroundColor, value: rule.color, range: range)
        if rule.bold {
            attributed.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                range: range
            )
        }
    }

    private static func intersects(_ range: NSRange, _ excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}

private struct HighlightRule {
    let pattern: String
    let color: NSColor
    let bold: Bool
    let options: NSRegularExpression.Options
    let allowProtectedOverlap: Bool

    static var number: HighlightRule {
        .regex(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, CodePreviewTheme.number, false)
    }

    static func regex(
        _ pattern: String,
        _ color: NSColor,
        _ bold: Bool,
        _ options: NSRegularExpression.Options = [],
        allowProtectedOverlap: Bool = false
    ) -> HighlightRule {
        HighlightRule(
            pattern: pattern,
            color: color,
            bold: bold,
            options: options,
            allowProtectedOverlap: allowProtectedOverlap
        )
    }

    static func keywords(_ words: [String], _ color: NSColor) -> HighlightRule {
        regex("\\b(" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b", color, true)
    }

    func matches(in source: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range)
    }
}

private let swiftKeywords = [
    "import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let",
    "mutating", "nonmutating", "public", "private", "internal", "fileprivate", "open",
    "static", "final", "override", "required", "convenience", "init", "deinit", "self",
    "super", "guard", "if", "else", "switch", "case", "default", "for", "while", "repeat",
    "return", "throw", "throws", "try", "catch", "do", "where", "async", "await", "actor",
    "nonisolated", "isolated", "some", "any", "true", "false", "nil", "associatedtype",
    "typealias", "get", "set", "willSet", "didSet", "weak", "unowned"
]

private let pythonKeywords = [
    "import", "from", "def", "class", "return", "if", "elif", "else", "for", "while",
    "in", "with", "as", "try", "except", "finally", "raise", "yield", "lambda", "pass",
    "break", "continue", "and", "or", "not", "is", "None", "True", "False", "async",
    "await", "self"
]

private let bashKeywords = [
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
    "function", "return", "exit", "export", "local", "source", "echo", "cd", "grep",
    "sed", "awk", "cat"
]

private let jsKeywords = [
    "import", "export", "from", "const", "let", "var", "function", "class", "extends",
    "return", "if", "else", "for", "while", "switch", "case", "break", "continue",
    "new", "this", "super", "try", "catch", "finally", "throw", "async", "await",
    "true", "false", "null", "undefined", "typeof", "instanceof", "interface", "type",
    "enum", "implements"
]

private let goKeywords = [
    "package", "import", "func", "type", "struct", "interface", "var", "const", "return",
    "if", "else", "for", "range", "switch", "case", "default", "break", "continue",
    "go", "defer", "chan", "select", "map", "make", "append", "len", "nil", "true",
    "false", "error", "string", "int", "bool"
]

private let genericKeywords = [
    "function", "return", "if", "else", "for", "while", "var", "let", "const", "class",
    "import", "export", "true", "false", "null", "nil"
]

private enum CodePreviewTheme {
    static let fontSize: CGFloat = 12
    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    static var background: NSColor {
        dynamic(
            light: NSColor(red: 0.965, green: 0.955, blue: 0.930, alpha: 1),
            dark: NSColor(red: 0.135, green: 0.135, blue: 0.125, alpha: 1)
        )
    }

    static var gutterBackground: NSColor {
        dynamic(
            light: NSColor(red: 0.930, green: 0.918, blue: 0.890, alpha: 1),
            dark: NSColor(red: 0.105, green: 0.105, blue: 0.098, alpha: 1)
        )
    }

    static var focusLineBackground: NSColor {
        dynamic(
            light: NSColor.controlAccentColor.withAlphaComponent(0.12),
            dark: NSColor.controlAccentColor.withAlphaComponent(0.18)
        )
    }

    static var searchBackground: NSColor {
        dynamic(
            light: NSColor.systemYellow.withAlphaComponent(0.32),
            dark: NSColor.systemYellow.withAlphaComponent(0.22)
        )
    }

    static var activeSearchBackground: NSColor {
        dynamic(
            light: NSColor.systemOrange.withAlphaComponent(0.42),
            dark: NSColor.systemOrange.withAlphaComponent(0.34)
        )
    }

    static var primaryText: NSColor { TranscriptTheme.primaryText }
    static var gutterText: NSColor { TranscriptTheme.tertiaryText }
    static var gutterFocusText: NSColor { TranscriptTheme.primaryText }
    static var keyword: NSColor { TranscriptTheme.codeKeyword }
    static var string: NSColor { TranscriptTheme.codeString }
    static var comment: NSColor { TranscriptTheme.codeComment }
    static var number: NSColor { TranscriptTheme.codeNumber }
    static var typeName: NSColor { TranscriptTheme.pathLink }
    static var symbol: NSColor { TranscriptTheme.artifactLink }
    static var attribute: NSColor { TranscriptTheme.running }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
#endif
