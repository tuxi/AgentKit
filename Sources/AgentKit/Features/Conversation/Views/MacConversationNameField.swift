#if os(macOS)
import AppKit
import SwiftUI

/// Native single-line field: the field editor owns selection, IME and shortcuts.
struct MacConversationNameField: NSViewRepresentable {
    @Binding var text: String
    var isSaving: Bool
    var focusRevision: Int
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NameField {
        let field = NameField()
        field.stringValue = text
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.setAccessibilityLabel("对话名称")
        field.setAccessibilityIdentifier("conversation.title.editor")
        field.onAttach = { [weak field, weak coordinator = context.coordinator] in
            guard let field else { return }
            coordinator?.focus(field)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NameField, context: Context) {
        let oldRevision = context.coordinator.parent.focusRevision
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != text, !composing { field.stringValue = text }
        field.isEditable = !isSaving
        if oldRevision != focusRevision, !isSaving { context.coordinator.focus(field) }
    }

    static func dismantleNSView(_ field: NameField, coordinator: Coordinator) {
        field.onAttach = nil
        field.delegate = nil
        if let editor = field.currentEditor(), field.window?.firstResponder === editor {
            field.window?.makeFirstResponder(coordinator.previousResponder)
        }
    }

    final class NameField: NSTextField {
        var onAttach: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacConversationNameField
        weak var field: NSTextField?
        weak var previousResponder: NSResponder?
        private var ended = false
        init(_ parent: MacConversationNameField) { self.parent = parent }

        func focus(_ field: NSTextField) {
            Task { @MainActor [weak self, weak field] in
                guard let self, let field, let window = field.window, !self.parent.isSaving else { return }
                if self.previousResponder == nil { self.previousResponder = window.firstResponder }
                window.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: field.stringValue.utf16.count))
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) { ended = false }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ obj: Notification) { commit() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                ended = true
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commit()
                return true
            }
            return false
        }

        private func commit() {
            guard !ended, !parent.isSaving else { return }
            ended = true
            if let field { parent.text = field.stringValue }
            parent.onCommit()
        }
    }
}
#endif
