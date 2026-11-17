#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AgentKit

@MainActor
final class MacComposerAlignmentTests: XCTestCase {
    private struct Editor: View {
        @State var text: String
        @State private var height: CGFloat = 28
        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "plus").frame(width: 28, height: 28)
                MacComposerTextView(text: $text, height: $height, placeholder: "输入消息…",
                    isEnabled: true, minHeight: 28, maxHeight: 100, onSend: {})
                    .frame(height: max(28, min(height, 100)))
                Image(systemName: "return").frame(width: 28, height: 28)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .padding(12)
            .frame(width: 600)
        }
    }

    private func findEditor(in view: NSView) -> ComposerNSTextView? {
        if let editor = view as? ComposerNSTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    func testSingleLineTextAndCaretAreCenteredAndMultilineStillScrolls() async throws {
        for (name, text) in [("empty", ""), ("chinese", "我重新进游戏了，还是提示游戏数据损坏并强制退出"),
                             ("mixed", "Hello 你好 👋"), ("newline", "第一行\n"),
                             ("overflow", String(repeating: "输入区滚动测试\n", count: 20))] {
            let host = NSHostingView(rootView: Editor(text: text))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 180),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let editor = try XCTUnwrap(findEditor(in: host))
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            let used = editor.contentLayoutHeight
            if ["empty", "chinese", "mixed"].contains(name) {
                XCTAssertEqual(scroll.contentSize.height, 28, accuracy: 0.5, name)
                XCTAssertEqual(editor.textContainerOrigin.y + used / 2, scroll.contentSize.height / 2, accuracy: 0.5, name)
                let screenCaret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let caret = editor.convert(window.convertFromScreen(screenCaret), from: nil)
                XCTAssertEqual(caret.midY, scroll.contentSize.height / 2, accuracy: 1, name)
            } else if name == "newline" {
                XCTAssertGreaterThan(scroll.contentSize.height, 28)
                XCTAssertGreaterThanOrEqual(scroll.contentSize.height, used + 4 - 0.5)
            } else {
                XCTAssertEqual(scroll.contentSize.height, 100, accuracy: 0.5)
                XCTAssertGreaterThan(used, scroll.contentSize.height)
                XCTAssertEqual(editor.textContainerOrigin.y, 2, accuracy: 0.5)
            }
            if let destination = ProcessInfo.processInfo.environment["COMPOSER_SNAPSHOTS"],
               let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: destination).appendingPathComponent("alignment-\(name).png"))
            }
        }
    }
}
#endif
