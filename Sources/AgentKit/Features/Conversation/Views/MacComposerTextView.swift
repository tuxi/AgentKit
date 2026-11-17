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
    /// Host classifies dropped images and path references without uploading.
    /// A missing callback preserves plain path insertion for legacy callers.
    var onFileDrop: (([URL]) -> Bool)? = nil

    var onDropTargetChange: ((Bool) -> Void)? = nil
    var suggestionText: String? = nil
    var onDismissSuggestion: (() -> Void)? = nil
    var completionScope = ""
    var onImagePaste: ((Data) -> Void)? = nil
    var tokens: Binding<[ComposerToken]> = .constant([])
    var queryCompletions: ((String, String, Int64) async throws -> ComposerCompletionResult)? = nil
    var resolveReference: ((ComposerCompletionItem) async throws -> ComposerCompletionItem)? = nil
    var onCompletionAction: ((String) -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

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
        textView.font = .systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 21
        paragraph.maximumLineHeight = 21
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (text as NSString).length))
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.autoresizingMask = [.width]
        textView.suggestionText = suggestionText
        textView.placeholderString = placeholder
        textView.onFocusChange = { focused in
            onFocusChange?(focused)
            if !focused { context.coordinator.closeCompletions() }
        }
        textView.onSend = onSend
        textView.onDropTargetChange = onDropTargetChange
        textView.onImagePaste = onImagePaste
        textView.onFileDrop = onFileDrop
        textView.onTextInserted = { [weak textView] in
            guard let textView else { return }
            context.coordinator.parent.text = textView.string
        }
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // 首帧测量一次高度。
        let coordinator = context.coordinator
        Task { @MainActor in coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.parent.completionScope != completionScope { context.coordinator.closeCompletions() }
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }

        // 流式消息更新会频繁触发 updateNSView。若此时用户正在使用输入法
        // （拼音/中文等），textView 处于 marked text（组字）状态。设置 .string
        // 会无条件清除 marked text，导致中文输入被打断。英文/数字不经过 marked
        // text 阶段，因此不受影响。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.suggestionText = suggestionText
        textView.placeholderString = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.onFocusChange = { focused in
            onFocusChange?(focused)
            if !focused { context.coordinator.closeCompletions() }
        }
        textView.onSend = onSend
        textView.onDropTargetChange = onDropTargetChange
        textView.onImagePaste = onImagePaste
        textView.onFileDrop = onFileDrop
        textView.onTextInserted = { [weak textView] in
            guard let textView else { return }
            context.coordinator.parent.text = textView.string
        }
        context.coordinator.recalculateHeight()
        context.coordinator.applyTokenAppearance()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.closeCompletions()
        (scrollView.documentView as? NSTextView)?.undoManager?.removeAllActions(withTarget: coordinator)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: MacComposerTextView
        weak var textView: ComposerNSTextView?
        private var measuredText: String?
        private var measuredWidth: CGFloat = -1
        private var measuredMaximum: CGFloat = -1
        private var heightRevision = 0
        private var completionTask: Task<Void, Never>?
        private var completionRevision: Int64 = 0
        private var completionRange: NSRange?
        private var completionPanel: MacComposerCompletionPanel?
        private var completionMonitor: Any?
        private let completionState = MacComposerCompletionState()
        private var replacingToken = false
        private var appliedTokens: [ComposerToken]?
        private var appearanceText: String?

        init(_ parent: MacComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            applyTokenAppearance()
            recalculateHeight()
            updateCompletions()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let replacementLength = (replacementString as NSString).length
            let affected = affectedCharRange
            if replacementLength == 0, affected.length > 0, !replacingToken,
               let token = parent.tokens.wrappedValue.first(where: { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), affected).length > 0 }) {
                replacingToken = true
                textView.insertText("", replacementRange: NSUnionRange(affected, NSRange(location: token.location, length: token.length)))
                replacingToken = false
                return false
            }
            let previousTokens = parent.tokens.wrappedValue
            let updatedTokens = previousTokens.compactMap { token -> ComposerToken? in
                var token = token
                let tokenRange = NSRange(location: token.location, length: token.length)
                if NSIntersectionRange(tokenRange, affected).length > 0 { return nil }
                if affected.length == 0 && affected.location > token.location && affected.location < NSMaxRange(tokenRange) { return nil }
                if token.location >= NSMaxRange(affected) { token.location += replacementLength - affected.length }
                return token
            }
            if previousTokens != updatedTokens {
                registerTokenUndo(previousTokens)
                parent.tokens.wrappedValue = updatedTokens
            }
            return true
        }

        private func registerTokenUndo(_ tokens: [ComposerToken]) {
            textView?.undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.registerTokenUndo(target.parent.tokens.wrappedValue)
                    target.parent.tokens.wrappedValue = tokens
                    target.appliedTokens = nil
                    target.applyTokenAppearance()
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, let range = completionRange else { return }
            let caret = tv.selectedRange()
            if caret.length > 0 || caret.location < range.location || caret.location > NSMaxRange(range) { closeCompletions() }
        }

        func applyTokenAppearance() {
            guard let tv = textView, !tv.hasMarkedText(), let storage = tv.textStorage else { return }
            let tokens = parent.tokens.wrappedValue
            guard appliedTokens != tokens || appearanceText != tv.string else { return }
            appliedTokens = tokens; appearanceText = tv.string
            var coloredRanges: [NSRange] = []
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { color, range, _ in
                if let color = color as? NSColor, !color.isEqual(NSColor.labelColor) { coloredRanges.append(range) }
            }
            storage.beginEditing()
            storage.removeAttribute(.toolTip, range: NSRange(location: 0, length: storage.length))
            for range in coloredRanges { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
            for token in parent.tokens.wrappedValue {
                guard token.location >= 0, token.length > 0, token.location <= storage.length, token.length <= storage.length - token.location else { continue }
                let range = NSRange(location: token.location, length: token.length)
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                storage.addAttribute(.toolTip, value: token.item.kind == "conversation" ? "引用最近 3 轮的消息片段；重新选择可更新快照。" : token.item.detail, range: range)
            }
            storage.endEditing()
            tv.typingAttributes[.foregroundColor] = NSColor.labelColor
        }

        func closeCompletions() {
            completionTask?.cancel(); completionTask = nil
            completionRevision += 1
            if let panel = completionPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            if let completionMonitor { NSEvent.removeMonitor(completionMonitor); self.completionMonitor = nil }
            completionRange = nil
        }

        private func updateCompletions() {
            guard let tv = textView, !tv.hasMarkedText(), let query = parent.queryCompletions else { closeCompletions(); return }
            let text = tv.string as NSString
            let caret = tv.selectedRange().location
            guard tv.selectedRange().length == 0, caret <= text.length else { closeCompletions(); return }
            let prefix = text.substring(to: caret)
            let word = prefix.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            let kind: String
            let queryText: String
            let range: NSRange
            if prefix.trimmingCharacters(in: .whitespaces).hasPrefix("/"), !prefix.trimmingCharacters(in: .whitespaces).contains(where: { $0.isWhitespace }) {
                let value = prefix.trimmingCharacters(in: .whitespaces)
                kind = "command"; queryText = String(value.dropFirst()); range = NSRange(location: caret - (value as NSString).length, length: (value as NSString).length)
            } else if word.hasPrefix("@"), !prefix.hasSuffix(" "), !prefix.hasSuffix("\n") {
                kind = "reference"; queryText = String(word.dropFirst()); range = NSRange(location: caret - (word as NSString).length, length: (word as NSString).length)
            } else { closeCompletions(); return }
            guard queryText.utf8.count <= 512 else { closeCompletions(); return }
            closeCompletions()
            completionRange = range
            let revision = completionRevision
            completionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let result = try await query(kind, queryText, revision)
                    guard let self, !Task.isCancelled, self.completionRevision == revision else { return }
                    self.completionState.items = result.items
                    self.completionState.selected = 0
                    self.completionState.message = result.items.isEmpty ? "没有匹配项" : (result.truncated ? "输入更多字符以缩小范围" : nil)
                    self.showCompletions(kind: kind)
                } catch {
                    guard let self, !Task.isCancelled, self.completionRevision == revision else { return }
                    self.completionState.items = []
                    self.completionState.message = "当前环境暂不支持补全"
                    self.showCompletions(kind: kind)
                }
            }
        }

        private func showCompletions(kind: String) {
            guard let tv = textView, let window = tv.window else { return }
            let width = min(max(240, window.contentView?.bounds.width ?? 320), kind == "command" ? 340 : 640)
            let view = NSHostingView(rootView: MacComposerCompletionList(state: completionState, width: width))
            let panel = completionPanel ?? MacComposerCompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            panel.hasShadow = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hidesOnDeactivate = true
            panel.contentView = view
            panel.isOpaque = false
            panel.backgroundColor = .clear
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.masksToBounds = true
            let size = view.fittingSize
            let anchor = window.convertToScreen(tv.convert(tv.bounds, to: nil))
            let visible = window.screen?.visibleFrame ?? window.frame
            let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8)
            let y = anchor.maxY + 8 + size.height <= visible.maxY ? anchor.maxY + 8 : max(visible.minY, anchor.minY - size.height - 8)
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            completionPanel = panel
            if completionMonitor == nil {
                completionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let tv = self.textView else { return }
                        if event.window !== self.completionPanel {
                            let insideEditor = event.window === tv.window && tv.bounds.contains(tv.convert(event.locationInWindow, from: nil))
                            if !insideEditor { self.closeCompletions() }
                        }
                    }
                    return event
                }
            }
            completionState.onSelect = { [weak self] item in self?.chooseCompletion(item) }
        }

        private func chooseCompletion(_ item: ComposerCompletionItem) {
            if item.kind == "conversation", item.contextText == nil {
                guard let resolve = parent.resolveReference else { return }
                completionTask?.cancel()
                let revision = completionRevision
                completionState.items = []
                completionState.message = "正在读取引用…"
                showCompletions(kind: "reference")
                completionTask = Task { @MainActor [weak self] in
                    do {
                        let resolved = try await resolve(item)
                        guard let self, !Task.isCancelled, self.completionRevision == revision else { return }
                        self.insertCompletion(resolved)
                    } catch {
                        guard let self, !Task.isCancelled, self.completionRevision == revision else { return }
                        self.completionState.message = "无法读取此引用，请重试或按 Esc 关闭"
                    }
                }
                return
            }
            insertCompletion(item)
        }

        private func insertCompletion(_ item: ComposerCompletionItem) {
            guard let tv = textView, let range = completionRange else { return }
            closeCompletions()
            if item.action != "insert" {
                guard ["model", "permissions", "skills"].contains(item.action) else { return }
                tv.insertText("", replacementRange: range)
                parent.onCompletionAction?(item.action)
                return
            }
            let previousTokens = parent.tokens.wrappedValue
            tv.insertText(item.insertText + " ", replacementRange: range)
            registerTokenUndo(previousTokens)
            parent.tokens.wrappedValue.append(ComposerToken(location: range.location, length: (item.insertText as NSString).length, item: item, workspacePath: parent.completionScope))
            parent.text = tv.string
            applyTokenAppearance()
        }

        /// 基于 layoutManager 的实际排版高度做自适应，clamp 到 [min, max]。
        func recalculateHeight() {
            guard let tv = textView,
                  let layoutManager = tv.layoutManager,
                  let container = tv.textContainer else { return }
            guard measuredText != tv.string || measuredWidth != tv.bounds.width || measuredMaximum != parent.maxHeight else { return }
            measuredText = tv.string
            measuredWidth = tv.bounds.width
            measuredMaximum = parent.maxHeight
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = tv.textContainerInset.height * 2
            let target = min(max(used + inset, parent.minHeight), parent.maxHeight)
            if abs(parent.height - target) > 0.5 {
                heightRevision += 1
                let revision = heightRevision
                let newHeight = target
                // 延后一拍，避免在 SwiftUI 视图更新周期内直接改 @Binding。
                Task { @MainActor [weak self] in
                    guard let self, self.heightRevision == revision else { return }
                    self.parent.height = newHeight
                }
            }
        }

        /// 回车 / Shift+回车 / 输入法处理的核心。
        /// 注意：IME 组字期间，回车用于选定候选词，input context 会消化该事件，
        /// 根本不会走到这里 —— 因此中文/联想输入永远不会误发。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if completionPanel?.isVisible == true {
                if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
                    let count = completionState.items.count
                    if count > 0 { completionState.selected = (completionState.selected + (commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : count - 1)) % count }
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeCompletions(); return true }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
                    if completionState.items.indices.contains(completionState.selected) { chooseCompletion(completionState.items[completionState.selected]) }
                    return true
                }
            }
            if textView.string.isEmpty, let suggestion = parent.suggestionText, !suggestion.isEmpty {
                if commandSelector == #selector(NSResponder.insertTab(_:)) {
                    textView.insertText(suggestion, replacementRange: textView.selectedRange())
                    parent.text = textView.string
                    parent.onDismissSuggestion?()
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onDismissSuggestion?(); return true }
            }
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

    var suggestionText: String? { didSet { if string.isEmpty { needsDisplay = true } } }

    var placeholderString: String = "" {
        didSet { if string.isEmpty { needsDisplay = true } }
    }
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange?(false) }
        return result
    }

    var onSend: (() -> Void)?
    var onDropTargetChange: ((Bool) -> Void)?
    var onImagePaste: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        if let urls = fileURLs(from: pasteboard), let onFileDrop, onFileDrop(urls) { return }
        if let onImagePaste, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            onImagePaste(data)
            return
        }
        super.paste(sender)
    }

    var onFileDrop: (([URL]) -> Bool)?
    /// Called after text is programmatically inserted (e.g., via drag-drop).
    /// Allows the SwiftUI binding to be updated.
    var onTextInserted: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = suggestionText ?? placeholderString
        guard !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .preferredFont(forTextStyle: .body),
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding,
                             y: textContainerInset.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var displayAttrs = attrs
        displayAttrs[.paragraphStyle] = paragraph
        let markerWidth: CGFloat = suggestionText == nil ? 0 : 30
        placeholder.draw(in: NSRect(x: origin.x, y: origin.y, width: max(0, bounds.width - origin.x - markerWidth), height: 24), withAttributes: displayAttrs)
        if suggestionText != nil {
            "⇥".draw(at: NSPoint(x: max(origin.x, bounds.width - 22), y: origin.y), withAttributes: attrs)
        }
    }

    // MARK: - Drag Destination

    private var isDropTargeted = false {
        didSet {
            guard isDropTargeted != oldValue else { return }
            onDropTargetChange?(isDropTargeted)
            if onDropTargetChange != nil { return }
            wantsLayer = true
            layer?.borderWidth = isDropTargeted ? 2 : 0
            layer?.borderColor = isDropTargeted
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            layer?.cornerRadius = 8
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, let urls = fileURLs(from: sender.draggingPasteboard),
              !urls.isEmpty,
              canAcceptDrop(urls) else {
            return []
        }
        isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, let urls = fileURLs(from: sender.draggingPasteboard),
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
        guard isEditable, let urls = fileURLs(from: sender.draggingPasteboard),
              !urls.isEmpty else { return false }

        if let onFileDrop { return onFileDrop(urls) }

        let pathURLs = urls.filter { !Self.isImageFile($0) }
        let imageURLs = urls.filter { Self.isImageFile($0) }

        var accepted = false
        // 非图片（文件/目录）：完整路径直接插入为文本。
        if !pathURLs.isEmpty {
            insertPathText(pathURLs)
            onTextInserted?()
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
            let preceding = (fullText as NSString).substring(to: caret)
            if preceding.last?.isWhitespace == false {
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
