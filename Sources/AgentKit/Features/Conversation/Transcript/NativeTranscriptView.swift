//
//  NativeTranscriptView.swift
//  AgentKit
//
//  Cross-platform read-only transcript view backed by native text selection.
//

import SwiftUI

struct NativeTranscriptView: View {
    let transcript: AttributedTranscript
    let onAction: (TranscriptAction) -> Void

    @State private var measuredHeight: CGFloat = 1

    var body: some View {
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
        let textView = NSTextView()
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
    let width: CGFloat
    @Binding var measuredHeight: CGFloat
    let onAction: (TranscriptAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.linkTextAttributes = [:]
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onAction = onAction

        if textView.attributedText.isEqual(to: attributedText) != true {
            textView.attributedText = attributedText
        }

        let fitting = textView.sizeThatFits(CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        let newHeight = max(1, ceil(fitting.height))
        if abs(newHeight - measuredHeight) > 0.5 {
            DispatchQueue.main.async {
                measuredHeight = newHeight
            }
        }
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
