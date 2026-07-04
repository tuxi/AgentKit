//
//  MacComposerTextView.swift
//  AgentKit
//
//  macOS 聊天输入框（对标 Claude Code / Cursor 的主流交互）：
//    - 回车发送，Shift+回车换行
//    - 尊重输入法（IME）：中文候选词 / 英文联想词的回车只提交候选，不发消息
//      —— 因为 doCommandBy(insertNewline:) 仅在 IME 组字结束后才被调用
//    - 内容高度自适应，超过 maxHeight 后内部滚动（不再贪婪占满最大高度）
//
//  仅 macOS 使用；iOS 侧沿用 SwiftUI TextField(axis:.vertical)。
//

#if os(macOS)

import AppKit
import SwiftUI

struct MacComposerTextView: NSViewRepresentable {

    @Binding var text: String
    /// 自适应后的目标高度（由内容测量得出，clamp 到 [minHeight, maxHeight]）。
    @Binding var height: CGFloat

    let placeholder: String
    let isEnabled: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// 回车发送。是否满足发送条件由调用方在闭包内判断。
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.autoresizingMask = [.width]
        textView.placeholderString = placeholder
        textView.onSend = onSend

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // 首帧测量一次高度。
        let coordinator = context.coordinator
        Task { @MainActor in coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }

        if textView.string != text {
            textView.string = text
        }
        textView.placeholderString = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSend = onSend
        context.coordinator.recalculateHeight()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: MacComposerTextView
        weak var textView: ComposerNSTextView?

        init(_ parent: MacComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalculateHeight()
        }

        /// 基于 layoutManager 的实际排版高度做自适应，clamp 到 [min, max]。
        func recalculateHeight() {
            guard let tv = textView,
                  let layoutManager = tv.layoutManager,
                  let container = tv.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = tv.textContainerInset.height * 2
            let target = min(max(used + inset, parent.minHeight), parent.maxHeight)
            if abs(parent.height - target) > 0.5 {
                let newHeight = target
                // 延后一拍，避免在 SwiftUI 视图更新周期内直接改 @Binding。
                Task { @MainActor [weak self] in
                    self?.parent.height = newHeight
                }
            }
        }

        /// 回车 / Shift+回车 / 输入法处理的核心。
        /// 注意：IME 组字期间，回车用于选定候选词，input context 会消化该事件，
        /// 根本不会走到这里 —— 因此中文/联想输入永远不会误发。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftHeld {
                    textView.insertNewline(nil)   // 真正换行
                } else {
                    parent.onSend()               // 发送
                }
                return true
            }
            return false
        }
    }
}

// MARK: - ComposerNSTextView

/// 带占位符绘制的 NSTextView（NSTextView 本身无 placeholder）。
final class ComposerNSTextView: NSTextView {

    var placeholderString: String = "" {
        didSet { if string.isEmpty { needsDisplay = true } }
    }
    var onSend: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .preferredFont(forTextStyle: .body),
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding,
                             y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }
}

#endif
