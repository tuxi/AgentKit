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

import SwiftUI

struct NativeTranscriptView: View {
    let transcript: AttributedTranscript
    let onAction: (TranscriptAction) -> Void

    #if os(macOS)
    @State private var measuredHeight: CGFloat = 1
    #endif

    var body: some View {
        #if os(macOS)
        GeometryReader { geometry in
            PlatformTranscriptTextView(
                attributedText: transcript.attributedString,
                actions: transcript.actions,
                width: max(1, geometry.size.width),
                measuredHeight: $measuredHeight,
                onAction: onAction
            )
        }
        .frame(height: measuredHeight)
        #else
        PlatformTranscriptTextView(
            attributedText: transcript.attributedString,
            actions: transcript.actions,
            onAction: onAction
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
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
    let width: CGFloat
    @Binding var measuredHeight: CGFloat
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

        if textView.textStorage?.isEqual(to: attributedText) != true {
            textView.textStorage?.setAttributedString(attributedText)
        }

        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame.size.width = width

        let newHeight = measuredTextHeight(textView)
        if abs(newHeight - measuredHeight) > 0.5 {
            DispatchQueue.main.async {
                measuredHeight = newHeight
            }
        }
    }

    private func measuredTextHeight(_ textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return 1
        }
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        return max(1, ceil(rect.height + textView.textContainerInset.height * 2))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions: [String: TranscriptAction] = [:]
        var onAction: (TranscriptAction) -> Void

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
        textView.textContainer.lineBreakMode = .byCharWrapping
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

        if textView.attributedText.isEqual(to: attributedText) != true {
            textView.attributedText = attributedText
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
