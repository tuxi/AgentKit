//
//  NativeTranscriptView.swift
//  AgentKit
//
//  Cross-platform read-only transcript view backed by native text selection.
//  Uses an explicit TextKit 1 stack so TranscriptLayoutManager can draw the
//  full-width block backgrounds (code, tables, diffs, errors) and inline
//  chips described by the builder's `.transcriptBlock` / `.transcriptChip`
//  attributes — glyph-run `.backgroundColor` can't produce those visuals.
//
//  Streaming updates are applied INCREMENTALLY: only the changed tail of the
//  text storage is replaced. That keeps the user's selection alive while
//  tokens stream in / tools run, and limits TextKit relayout to the tail
//  instead of the whole turn.
//

import SwiftUI

struct NativeTranscriptView: View {
    let transcript: AttributedTranscript
    let onAction: (TranscriptAction) -> Void

    var body: some View {
        PlatformTranscriptTextView(
            attributedText: transcript.attributedString,
            actions: transcript.actions,
            onAction: onAction
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Incremental text application

/// Applies a new attributed string to an NSTextStorage by replacing only the
/// suffix that actually changed (common-prefix diff in UTF-16 space).
/// Selection survives because platform text views keep selections that lie
/// before an edit, and adjust ones after it.
enum TranscriptTextApplier {

    enum Result {
        case noChange
        /// Only the tail was replaced — selection in the prefix survives.
        case incremental
        /// Characters were identical but attributes changed — full replace.
        /// Caller should restore the selection (string length is unchanged).
        case attributesOnly
    }

    static func apply(_ new: NSAttributedString, to storage: NSTextStorage) -> Result {
        let oldLength = storage.length
        let newLength = new.length
        let prefix = commonPrefixLength(storage.string as NSString, new.string as NSString)

        if prefix == oldLength && prefix == newLength {
            // Characters identical. Attribute-only changes (rare: e.g. a link
            // gains a target with the same visible text) need a full pass.
            if storage.isEqual(to: new) { return .noChange }
            storage.setAttributedString(new)
            return .attributesOnly
        }

        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: prefix, length: oldLength - prefix),
            with: new.attributedSubstring(
                from: NSRange(location: prefix, length: newLength - prefix)
            )
        )
        storage.endEditing()
        return .incremental
    }

    /// Longest common prefix of two strings in UTF-16 code units, backed off
    /// so it never splits a surrogate pair.
    private static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let n = min(a.length, b.length)
        guard n > 0 else { return 0 }

        var bufferA = [unichar](repeating: 0, count: n)
        var bufferB = [unichar](repeating: 0, count: n)
        a.getCharacters(&bufferA, range: NSRange(location: 0, length: n))
        b.getCharacters(&bufferB, range: NSRange(location: 0, length: n))

        var i = 0
        while i < n && bufferA[i] == bufferB[i] { i += 1 }
        if i > 0 && i < n && UTF16.isLeadSurrogate(bufferA[i - 1]) {
            i -= 1
        }
        return i
    }
}

// MARK: - Block decoration layout manager

/// Draws the transcript's block-level chrome behind the text:
/// - `.transcriptBlock` runs get a full-width rounded background
///   (code/table/error) or per-run stripes (diff lines) or a leading
///   vertical bar (blockquote).
/// - `.transcriptChip` runs get a snug rounded chip behind the glyphs
///   (inline code, nested tool titles).
/// Drawing happens before `super.drawBackground`, so selection highlights
/// still paint on top and text selection behavior is untouched.
final class TranscriptLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawBlockDecorations(at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawBlockDecorations(at origin: CGPoint) {
        guard let textStorage,
              let textContainer = textContainers.first,
              textStorage.length > 0 else {
            return
        }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerWidth = textContainer.size.width

        textStorage.enumerateAttribute(.transcriptBlock, in: fullRange) { value, range, _ in
            guard let block = value as? TranscriptBlockValue else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            var union = CGRect.null
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                union = union.union(rect)
            }
            guard !union.isNull else { return }

            if block.kind == .quote {
                let bar = CGRect(
                    x: origin.x + 1,
                    y: origin.y + union.minY,
                    width: 3,
                    height: union.height
                )
                Self.fill(bar, color: TranscriptTheme.quoteBar, radius: 1.5)
                return
            }

            if block.kind == .divider {
                let inset = TranscriptTheme.blockHorizontalPadding
                let line = CGRect(
                    x: origin.x + inset,
                    y: origin.y + union.midY - 0.5,
                    width: max(0, containerWidth - inset * 2),
                    height: 1
                )
                Self.fill(line, color: TranscriptTheme.hairline, radius: 0.5)
                return
            }

            guard let color = TranscriptTheme.blockFill(for: block.kind) else { return }
            var rect = CGRect(
                x: origin.x,
                y: origin.y + union.minY,
                width: containerWidth,
                height: union.height
            )
            // Standalone blocks get vertical breathing room; diff stripes
            // tile edge to edge so adjacent runs don't overlap.
            switch block.kind {
            case .code, .table, .error:
                rect = rect.insetBy(dx: 0, dy: -2)
            default:
                break
            }
            Self.fill(rect, color: color, radius: TranscriptTheme.blockCornerRadius(for: block.kind))
        }

        // Hairline under table header rows, inside the table background.
        textStorage.enumerateAttribute(.transcriptTableHeader, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var union = CGRect.null
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                union = union.union(rect)
            }
            guard !union.isNull else { return }
            let inset = TranscriptTheme.blockHorizontalPadding
            let line = CGRect(
                x: origin.x + inset,
                y: origin.y + union.maxY - 2,
                width: max(0, containerWidth - inset * 2),
                height: 1
            )
            Self.fill(line, color: TranscriptTheme.hairline, radius: 0.5)
        }

        textStorage.enumerateAttribute(.transcriptChip, in: fullRange) { value, range, _ in
            guard let chip = value as? TranscriptChipValue else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let color = TranscriptTheme.chipFill(for: chip.kind)

            self.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, container, lineGlyphRange, _ in
                let intersection = NSIntersectionRange(lineGlyphRange, glyphRange)
                guard intersection.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: intersection, in: container)
                rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
                Self.fill(rect, color: color, radius: 4)
            }
        }
    }

    private static func fill(_ rect: CGRect, color: TranscriptPlatformColor, radius: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        color.setFill()
        #if os(macOS)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        #else
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        #endif
    }
}

