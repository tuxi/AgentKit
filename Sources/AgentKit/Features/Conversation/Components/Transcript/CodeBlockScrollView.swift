//
//  CodeBlockScrollView.swift
//  AgentKit
//
//  iOS-only UIKit-wrapped code block with proper horizontal scrolling.
//  Uses UIScrollView + UITextView to avoid the gesture-conflict issues
//  that plague SwiftUI ScrollView when nested inside a vertical ScrollView
//  (the conversation timeline). directionalLockEnabled prevents horizontal
//  pans from leaking into the parent scroll view.
//

#if os(iOS)
import SwiftUI
import UIKit

/// A code block that scrolls horizontally without stealing gestures
/// from the parent vertical conversation scroll view.
struct CodeBlockScrollView: UIViewRepresentable {
    let code: AttributedString
    let language: String
    var onCopy: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.backgroundColor = .clear

        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = scrollView.subviews.first as? UITextView else { return }
        textView.attributedText = NSAttributedString(code)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView scrollView: UIScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = scrollView.subviews.first as? UITextView else {
            return CGSize(width: 200, height: 44)
        }

        let width = max(1, (proposal.width ?? UIScreen.main.bounds.width).rounded())
        // Measure the text height at this container width,
        // then cap at a reasonable maximum.
        let textSize = textView.sizeThatFits(CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        let height = min(max(44, ceil(textSize.height)), 600)
        return CGSize(width: width, height: height)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        // Reserved for future delegate needs (e.g. link taps).
    }
}
#endif
