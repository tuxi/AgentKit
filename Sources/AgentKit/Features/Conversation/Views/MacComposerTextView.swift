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
import UniformTypeIdentifiers

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
    /// 拖拽图片到输入框时回调（仅图片走附件流程）。返回 true 表示接受拖放。
    /// 非图片文件/目录不经过此回调 —— 其完整路径会直接插入为输入框文本。
    var onFileDrop: (([URL]) -> Bool)? = nil

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
        textView.onFileDrop = onFileDrop
        textView.registerForDraggedTypes([.fileURL])

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

        // 流式消息更新会频繁触发 updateNSView。若此时用户正在使用输入法
        // （拼音/中文等），textView 处于 marked text（组字）状态。设置 .string
        // 会无条件清除 marked text，导致中文输入被打断。英文/数字不经过 marked
        // text 阶段，因此不受影响。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.placeholderString = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSend = onSend
        textView.onFileDrop = onFileDrop
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
/// 拖放支持：图片文件走 onFileDrop（附件流程）；非图片文件/目录的
/// 完整路径直接插入为输入框文本。
final class ComposerNSTextView: NSTextView {

    var placeholderString: String = "" {
        didSet { if string.isEmpty { needsDisplay = true } }
    }
    var onSend: (() -> Void)?
    var onFileDrop: (([URL]) -> Bool)?

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

    // MARK: - Drag Destination

    private var isDropTargeted = false {
        didSet {
            guard isDropTargeted != oldValue else { return }
            wantsLayer = true
            layer?.borderWidth = isDropTargeted ? 2 : 0
            layer?.borderColor = isDropTargeted
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            layer?.cornerRadius = 8
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = fileURLs(from: sender.draggingPasteboard),
              !urls.isEmpty,
              canAcceptDrop(urls) else {
            return []
        }
        isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let urls = fileURLs(from: sender.draggingPasteboard),
              !urls.isEmpty,
              canAcceptDrop(urls) else {
            isDropTargeted = false
            return []
        }
        isDropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        guard let urls = fileURLs(from: sender.draggingPasteboard),
              !urls.isEmpty else { return false }

        let pathURLs = urls.filter { !Self.isImageFile($0) }
        let imageURLs = urls.filter { Self.isImageFile($0) }

        var accepted = false
        // 非图片（文件/目录）：完整路径直接插入为文本。
        if !pathURLs.isEmpty {
            insertPathText(pathURLs)
            accepted = true
        }
        // 图片：走附件流程（拷贝到工作区或上传 gateway）。
        if !imageURLs.isEmpty, let onFileDrop {
            accepted = onFileDrop(imageURLs) || accepted
        }
        return accepted
    }

    /// 拖放是否可接受：只要包含非图片项（文件/目录）即可接受，其路径将作为文本插入；
    /// 纯图片拖放仅在配置了 onFileDrop 时接受（附件流程）。
    private func canAcceptDrop(_ urls: [URL]) -> Bool {
        if urls.contains(where: { !Self.isImageFile($0) }) { return true }
        return onFileDrop != nil
    }

    /// 将非图片文件/目录的完整路径作为文本插入到当前光标处。
    /// 多个路径以空格分隔；若插入点前已有非空白字符则自动补一个空格分隔。
    private func insertPathText(_ urls: [URL]) {
        guard !urls.isEmpty, isEditable else { return }
        let fullText = string
        let joined = urls.map(\.path).joined(separator: " ")

        let caret = min(max(selectedRange.location, 0), (fullText as NSString).length)
        var insertion = joined
        if caret > 0 {
            let prev = fullText[fullText.index(fullText.startIndex, offsetBy: caret - 1)]
            if !prev.isWhitespace {
                insertion = " " + insertion
            }
        }
        let range = NSRange(location: caret, length: 0)
        replaceCharacters(in: range, with: insertion)
        setSelectedRange(NSRange(location: caret + (insertion as NSString).length, length: 0))
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        let urls = items.compactMap { item -> URL? in
            guard let path = item.string(forType: .fileURL) else { return nil }
            return URL(string: path)
        }
        return urls.isEmpty ? nil : urls
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
              let type = UTType(uti) else { return false }
        return type.conforms(to: .image)
    }
}

#endif
