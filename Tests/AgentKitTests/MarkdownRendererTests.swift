//
//  MarkdownRendererTests.swift
//  AgentKitTests
//
//  Tests for MarkdownASTConverter, inline rendering, and streaming diff.
//

import XCTest
@testable import AgentKit

final class MarkdownASTConverterTests: XCTestCase {

    // MARK: - Block Parsing

    func testEmptyInput() {
        let blocks = MarkdownASTConverter.parse("")
        XCTAssertEqual(blocks.count, 0)
    }

    func testSingleParagraph() {
        let blocks = MarkdownASTConverter.parse("Hello, world!")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(inlines.count, 1)
        if case .text(let s) = inlines[0] {
            XCTAssertEqual(s, "Hello, world!")
        } else {
            XCTFail("Expected text")
        }
    }

    func testHeadings() {
        let blocks = MarkdownASTConverter.parse("# Title\n## Section\n### Subsection")
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(level: 1, _) = blocks[0] else { XCTFail("Expected h1"); return }
        guard case .heading(level: 2, _) = blocks[1] else { XCTFail("Expected h2"); return }
        guard case .heading(level: 3, _) = blocks[2] else { XCTFail("Expected h3"); return }
    }

    func testCodeBlock() {
        let md = """
        ```swift
        let x = 1
        print(x)
        ```
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .codeBlock(let lang, let code) = blocks[0] else {
            XCTFail("Expected codeBlock"); return
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertTrue(code.contains("let x = 1"))
    }

    func testUnorderedList() {
        let md = """
        - Item one
        - Item two
        - Item three
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .unorderedList(let items) = blocks[0] else {
            XCTFail("Expected unorderedList"); return
        }
        XCTAssertEqual(items.count, 3)
    }

    func testOrderedList() {
        let md = """
        1. First
        2. Second
        3. Third
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .orderedList(let items, let start) = blocks[0] else {
            XCTFail("Expected orderedList"); return
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(start, 1)
    }

    func testTaskList() {
        let md = """
        - [x] Done item
        - [ ] Todo item
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .unorderedList(let items) = blocks[0] else {
            XCTFail("Expected unorderedList with checkboxes"); return
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].checkbox, .checked)
        XCTAssertEqual(items[1].checkbox, .unchecked)
    }

    func testBlockquote() {
        let md = "> This is a quote"
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .blockquote(_) = blocks[0] else {
            XCTFail("Expected blockquote"); return
        }
    }

    func testThematicBreak() {
        let blocks = MarkdownASTConverter.parse("---")
        XCTAssertEqual(blocks.count, 1)
        guard case .thematicBreak = blocks[0] else {
            XCTFail("Expected thematicBreak"); return
        }
    }

    func testTable() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let head, let body) = blocks[0] else {
            XCTFail("Expected table"); return
        }
        XCTAssertEqual(head.count, 2)
        XCTAssertEqual(body.count, 1)
    }

    // MARK: - Inline Parsing

    func testBold() {
        let blocks = MarkdownASTConverter.parse("Hello **world**!")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else { XCTFail("Expected paragraph"); return }
        let hasStrong = inlines.contains { if case .strong = $0 { true } else { false } }
        XCTAssertTrue(hasStrong, "Expected a strong inline node")
    }

    func testItalic() {
        let blocks = MarkdownASTConverter.parse("Hello *world*!")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else { XCTFail("Expected paragraph"); return }
        let hasEmphasis = inlines.contains { if case .emphasis = $0 { true } else { false } }
        XCTAssertTrue(hasEmphasis, "Expected an emphasis inline node")
    }

    func testInlineCode() {
        let blocks = MarkdownASTConverter.parse("Use `let x = 1` to declare.")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else { XCTFail("Expected paragraph"); return }
        let hasCode = inlines.contains {
            if case .inlineCode(let code) = $0, code == "let x = 1" { true } else { false }
        }
        XCTAssertTrue(hasCode, "Expected inline code node")
    }

    func testLink() {
        let blocks = MarkdownASTConverter.parse("[Click here](https://example.com)")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let inlines) = blocks[0] else { XCTFail("Expected paragraph"); return }
        let hasLink = inlines.contains {
            if case .link(let dest, _) = $0, dest == "https://example.com" { true } else { false }
        }
        XCTAssertTrue(hasLink, "Expected link node")
    }

    // MARK: - Regression: Bug "step9step9_assemble"

    func testOrderedListDoesNotCorruptText() {
        let md = """
        1. step1_setup
        2. step2_configure
        3. step3_assemble
        """
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .orderedList(let items, _) = blocks[0] else {
            XCTFail("Expected orderedList"); return
        }
        XCTAssertEqual(items.count, 3)

        for (i, item) in items.enumerated() {
            XCTAssertFalse(item.blocks.isEmpty, "Item \(i) should have at least one block")
        }
    }

    func testMixedBoldItalicDoesNotCorrupt() {
        let md = "This is **bold** and *italic* and `code` text."
        let blocks = MarkdownASTConverter.parse(md)
        XCTAssertEqual(blocks.count, 1)

        guard case .paragraph(let inlines) = blocks[0] else { XCTFail("Expected paragraph"); return }
        let rendered = MarkdownInlineRenderer.render(inlines)
        XCTAssertFalse(rendered.characters.isEmpty, "Rendered output should not be empty")
    }

    // MARK: - Streaming Diff: Stable Prefix

    func testStablePrefixPreservesIDs() {
        let text1 = "# Hello\n\nThis is a paragraph."
        let text2 = "# Hello\n\nThis is a paragraph.\n\nMore content here."

        let blocks1 = MarkdownASTConverter.parse(text1)
        let blocks2 = MarkdownASTConverter.parse(text2)

        XCTAssertGreaterThanOrEqual(blocks2.count, blocks1.count)
        XCTAssertEqual(blocks1[0].id, blocks2[0].id, "Heading block ID should be stable")
    }
}