#if os(macOS)
import AppKit

private struct PlatformTranscriptTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let actions: [String: TranscriptAction]
    let onAction: (TranscriptAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = TranscriptLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [:]
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onAction = onAction

        // Fast path: unchanged transcript instance (cache hit upstream).
        guard context.coordinator.lastApplied !== attributedText else { return }
        context.coordinator.lastApplied = attributedText

        guard let storage = textView.textStorage else { return }
        let savedSelection = textView.selectedRanges
        if TranscriptTextApplier.apply(attributedText, to: storage) == .attributesOnly {
            // Same characters, new attributes — the full replace dropped the
            // selection, but every saved range is still valid. Put it back.
            textView.selectedRanges = savedSelection
        }
    }

    /// Synchronous self-sizing — replaces the old GeometryReader +
    /// measuredHeight @State round-trip, which forced a second layout pass
    /// (and a visible stutter) on every streaming update.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }
        let width = max(1, proposedWidth)
        if textContainer.containerSize.width != width {
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(1, ceil(used.height + textView.textContainerInset.height * 2))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions: [String: TranscriptAction] = [:]
        var onAction: (TranscriptAction) -> Void
        /// Identity of the last applied transcript — skips diffing entirely
        /// when the upstream cache hands back the same instance.
        var lastApplied: NSAttributedString?

        init(onAction: @escaping (TranscriptAction) -> Void) {
            self.onAction = onAction
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard let url = link as? URL,
                  url.scheme == "agentkit-transcript",
                  let id = url.host,
                  let action = actions[id] else {
                return false
            }
            onAction(action)
            return true
        }
    }
}

#else
import UIKit

private struct PlatformTranscriptTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let actions: [String: TranscriptAction]
    let onAction: (TranscriptAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeUIView(context: Context) -> UITextView {
        let textStorage = NSTextStorage()
        let layoutManager = TranscriptLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        // Wrapping is per-paragraph: prose wraps at word boundaries, code
        // and tables wrap by character (see TranscriptAttributedBuilder).
        textView.adjustsFontForContentSizeCategory = false
        textView.linkTextAttributes = [:]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onAction = onAction

        // Fast path: unchanged transcript instance (cache hit upstream).
        guard context.coordinator.lastApplied !== attributedText else { return }
        context.coordinator.lastApplied = attributedText

        let savedSelection = textView.selectedRange
        if TranscriptTextApplier.apply(attributedText, to: textView.textStorage) == .attributesOnly {
            textView.selectedRange = savedSelection
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = max(1, proposal.width ?? UIScreen.main.bounds.width)
        textView.bounds.size.width = width
        textView.textContainer.size = CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let fitting = textView.sizeThatFits(CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        return CGSize(width: width, height: max(1, ceil(fitting.height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var actions: [String: TranscriptAction] = [:]
        var onAction: (TranscriptAction) -> Void
        /// Identity of the last applied transcript — skips diffing entirely
        /// when the upstream cache hands back the same instance.
        var lastApplied: NSAttributedString?

        init(onAction: @escaping (TranscriptAction) -> Void) {
            self.onAction = onAction
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard URL.scheme == "agentkit-transcript",
                  let id = URL.host,
                  let action = actions[id] else {
                return true
            }
            onAction(action)
            return false
        }
    }
}
#endif
