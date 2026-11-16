#if os(macOS)
import AppKit

extension NSAttributedString.Key {
    static let desktopToolOutput = NSAttributedString.Key("agentkit.desktopToolOutput")
}

/// A fixed-height TextKit slot with an independently selectable/scrollable
/// output view over it. The command remains ordinary text above the slot.
final class NativeToolOutputValue: NSObject {
    let callID: String
    let output: String
    let running: Bool
    let isInput: Bool
    var identity: String { (isInput ? "input:" : "output:") + callID }
    let height: CGFloat

    init(callID: String, output: String, running: Bool, isInput: Bool = false) {
        self.callID = callID
        self.output = output
        self.running = running
        self.isInput = isInput
        self.height = min(isInput ? 160 : 280, max(42, CGFloat(max(output.components(separatedBy: "\n").count, output.utf16.count / 90 + 1)) * 19 + 12))
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NativeToolOutputValue else { return false }
        return identity == other.identity && output == other.output && running == other.running
    }
    override var hash: Int { identity.hashValue ^ output.hashValue }
}

final class NativeToolOutputCell: NSTextAttachmentCell {
    let height: CGFloat
    init(height: CGFloat) {
        self.height = height
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: 1, height: height) }
}

@MainActor
final class NativeToolOutputScrollView: NSScrollView {
    private let outputView = NSTextView(frame: .zero)
    private var value: NativeToolOutputValue?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = false
        outputView.textContainerInset = NSSize(width: 4, height: 4)
        documentView = outputView
    }
    required init?(coder: NSCoder) { nil }

    func update(_ next: NativeToolOutputValue) {
        let wasAtBottom = outputView.frame.height - contentView.bounds.maxY < 8
        let hadValue = value != nil
        let oldOrigin = contentView.bounds.origin
        let old = value
        value = next
        if old?.output != next.output {
            let text = NSAttributedString(string: next.output, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            if let storage = outputView.textStorage { _ = TranscriptTextApplier.apply(text, to: storage) }
        }
        outputView.setAccessibilityLabel(ToolTranscriptText().text(next.isInput ? "input" : "output"))
        outputView.textContainer?.containerSize = NSSize(width: max(1, bounds.width - 20), height: .greatestFiniteMagnitude)
        if let manager = outputView.layoutManager, let container = outputView.textContainer {
            manager.ensureLayout(for: container)
            outputView.setFrameSize(NSSize(width: bounds.width, height: max(bounds.height, manager.usedRect(for: container).height + 8)))
        }
        let follow = hadValue && next.running && wasAtBottom && outputView.selectedRange().length == 0
        let y = follow ? max(0, outputView.frame.height - bounds.height) : min(oldOrigin.y, max(0, outputView.frame.height - bounds.height))
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}
#endif
