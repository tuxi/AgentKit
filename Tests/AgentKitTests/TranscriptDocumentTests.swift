//
//  TranscriptDocumentTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit

final class TranscriptDocumentTests: XCTestCase {

    func testToolPresenterMakesReadableTitles() {
        let read = ToolNodePayload(
            callID: "c1",
            toolName: "read_file",
            args: .object(["path": .string("Sources/App.swift")]),
            status: .completed,
            elapsedMs: 12
        )
        let run = ToolNodePayload(
            callID: "c2",
            toolName: "run_command",
            args: .object(["command": .string("swift test")]),
            status: .running
        )

        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: read).title, "Read App.swift")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: run).title, "Run swift test")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: run).statusTone, .running)
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: run).statusText, "running")
    }

    func testCollapsedToolProducesToggleActionWithoutOutput() {
        let turn = makeTurn(toolOutput: "secret output")
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.attributedString.string.contains("Read App.swift"))
        XCTAssertFalse(transcript.attributedString.string.contains("secret output"))
        XCTAssertTrue(transcript.actions.values.contains(.toggleTool(callID: "c1")))
        XCTAssertTrue(transcript.copyText.contains("Read App.swift"))
    }

    func testExpandedToolIncludesArgsOutputAndArtifactAction() {
        let turn = makeTurn(toolOutput: "line 1\nline 2", includeArtifact: true)
        let state = TranscriptDocumentState(expandedToolIDs: ["c1"])
        let transcript = TurnTranscriptBuilder.build(turn: turn, state: state)
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("Input"))
        XCTAssertTrue(rendered.contains("path"))
        XCTAssertTrue(rendered.contains("Sources\\/App.swift"))
        XCTAssertTrue(rendered.contains("Output"))
        XCTAssertTrue(rendered.contains("line 1\n  line 2"))
        XCTAssertTrue(rendered.contains("Artifact"))
        XCTAssertTrue(transcript.actions.values.contains(.toggleTool(callID: "c1")))
        XCTAssertTrue(transcript.actions.values.contains(.openArtifact(callID: "c1")))
    }

    func testMultipleToolsCollapseToGroupSummary() {
        let turn = makeMultiToolTurn()
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("Read 2 files"))
        XCTAssertFalse(rendered.contains("Sources/A.swift"))
        XCTAssertFalse(rendered.contains("Sources/B.swift"))
        XCTAssertTrue(transcript.actions.values.contains(.toggleTool(callID: "group:c1")))
    }

    func testExpandedToolGroupShowsTargetsOnly() {
        let turn = makeMultiToolTurn()
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState(expandedToolIDs: ["group:c1"])
        )
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("Read 2 files"))
        XCTAssertTrue(rendered.contains("Read A.swift"))
        XCTAssertTrue(rendered.contains("Read B.swift"))
        XCTAssertFalse(rendered.contains("a contents"))
        XCTAssertFalse(rendered.contains("b contents"))
    }

    func testRunningAndFailedToolsExposeSubtleStatusText() {
        let running = ToolNodePayload(
            callID: "run",
            toolName: "run_command",
            args: .object(["command": .string("swift test")]),
            status: .running
        )
        let failed = ToolNodePayload(
            callID: "fail",
            toolName: "run_command",
            args: .object(["command": .string("swift build")]),
            status: .failed,
            exitCode: 1
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "tools", tools: [running, failed]))],
            footer: nil,
            isLive: true
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState(expandedToolIDs: ["group:tools"])
        )
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("running"))
        XCTAssertTrue(rendered.contains("failed 1"))
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: running).statusTone, .running)
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: failed).statusTone, .failed)
    }

    func testRunningToolAnimationFrameChangesTranscriptGlyph() {
        let tool = ToolNodePayload(
            callID: "run",
            toolName: "run_command",
            args: .object(["command": .string("swift test")]),
            status: .running
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "run", tools: [tool]))],
            footer: nil,
            isLive: true
        )

        let first = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState(),
            animationFrame: 0
        )
        let second = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState(),
            animationFrame: 1
        )

        XCTAssertTrue(first.attributedString.string.contains("running"))
        XCTAssertTrue(second.attributedString.string.contains("running"))
        XCTAssertNotEqual(first.attributedString.string, second.attributedString.string)
    }

    func testDiffSummaryAppearsOnCollapsedToolLine() {
        let diff = """
        @@ -1,1 +1,1 @@
        -old line
        +new line
        """
        let turn = makeTurn(toolOutput: diff)
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.attributedString.string.contains("+1 -1"))
    }

    func testStandaloneArtifactProducesPathAction() {
        let artifact = makeArtifact()
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: MessageNodePayload(role: .user, text: "show file"),
            blocks: [.artifact(id: "artifact-c1", artifact)],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.attributedString.string.contains("Sources/App.swift"))
        XCTAssertTrue(transcript.actions.values.contains(.openArtifact(callID: "c1")))
        XCTAssertTrue(transcript.actions.values.contains(.openPath("Sources/App.swift")))
    }

    func testBodyTextDetectsURLAndPathAssets() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Open Sources/App.swift and https://example.com/docs for context."
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.kind == .filePath && reference.target == "Sources/App.swift"
        })
        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.kind == .url && reference.target == "https://example.com/docs"
        })
    }

    func testBodyPathResolvesKnownArtifact() {
        let artifact = makeArtifact()
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .artifact(id: "artifact-c1", artifact),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "The relevant file is Sources/App.swift."
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.kind == .artifact
                && reference.target == "Sources/App.swift"
                && reference.resolvedArtifactCallID == "c1"
        })
    }

    func testMarkdownHeadingListAndInlineCodeRenderAsTranscriptText() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "# Plan\n\n- Edit `Sources/App.swift`\n- Run tests"
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("Plan"))
        XCTAssertFalse(rendered.contains("# Plan"))
        XCTAssertTrue(rendered.contains("- Edit Sources/App.swift"))
        XCTAssertTrue(rendered.contains("- Run tests"))
    }

    func testMarkdownLinkProducesAssetAction() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Read [the docs](https://example.com/docs)."
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.attributedString.string.contains("the docs"))
        XCTAssertFalse(transcript.attributedString.string.contains("https://example.com/docs"))
        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.kind == .url && reference.target == "https://example.com/docs"
        })
    }

    func testMarkdownCodeBlockHasCodeBackground() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: """
                    ```swift
                    let value = 42
                    ```
                    """
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        let attrs = attributes(in: transcript.attributedString, for: "let value")
        XCTAssertNotNil(attrs[.backgroundColor])
        XCTAssertNotNil(attrs[.font])
    }

    func testExpandedDiffOutputHasLineColors() {
        let diff = """
        @@ -1,2 +1,2 @@
        -old line
        +new line
        """
        let turn = makeTurn(toolOutput: diff)
        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState(expandedToolIDs: ["c1"])
        )

        let removed = attributes(in: transcript.attributedString, for: "-old line")
        let added = attributes(in: transcript.attributedString, for: "+new line")

        XCTAssertNotNil(removed[.foregroundColor])
        XCTAssertNotNil(added[.foregroundColor])
        XCTAssertNotEqual(
            String(describing: removed[.foregroundColor] as Any),
            String(describing: added[.foregroundColor] as Any)
        )
    }

    private func makeTurn(toolOutput: String, includeArtifact: Bool = false) -> ConversationTurn {
        let artifact = includeArtifact ? makeArtifact() : nil
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "read_file",
            args: .object(["path": .string("Sources/App.swift")]),
            status: .completed,
            output: toolOutput,
            exitCode: 0,
            elapsedMs: 12,
            isAutoApproved: false,
            artifact: artifact
        )

        return ConversationTurn(
            id: "turn",
            userPrompt: MessageNodePayload(role: .user, text: "read it"),
            blocks: [
                .text(id: "t1", MessageNodePayload(role: .assistant, text: "I'll inspect it.")),
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t2", MessageNodePayload(role: .assistant, text: "Done."))
            ],
            footer: TurnStats(promptTokens: 1200, elapsedMs: 30, invocationCount: 1),
            isLive: false
        )
    }

    private func makeMultiToolTurn() -> ConversationTurn {
        let a = ToolNodePayload(
            callID: "c1",
            toolName: "read_file",
            args: .object(["path": .string("Sources/A.swift")]),
            status: .completed,
            output: "a contents",
            exitCode: 0,
            elapsedMs: 10
        )
        let b = ToolNodePayload(
            callID: "c2",
            toolName: "read_file",
            args: .object(["path": .string("Sources/B.swift")]),
            status: .completed,
            output: "b contents",
            exitCode: 0,
            elapsedMs: 12
        )

        return ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "c1", tools: [a, b]))],
            footer: nil,
            isLive: false
        )
    }

    private func makeArtifact() -> ArtifactNode {
        ArtifactNode(
            callID: "c1",
            turnID: "turn",
            kind: .fileRead,
            renderKind: .file,
            path: "Sources/App.swift",
            content: .file(FilePayload(
                filePath: "Sources/App.swift",
                content: "import SwiftUI",
                language: "swift"
            ))
        )
    }

    private func attributes(
        in attributed: NSAttributedString,
        for needle: String
    ) -> [NSAttributedString.Key: Any] {
        let range = (attributed.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing substring: \(needle)")
        guard range.location != NSNotFound else { return [:] }
        return attributed.attributes(at: range.location, effectiveRange: nil)
    }
}
