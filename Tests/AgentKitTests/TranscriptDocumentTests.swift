//
//  TranscriptDocumentTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit

final class TranscriptDocumentTests: XCTestCase {

    func testListFilesCompilesToDirectoryArtifact() {
        var tool = ToolCallItem(
            callID: "call_list",
            toolName: "list_files",
            toolArgs: .object(["path": .string("Sources/AgentKit")])
        )
        tool.status = .completed
        tool.result = ToolResult(
            callID: "call_list",
            toolName: "list_files",
            observation: "Core\nFeatures\nResources",
            error: nil
        )

        let artifact = ToolSemanticCompiler.compile(tool, turnID: "turn")

        XCTAssertEqual(artifact?.renderKind, .files)
        guard case .directory(let payload) = artifact?.content else {
            XCTFail("Expected list_files to render as a directory artifact")
            return
        }
        XCTAssertEqual(payload.path, "Sources/AgentKit")
        XCTAssertEqual(payload.listing, "Core\nFeatures\nResources")
    }

    func testListFilesEmptyObservationCompilesToEmptyDirectoryListing() {
        var tool = ToolCallItem(
            callID: "call_list",
            toolName: "list_files",
            toolArgs: .object(["path": .string(".git")])
        )
        tool.status = .completed
        tool.result = ToolResult(
            callID: "call_list",
            toolName: "list_files",
            observation: "[observation] ok\n---\n(empty)",
            error: nil
        )

        let artifact = ToolSemanticCompiler.compile(tool, turnID: "turn")

        guard case .directory(let payload) = artifact?.content else {
            XCTFail("Expected list_files to render as a directory artifact")
            return
        }
        XCTAssertEqual(payload.path, ".git")
        XCTAssertEqual(payload.listing, "")
        XCTAssertEqual(payload.entryCount, 0)
        XCTAssertEqual(artifact.map(SummaryRenderer.summary), "Listed 0 files in .git/")
    }

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
        XCTAssertTrue(rendered.contains("line 1\nline 2"))
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

    func testSystemToolErrorRendersAsProminentFailure() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .system(
                    id: "error",
                    SystemNodePayload(
                        kind: .observation,
                        text: "Tool error: fetch: HTTP 404"
                    )
                )
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let rendered = transcript.attributedString.string

        XCTAssertTrue(rendered.contains("! Error"))
        XCTAssertTrue(rendered.contains("Tool error: fetch: HTTP 404"))
        let errorBlock = attributes(in: transcript.attributedString, for: "! Error")[.transcriptBlock]
        XCTAssertEqual((errorBlock as? TranscriptBlockValue)?.kind, .error)
        XCTAssertNotNil(attributes(in: transcript.attributedString, for: "Tool error")[.foregroundColor])
    }

    func testMarkdownTableRowsHaveBackground() {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: """
                    | 文件 | 行 | 内容 |
                    | --- | ---: | --- |
                    | App.swift | 12 | value |
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

        // Header, rule, and body rows all carry the same table block tag so
        // the layout manager draws one full-width background behind them.
        let headerBlock = attributes(in: transcript.attributedString, for: "文件")[.transcriptBlock]
        let rowBlock = attributes(in: transcript.attributedString, for: "App.swift")[.transcriptBlock]
        XCTAssertEqual((headerBlock as? TranscriptBlockValue)?.kind, .table)
        XCTAssertEqual((rowBlock as? TranscriptBlockValue)?.kind, .table)
        XCTAssertEqual(headerBlock as? TranscriptBlockValue, rowBlock as? TranscriptBlockValue)
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

    func testToolFinishedDecodesStructuredOutputAndAssetsFromFixtures() throws {
        let fixtures: [(name: String, tool: String, outputKind: String, assetKind: String)] = [
            ("tool_finished_grep_assets.json", "grep", "search_results", "file_location"),
            ("tool_finished_read_file_assets.json", "read_file", "file", "file"),
            ("tool_finished_project_graph_assets.json", "project_graph", "symbols", "symbol")
        ]

        for fixture in fixtures {
            let wire = try JSONDecoder().decode(WireFrame.self, from: fixtureData(fixture.name))
            guard case .toolFinished(let turnID, let callID, let result) = AgentEvent.from(wire: wire) else {
                return XCTFail("Expected tool_finished event for \(fixture.name)")
            }

            XCTAssertEqual(result.toolName, fixture.tool)
            XCTAssertEqual(result.output?["kind"].stringValue, fixture.outputKind)
            XCTAssertEqual(result.assets.first?.kind, fixture.assetKind)
            XCTAssertEqual(result.assets.first?.sourceTurnID, turnID)
            XCTAssertEqual(result.assets.first?.sourceCallID, callID)
            XCTAssertTrue(result.assets.first?.id.hasPrefix("asset_") == true)
            XCTAssertNotNil(result.assets.first?.workspaceRelativePath)
            XCTAssertNotNil(result.assets.first?.preview)
        }
    }

    func testTurnFinishedDecodesTextAnnotations() throws {
        let data = """
        {
          "event_id": "evt_fixed",
          "kind": "turn_finished",
          "at": "2026-06-24T10:00:00.123Z",
          "session_id": "sess_root",
          "turn_id": "turn_7",
          "text_annotations": [
            {
              "asset_id": "asset_turn_7_call_grep_001_7156f5c8",
              "kind": "file_location",
              "text": "App.swift:5",
              "start_byte": 6,
              "end_byte": 17,
              "start_utf16": 6,
              "end_utf16": 17,
              "source_turn_id": "turn_7",
              "source_call_id": "call_grep"
            }
          ],
          "text": "Open `App.swift:5` for the important line."
        }
        """.data(using: .utf8)!

        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        guard case .turnFinished(let turnID, let text, let annotations) = AgentEvent.from(wire: wire) else {
            return XCTFail("Expected turn_finished event")
        }

        XCTAssertEqual(turnID, "turn_7")
        XCTAssertEqual(text, "Open `App.swift:5` for the important line.")
        XCTAssertEqual(annotations.first?.assetID, "asset_turn_7_call_grep_001_7156f5c8")
        XCTAssertEqual(annotations.first?.startUTF16, 6)
        XCTAssertEqual(annotations.first?.sourceCallID, "call_grep")
    }

    func testStructuredAssetTakesPriorityOverRegexPathFallback() {
        let asset = AgentAssetRef(
            id: "asset_turn_c1_001",
            kind: "file_location",
            uri: "workspace://agentkit-local/Sources/App.swift#L12",
            displayName: "App.swift:12",
            workspaceID: "agentkit-local",
            workspaceRelativePath: "Sources/App.swift",
            range: AgentAssetRange(startLine: 12),
            preview: "let value = 42",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "grep",
            args: .object(["query": .string("value")]),
            status: .completed,
            output: "Sources/App.swift:12: let value = 42",
            assets: [asset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Open Sources/App.swift for context."
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
            return reference.kind == .structured
                && reference.structuredAsset?.id == "asset_turn_c1_001"
        })
    }

    func testStructuredAssetMatchesWorkspaceRelativePathAliases() {
        let asset = AgentAssetRef(
            id: "asset_video",
            kind: "video",
            uri: "workspace://ai-local/all_highlights/highlight_2.mp4",
            displayName: "highlight_2.mp4",
            workspaceID: "ai-local",
            workspaceRelativePath: "all_highlights/highlight_2.mp4",
            absolutePath: "/Users/example/ai/all_highlights/highlight_2.mp4",
            mimeType: "video/mp4",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "list_files",
            args: .object(["path": .string(".")]),
            status: .completed,
            output: "all_highlights/highlight_2.mp4",
            assets: [asset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Open ./all_highlights/highlight_2.mp4 or /all_highlights/highlight_2.mp4."
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let references = transcript.actions.values.compactMap { action -> AssetReference? in
            guard case .openAsset(let reference) = action else { return nil }
            return reference
        }

        XCTAssertTrue(references.contains {
            $0.display == "./all_highlights/highlight_2.mp4"
                && $0.kind == .structured
                && $0.structuredAsset?.id == asset.id
        })
        XCTAssertTrue(references.contains {
            $0.display == "/all_highlights/highlight_2.mp4"
                && $0.kind == .structured
                && $0.structuredAsset?.id == asset.id
        })
    }

    func testAssetDisplayIndexDeduplicatesSameFileLineAcrossTools() {
        let projectGraphAsset = AgentAssetRef(
            id: "asset_project_graph",
            kind: "file_location",
            displayName: "Contents.swift:109",
            workspaceID: "learningios-local",
            workspaceRelativePath: "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift",
            range: AgentAssetRange(startLine: 109, startColumn: 1),
            preview: "@HTMLBuilder content: () -> String) -> String {",
            sourceCallID: "call_project_graph"
        )
        let grepAsset = AgentAssetRef(
            id: "asset_grep",
            kind: "file_location",
            displayName: "Contents.swift:109",
            workspaceID: "learningios-local",
            workspaceRelativePath: "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift",
            range: AgentAssetRange(startLine: 109, startColumn: 12),
            preview: "@HTMLBuilder content: () -> String) -> String {",
            sourceCallID: "call_grep"
        )

        let unique = AgentAssetDisplayIndex.unique([projectGraphAsset, grepAsset])

        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.id, "asset_grep")
        XCTAssertEqual(unique.first?.range?.startColumn, 12)
    }

    func testTextAnnotationLinksInlineCodeToStructuredAsset() {
        let annotation = AgentTextAnnotation(
            assetID: "asset_turn_c1_001",
            kind: "file_location",
            text: "App.swift:12",
            startUTF16: 6,
            endUTF16: 18,
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let asset = AgentAssetRef(
            id: "asset_turn_c1_001",
            kind: "file_location",
            uri: "workspace://agentkit-local/Sources/App.swift#L12",
            displayName: "App.swift:12",
            workspaceID: "agentkit-local",
            workspaceRelativePath: "Sources/App.swift",
            range: AgentAssetRange(startLine: 12),
            preview: "let value = 42",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "grep",
            args: .object(["query": .string("value")]),
            status: .completed,
            output: "Sources/App.swift:12: let value = 42",
            assets: [asset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Open `App.swift:12` for the important line.",
                    textAnnotations: [annotation]
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )

        XCTAssertTrue(transcript.attributedString.string.contains("App.swift:12"))
        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.kind == .structured
                && reference.display == "App.swift:12"
                && reference.structuredAsset?.id == annotation.assetID
        })
    }

    func testTextAnnotationsLinkBareLineNumbersInsideMarkdownTable() {
        let asset99 = AgentAssetRef(
            id: "asset_line_99",
            kind: "file_location",
            displayName: "Contents.swift:99",
            workspaceID: "learningios-local",
            workspaceRelativePath: "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift",
            range: AgentAssetRange(startLine: 99, startColumn: 1),
            preview: "struct HTMLBuilder {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let asset109 = AgentAssetRef(
            id: "asset_line_109",
            kind: "file_location",
            displayName: "Contents.swift:109",
            workspaceID: "learningios-local",
            workspaceRelativePath: "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift",
            range: AgentAssetRange(startLine: 109, startColumn: 1),
            preview: "@HTMLBuilder content: () -> String) -> String {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "project_graph",
            args: .object(["symbol": .string("HTMLBuilder")]),
            status: .completed,
            output: "references",
            assets: [asset99, asset109]
        )
        let annotations = [
            AgentTextAnnotation(
                assetID: asset99.id,
                kind: "file_location",
                text: "99",
                sourceTurnID: "turn",
                sourceCallID: "c1"
            ),
            AgentTextAnnotation(
                assetID: asset109.id,
                kind: "file_location",
                text: "109",
                sourceTurnID: "turn",
                sourceCallID: "c1"
            )
        ]
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: """
                    | 行号 | 文件 | 内容 |
                    |------|------|------|
                    | 99 | `CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift` | `struct HTMLBuilder {` |
                    | 109 | 同上 | `@HTMLBuilder content: () -> String) -> String {` |
                    """,
                    textAnnotations: annotations
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
            return reference.display == "99"
                && reference.structuredAsset?.id == asset99.id
        })
        XCTAssertTrue(transcript.actions.values.contains {
            guard case .openAsset(let reference) = $0 else { return false }
            return reference.display == "109"
                && reference.structuredAsset?.id == asset109.id
        })
    }

    func testDuplicateAnnotationTextIsConsumedInRenderedOrder() {
        let path = "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift"
        let asset99 = AgentAssetRef(
            id: "asset_line_99",
            kind: "file_location",
            displayName: "Contents.swift:99",
            workspaceID: "learningios-local",
            workspaceRelativePath: path,
            range: AgentAssetRange(startLine: 99, startColumn: 8),
            preview: "struct HTMLBuilder {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let asset109 = AgentAssetRef(
            id: "asset_line_109",
            kind: "file_location",
            displayName: "Contents.swift:109",
            workspaceID: "learningios-local",
            workspaceRelativePath: path,
            range: AgentAssetRange(startLine: 109, startColumn: 12),
            preview: "@HTMLBuilder content: () -> String) -> String {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "grep",
            args: .object(["query": .string("HTMLBuilder")]),
            status: .completed,
            output: "references",
            assets: [asset99, asset109]
        )
        let annotations = [
            AgentTextAnnotation(
                assetID: asset99.id,
                kind: "file_location",
                text: path,
                startUTF16: 70,
                endUTF16: 148,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            ),
            AgentTextAnnotation(
                assetID: asset109.id,
                kind: "file_location",
                text: path,
                startUTF16: 190,
                endUTF16: 268,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            )
        ]
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: """
                    | # | 文件 | 行号 |
                    |---|------|------|
                    | 1 | `\(path)` | 99 |
                    | 2 | `\(path)` | 109 |
                    """,
                    textAnnotations: annotations
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let structuredIDs = transcript.actions.values.compactMap { action -> String? in
            guard case .openAsset(let reference) = action,
                  reference.display == path else {
                return nil
            }
            return reference.structuredAsset?.id
        }

        XCTAssertTrue(structuredIDs.contains(asset99.id))
        XCTAssertTrue(structuredIDs.contains(asset109.id))
    }

    func testTablePathAnnotationUsesNearbyLineNumberAsset() {
        let path = "CodePractice.playground/Pages/01-SwiftDeepDive.xcplaygroundpage/Contents.swift"
        let asset99 = AgentAssetRef(
            id: "asset_line_99",
            kind: "file_location",
            displayName: "Contents.swift:99",
            workspaceID: "learningios-local",
            workspaceRelativePath: path,
            range: AgentAssetRange(startLine: 99, startColumn: 8),
            preview: "struct HTMLBuilder {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let asset109 = AgentAssetRef(
            id: "asset_line_109",
            kind: "file_location",
            displayName: "Contents.swift:109",
            workspaceID: "learningios-local",
            workspaceRelativePath: path,
            range: AgentAssetRange(startLine: 109, startColumn: 12),
            preview: "@HTMLBuilder content: () -> String) -> String {",
            mimeType: "text/x-swift",
            sourceTurnID: "turn",
            sourceCallID: "c1"
        )
        let tool = ToolNodePayload(
            callID: "c1",
            toolName: "grep",
            args: .object(["query": .string("HTMLBuilder")]),
            status: .completed,
            output: "references",
            assets: [asset99, asset109]
        )
        let annotations = [
            AgentTextAnnotation(
                assetID: asset99.id,
                kind: "file_location",
                text: path,
                startUTF16: 95,
                endUTF16: 173,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            ),
            AgentTextAnnotation(
                assetID: asset99.id,
                kind: "file_location",
                text: "99",
                startUTF16: 177,
                endUTF16: 179,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            ),
            AgentTextAnnotation(
                assetID: asset99.id,
                kind: "file_location",
                text: path,
                startUTF16: 222,
                endUTF16: 300,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            ),
            AgentTextAnnotation(
                assetID: asset109.id,
                kind: "file_location",
                text: "109",
                startUTF16: 304,
                endUTF16: 307,
                sourceTurnID: "turn",
                sourceCallID: "c1"
            )
        ]
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "c1", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: """
                    | # | 文件 | 行号 | 上下文 |
                    |---|------|------|--------|
                    | 1 | `\(path)` | 99 | `struct HTMLBuilder {` |
                    | 2 | `\(path)` | 109 | `@HTMLBuilder content: () -> String) -> String {` |
                    """,
                    textAnnotations: annotations
                ))
            ],
            footer: nil,
            isLive: false
        )

        let transcript = TurnTranscriptBuilder.build(
            turn: turn,
            state: TranscriptDocumentState()
        )
        let structuredIDs = transcript.actions.values.compactMap { action -> String? in
            guard case .openAsset(let reference) = action,
                  reference.display == path else {
                return nil
            }
            return reference.structuredAsset?.id
        }

        XCTAssertTrue(structuredIDs.contains(asset99.id))
        XCTAssertTrue(structuredIDs.contains(asset109.id))
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

    func testDirectoryPathPrefersTurnArtifactOverStructuredAsset() {
        let artifact = ArtifactNode(
            callID: "call_list",
            turnID: "turn",
            kind: .listFiles,
            renderKind: .files,
            path: ".git",
            content: .directory(DirectoryPayload(path: ".git", listing: ""))
        )
        let runtimeDirectory = AgentAssetRef(
            id: "asset_directory_git",
            kind: "directory",
            displayName: ".git/",
            workspaceRelativePath: ".git",
            preview: ".git/objects/info/\n.git/objects/pack/"
        )
        let tool = ToolNodePayload(
            callID: "call_list",
            toolName: "list_files",
            args: .object(["path": .string(".git")]),
            status: .completed,
            output: "[observation] ok\n---\n(empty)",
            assets: [runtimeDirectory],
            artifact: artifact
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [
                .toolGroup(ToolGroup(id: "call_list", tools: [tool])),
                .text(id: "t1", MessageNodePayload(
                    role: .assistant,
                    text: "Open `.git/`."
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
            return reference.display == ".git/"
                && reference.kind == .artifact
                && reference.resolvedArtifactCallID == "call_list"
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
        XCTAssertEqual((attrs[.transcriptBlock] as? TranscriptBlockValue)?.kind, .code)
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

    private func fixtureData(_ name: String) throws -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: packageRoot
                .appendingPathComponent("docs/protocols/fixtures/tool-assets")
                .appendingPathComponent(name)
        )
    }
}
