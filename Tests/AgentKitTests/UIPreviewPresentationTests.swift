//
//  UIPreviewPresentationTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit

@MainActor
final class UIPreviewPresentationTests: XCTestCase {
    private let fallbackID = "asset_preview_fallback"
    private let layoutArtifactID = "layout_abcdef0123456789"
    private let layoutJSONID = "asset_layout_json"
    private let overlayID = "asset_layout_overlay"
    private let evidenceID = "asset_evidence_json"
    private let previewArtifactID = "preview_abcdef0123456789"
    private let sourceAssetID = "asset_source_screen"
    private let sourceSHA = String(repeating: "a", count: 64)
    private let evidenceSHA = String(repeating: "b", count: 64)
    private let layoutRevisionSHA = "sha256:" + String(repeating: "c", count: 64)
    private let fallbackSHA = String(repeating: "d", count: 64)

    func testValidAdaptationProjectsBySchemaForArbitraryToolName() throws {
        let tool = makeTool(
            toolName: "future_preview_surface",
            output: validResult(mode: "adaptation", lineage: validLineage()),
            assets: [fallbackAsset]
        )
        let projected = try project(
            tool,
            artifacts: [try makeArtifact(mode: "adaptation", lineage: validLineage())],
            registerActions: true
        )
        let preview = try XCTUnwrap(projected.uiPreview)

        XCTAssertEqual(preview.title, "DreamLog Duo Home")
        XCTAssertEqual(preview.mode, "adaptation")
        XCTAssertEqual(preview.modeLabel, "Adaptation Preview")
        XCTAssertEqual(preview.artifactKey, "preview_key")
        XCTAssertEqual(preview.artifactID, previewArtifactID)
        XCTAssertEqual(preview.revision, 1)
        XCTAssertEqual(preview.kind, "interactive_html")
        XCTAssertEqual(preview.presentationState, "interactiveReady")
        XCTAssertEqual(preview.statusLabel, "预览就绪")
        XCTAssertEqual(preview.fallback.assetID, fallbackID)
        XCTAssertEqual(preview.fallback.mimeType, "image/png")
        XCTAssertEqual(preview.fallback.sha256, fallbackSHA)
        XCTAssertNotNil(preview.fallback.viewActionID)
        XCTAssertNotNil(preview.rawActionID)

        let lineage = try XCTUnwrap(preview.lineage)
        XCTAssertEqual(lineage.layoutArtifactID, layoutArtifactID)
        XCTAssertEqual(lineage.layoutRevision, 3)
        XCTAssertEqual(lineage.layoutRevisionSHA256, layoutRevisionSHA)
        XCTAssertEqual(lineage.sourceAssetID, sourceAssetID)
        XCTAssertEqual(lineage.sourceAssetSHA256, sourceSHA)
        XCTAssertEqual(lineage.evidenceSHA256, evidenceSHA)
        XCTAssertEqual(lineage.target, "duo_folded")
        XCTAssertEqual(lineage.state, "home")
        XCTAssertEqual(lineage.targetMatrixID, "matrix_duo_primary")
        XCTAssertEqual(lineage.targetMatrixTargets, ["duo_folded", "iphone_portrait"])
        XCTAssertEqual(lineage.approvalState, "user_confirmed")
        XCTAssertEqual(lineage.approvalEvidenceRef, "approval-note-1")

        XCTAssertNil(projected.output, "structured preview JSON must not enter the transcript")
        XCTAssertNil(projected.detail)
        XCTAssertNil(projected.uiLayout)
        XCTAssertNil(projected.uiEvidence)
        XCTAssertNil(projected.imageView)
    }

    func testExplorePreviewIsExplicitlyMarkedAndHasNoLineage() throws {
        let tool = makeTool(
            toolName: "any",
            output: validResult(mode: "explore"),
            assets: [fallbackAsset]
        )
        let projected = try project(
            tool,
            artifacts: [try makeArtifact(mode: "explore", lineage: nil)]
        )
        let preview = try XCTUnwrap(projected.uiPreview)
        XCTAssertEqual(preview.mode, "explore")
        XCTAssertEqual(preview.modeLabel, "Explore Preview")
        XCTAssertNil(preview.lineage)
        XCTAssertNil(preview.layoutJSON)
        XCTAssertNil(preview.evidenceJSON)
    }

    func testReusedCallIDUsesRevisionDescribedByEachResultOnReplay() throws {
        // A replayed runtime can keep one call ID while the artifact gains a
        // second revision in a later turn. The earlier turn must keep its own
        // revision and fallback identity instead of being matched against the
        // newest revision and losing its card.
        guard case .object(var revisionTwoLineage) = validLineage() else {
            return XCTFail("lineage fixture is not an object")
        }
        revisionTwoLineage["target"] = .string("iphone_portrait")
        revisionTwoLineage["state"] = .string("compact")

        let revisionTwoFallbackID = "asset_preview_fallback_r2"
        let revisionTwoFallbackSHA = String(repeating: "e", count: 64)
        var revisionTwoJSON = try artifactJSON(
            mode: "adaptation",
            lineage: .object(revisionTwoLineage)
        )
        revisionTwoJSON["revision"] = .integer(2)
        revisionTwoJSON["viewer"] = .object([
            "url": .string("/v1/conversations/projection/previews/\(previewArtifactID)/revisions/2/viewer"),
            "mime_type": .string("text/html; charset=utf-8"),
            "size_bytes": .integer(1034),
            "sha256": .string("sha256:" + String(repeating: "8", count: 64)),
        ])
        revisionTwoJSON["fallback"] = .object([
            "asset_id": .string(revisionTwoFallbackID),
            "text": .string("Interactive preview unavailable. Showing static evidence."),
        ])
        revisionTwoJSON["assets"] = .array([
            .object([
                "asset_id": .string(revisionTwoFallbackID),
                "role": .string("fallback"),
                "mime_type": .string("image/png"),
                "size_bytes": .integer(6213),
                "sha256": .string("sha256:" + revisionTwoFallbackSHA),
                "content_url": .string(
                    "/v1/conversations/projection/previews/\(previewArtifactID)/revisions/2/assets/\(revisionTwoFallbackID)/content"
                ),
                "width": .integer(200),
                "height": .integer(400),
                "alt": .string("Second revision fallback"),
            ]),
        ])
        revisionTwoJSON.removeValue(forKey: "revision_sha256")
        revisionTwoJSON["revision_sha256"] = .string(
            try PreviewRFC8785.sha256(.object(revisionTwoJSON))
        )

        let revisionOne = try makeArtifact(mode: "adaptation", lineage: validLineage())
        let revisionTwo = try decodeArtifact(revisionTwoJSON)
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: validLineage()),
            assets: [fallbackAsset]
        )

        let projected = try project(tool, artifacts: [revisionOne, revisionTwo])
        let preview = try XCTUnwrap(projected.uiPreview)

        XCTAssertEqual(preview.artifactID, previewArtifactID)
        XCTAssertEqual(preview.revision, 1)
        XCTAssertEqual(preview.fallback.assetID, fallbackID)
        XCTAssertEqual(preview.fallback.sha256, fallbackSHA)
        XCTAssertEqual(preview.lineage?.target, "duo_folded")
    }

    func testAdaptationWithoutV2LineageIsNeverShownAsFormalPreview() throws {
        for lineage in [JSONValue.null, legacyV1Lineage()] {
            let tool = makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation", lineage: lineage),
                assets: [fallbackAsset]
            )
            let projected = try project(
                tool,
                artifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
            )
            XCTAssertNil(projected.uiPreview)
            XCTAssertEqual(projected.output, "ordinary output")
        }
    }

    func testExploreWithLineageIsRejected() throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "explore", lineage: lineage),
            assets: [fallbackAsset]
        )
        XCTAssertNil(try project(
            tool,
            artifacts: [try makeArtifact(mode: "explore", lineage: lineage)]
        ).uiPreview)
    }

    func testUnknownFieldsAndRecommendationsFallBackToOrdinaryOutput() throws {
        var root = try XCTUnwrap(validResult(mode: "explore").object)
        root["recommended_layout"] = .string("sidebar")
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: .object(root), assets: [fallbackAsset]),
            artifacts: [try makeArtifact(mode: "explore", lineage: nil)]
        ).uiPreview)

        var lineageObject = try XCTUnwrap(validLineage().object)
        lineageObject["recommended_target"] = .string("ipad_landscape")
        var result = try XCTUnwrap(validResult(mode: "adaptation").object)
        result["lineage"] = .object(lineageObject)
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: .object(result), assets: [fallbackAsset]),
            artifacts: [try makeArtifact(mode: "adaptation", lineage: .object(lineageObject))]
        ).uiPreview)

        var wrongSchema = try XCTUnwrap(validResult(mode: "explore").object)
        wrongSchema["schema"] = .string("ui_preview_result.v2")
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: .object(wrongSchema), assets: [fallbackAsset]),
            artifacts: [try makeArtifact(mode: "explore", lineage: nil)]
        ).uiPreview)
    }

    func testArtifactMustMatchModeTitleKindAndFallback() throws {
        let lineage = validLineage()
        let output = validResult(mode: "adaptation", lineage: lineage)

        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [fallbackAsset]),
            artifacts: [try makeArtifact(
                mode: "explore",
                lineage: lineage,
                title: "DreamLog Duo Home"
            )]
        ).uiPreview)

        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [fallbackAsset]),
            artifacts: [try makeArtifact(
                mode: "adaptation",
                lineage: lineage,
                title: "Different title"
            )]
        ).uiPreview)

        let mismatchedFallback = try artifactJSON(
            mode: "adaptation",
            lineage: lineage,
            fallbackSHA256: String(repeating: "e", count: 64)
        )
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [fallbackAsset]),
            artifacts: [try decodeArtifact(mismatchedFallback)]
        ).uiPreview)

        let missingMetadataLineage = try artifactJSON(mode: "adaptation", lineage: nil)
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [fallbackAsset]),
            artifacts: [try decodeArtifact(missingMetadataLineage)]
        ).uiPreview)
    }

    func testFallbackAssetMustBeRegisteredAndConsistent() throws {
        let lineage = validLineage()
        let output = validResult(mode: "adaptation", lineage: lineage)
        let artifact = try makeArtifact(mode: "adaptation", lineage: lineage)

        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: []),
            artifacts: [artifact]
        ).uiPreview)

        let wrongKind = AgentAssetRef(
            id: fallbackID,
            kind: "file",
            displayName: "fallback.png",
            workspaceID: "ws_current",
            workspaceRelativePath: fallbackPath,
            mimeType: "image/png",
            sourceCallID: "call_preview"
        )
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [wrongKind]),
            artifacts: [artifact]
        ).uiPreview)

        let wrongPath = AgentAssetRef(
            id: fallbackID,
            kind: "image",
            displayName: "fallback.png",
            workspaceID: "ws_current",
            workspaceRelativePath: ".codeagent/other/fallback.png",
            mimeType: "image/png",
            sourceCallID: "call_preview"
        )
        XCTAssertNil(try project(
            makeTool(toolName: "ui_preview", output: output, assets: [wrongPath]),
            artifacts: [artifact]
        ).uiPreview)
    }

    func testLineageResolvesLayoutJSONAndEvidenceJSON() throws {
        let lineage = validLineage()
        let layoutTurn = ConversationTurn(
            id: "layout_turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "layout_group", tools: [layoutTool]))],
            footer: nil,
            isLive: false
        )
        let previewTurn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation", lineage: lineage),
                assets: [fallbackAsset]
            )]))],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(
            timeline: [],
            turns: [layoutTurn, previewTurn],
            previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "projection"
        )
        let preview = try XCTUnwrap(
            document.turns.last?.blocks.first?.tools.first?.uiPreview
        )
        XCTAssertEqual(preview.layoutJSON?.assetID, layoutJSONID)
        XCTAssertEqual(preview.evidenceJSON?.assetID, evidenceID)
    }

    func testNativeCardModelProjectsValidatedAdaptation() throws {
        let lineage = validLineage()
        let layoutTurn = ConversationTurn(
            id: "layout_turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "layout_group", tools: [layoutTool]))],
            footer: nil,
            isLive: false
        )
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let previewTurn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let artifact = try makeArtifact(mode: "adaptation", lineage: lineage)

        let models = UIPreviewCardModelBuilder.models(
            turn: previewTurn,
            allTurns: [layoutTurn, previewTurn],
            previewArtifacts: [artifact],
            conversationID: "projection"
        )

        XCTAssertEqual(models.count, 1)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.callID, "call_preview")
        XCTAssertEqual(model.title, "DreamLog Duo Home")
        XCTAssertEqual(model.mode, "adaptation")
        XCTAssertEqual(model.modeLabel, "Adaptation Preview")
        XCTAssertEqual(model.artifactID, previewArtifactID)
        XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(model.revisionSHA256, artifact.revisionSHA256)
        XCTAssertEqual(model.presentationState, "interactiveReady")
        XCTAssertEqual(model.fallback.assetID, fallbackID)
        XCTAssertEqual(model.fallback.sha256, fallbackSHA)
        XCTAssertEqual(model.lineage?.target, "duo_folded")
        XCTAssertEqual(model.lineage?.state, "home")
        XCTAssertEqual(model.lineage?.targetMatrixID, "matrix_duo_primary")
        XCTAssertEqual(model.lineage?.targetMatrixTargets, ["duo_folded", "iphone_portrait"])
        XCTAssertEqual(model.lineage?.approvalState, "user_confirmed")
        XCTAssertEqual(model.lineage?.approvalEvidenceRef, "approval-note-1")
        XCTAssertEqual(model.layoutJSON?.id, layoutJSONID)
        XCTAssertEqual(model.evidenceJSON?.id, evidenceID)
    }

    func testNativeCardModelRendersOneBlockPerPreviewRevision() throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool, tool]))],
            footer: nil,
            isLive: false
        )
        let models = UIPreviewCardModelBuilder.models(
            turn: turn,
            allTurns: [turn],
            previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)],
            conversationID: "projection"
        )
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.revision, 1)
    }

    func testNativeCardModelProjectsExploreWithoutLineage() throws {
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "explore"),
            assets: [fallbackAsset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let models = UIPreviewCardModelBuilder.models(
            turn: turn,
            allTurns: [turn],
            previewArtifacts: [try makeArtifact(mode: "explore", lineage: nil)],
            conversationID: "projection"
        )
        XCTAssertEqual(models.count, 1)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.modeLabel, "Explore Preview")
        XCTAssertNil(model.lineage)
        XCTAssertNil(model.layoutJSON)
        XCTAssertNil(model.evidenceJSON)
        XCTAssertEqual(model.fallback.assetID, fallbackID)
    }

    func testNativeCardAppearsWhenArtifactArrivesAfterResult() throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let layoutTurn = ConversationTurn(
            id: "layout_turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "layout_group", tools: [layoutTool]))],
            footer: nil,
            isLive: false
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )

        XCTAssertTrue(UIPreviewCardModelBuilder.models(
            turn: turn,
            allTurns: [layoutTurn, turn],
            previewArtifacts: [],
            conversationID: "projection"
        ).isEmpty)

        let models = UIPreviewCardModelBuilder.models(
            turn: turn,
            allTurns: [layoutTurn, turn],
            previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)],
            conversationID: "projection"
        )
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.revision, 1)
    }

    func testNativeCardModelSuppressesUnvalidatedRecords() throws {
        let lineage = validLineage()
        let turn = { (tool: ToolNodePayload) -> ConversationTurn in
            ConversationTurn(
                id: "turn",
                userPrompt: nil,
                blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
                footer: nil,
                isLive: false
            )
        }

        // Adaptation without lineage.
        XCTAssertTrue(UIPreviewCardModelBuilder.models(
            turn: turn(makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation"),
                assets: [fallbackAsset]
            )),
            allTurns: [],
            previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: nil)],
            conversationID: "projection"
        ).isEmpty)

        // Explore carrying lineage.
        XCTAssertTrue(UIPreviewCardModelBuilder.models(
            turn: turn(makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "explore", lineage: lineage),
                assets: [fallbackAsset]
            )),
            allTurns: [],
            previewArtifacts: [try makeArtifact(mode: "explore", lineage: lineage)],
            conversationID: "projection"
        ).isEmpty)

        // Result/artifact fallback identity mismatch.
        XCTAssertTrue(UIPreviewCardModelBuilder.models(
            turn: turn(makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation", lineage: lineage),
                assets: [fallbackAsset]
            )),
            allTurns: [],
            previewArtifacts: [try decodeArtifact(artifactJSON(
                mode: "adaptation",
                lineage: lineage,
                fallbackSHA256: String(repeating: "e", count: 64)
            ))],
            conversationID: "projection"
        ).isEmpty)

        // Missing artifact.
        XCTAssertTrue(UIPreviewCardModelBuilder.models(
            turn: turn(makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation", lineage: lineage),
                assets: [fallbackAsset]
            )),
            allTurns: [],
            previewArtifacts: [],
            conversationID: "projection"
        ).isEmpty)
    }

    func testLiveAndReplayProduceSamePreviewAndOneBlock() async throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "arbitrary_preview_producer",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let liveArtifact = try makeArtifact(
            mode: "adaptation",
            lineage: lineage
        )
        let prefix: [AgentEvent] = [
            .turnStarted(turnID: "turn", text: "preview"),
            .toolStarted(
                turnID: "turn",
                callID: "call_preview",
                tool: ToolCall(callID: "call_preview", toolName: tool.toolName, toolArgs: nil)
            ),
            .toolFinished(turnID: "turn", callID: "call_preview", result: ToolResult(
                callID: "call_preview",
                toolName: tool.toolName,
                observation: tool.output,
                error: nil,
                output: tool.structuredOutput,
                assets: tool.assets
            )),
            .previewArtifact(PreviewArtifactEvent(
                sequence: 1,
                sessionID: "live",
                turnID: "turn",
                callID: "call_preview",
                artifact: liveArtifact
            )),
        ]

        let liveEngine = RuntimeEngine(sessionID: "live")
        for event in prefix { await liveEngine.ingest(event) }
        let liveDocument = ConversationWebDocumentBuilder.build(
            snapshot: await liveEngine.currentSnapshot(),
            conversationID: "live"
        )
        let livePreview = try XCTUnwrap(
            liveDocument.turns.first?.blocks.first?.tools.first?.uiPreview
        )
        XCTAssertNil(liveDocument.turns.first?.previews)

        var replayEvents = prefix
        replayEvents[3] = .previewArtifact(PreviewArtifactEvent(
            sequence: 1,
            sessionID: "replay",
            turnID: "turn",
            callID: "call_preview",
            artifact: liveArtifact
        ))
        let replayEngine = RuntimeEngine(sessionID: "replay")
        await replayEngine.importHistory(replayEvents + [
            .turnFinished(turnID: "turn", text: "done", textAnnotations: []),
        ])
        let replaySnapshot = await replayEngine.currentSnapshot()
        let firstReplay = ConversationWebDocumentBuilder.build(
            snapshot: replaySnapshot,
            conversationID: "replay"
        )
        let secondReplay = ConversationWebDocumentBuilder.build(
            snapshot: replaySnapshot,
            conversationID: "replay"
        )
        let replayPreview = try XCTUnwrap(
            firstReplay.turns.first?.blocks.first?.tools.first?.uiPreview
        )
        XCTAssertEqual(livePreview, replayPreview)
        XCTAssertNil(firstReplay.turns.first?.previews)

        let firstBlocks = firstReplay.turns.first?.blocks.flatMap(\.tools).filter {
            $0.uiPreview != nil
        } ?? []
        let secondBlocks = secondReplay.turns.first?.blocks.flatMap(\.tools).filter {
            $0.uiPreview != nil
        } ?? []
        XCTAssertEqual(firstBlocks.count, 1)
        XCTAssertEqual(secondBlocks.count, 1)
        XCTAssertEqual(firstBlocks, secondBlocks)
    }

    func testLaterArtifactArrivalInvalidatesReusedTurn() throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let withoutArtifact = RuntimeSnapshot(timeline: [], turns: [turn])
        let firstDocument = ConversationWebDocumentBuilder.build(
            snapshot: withoutArtifact,
            conversationID: "projection"
        )
        XCTAssertNil(firstDocument.turns.first?.blocks.first?.tools.first?.uiPreview)

        let withArtifact = RuntimeSnapshot(
            timeline: [],
            turns: [turn],
            previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
        )
        let direct = ConversationWebDocumentBuilder.build(
            snapshot: withArtifact,
            conversationID: "projection"
        )
        XCTAssertNotNil(direct.turns.first?.blocks.first?.tools.first?.uiPreview)
        let second = ConversationWebDocumentBuilder.buildWithStableTurns(
            snapshot: withArtifact,
            conversationID: "projection",
            reusing: ConversationWebDocumentBuilder.ReuseSource(
                snapshot: withoutArtifact,
                document: firstDocument,
                extensionContributions: [:]
            )
        )
        XCTAssertNotNil(second.document.turns.first?.blocks.first?.tools.first?.uiPreview)
        XCTAssertFalse(second.stableTurnIDs.contains("turn"))
    }

    func testInvalidAdaptationAlsoSuppressesGenericPreviewCard() throws {
        let lineage = validLineage()
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation"),
            assets: [fallbackAsset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
            ),
            conversationID: "projection"
        )
        XCTAssertNil(document.turns.first?.blocks.first?.tools.first?.uiPreview)
        XCTAssertNil(
            document.turns.first?.previews,
            "an adaptation without v2 lineage must not fall back to a generic preview"
        )
    }

    func testUnboundPreviewArtifactStillRendersGenericCard() throws {
        let artifact = try makeArtifact(
            mode: nil,
            lineage: nil,
            callID: "call_other"
        )
        let tool = makeTool(
            toolName: "other_preview_producer",
            output: validResult(mode: "explore"),
            assets: [fallbackAsset]
        )
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [artifact]
            ),
            conversationID: "projection"
        )
        XCTAssertNil(document.turns.first?.blocks.first?.tools.first?.uiPreview)
        XCTAssertEqual(document.turns.first?.previews?.count, 1)
    }

    func testProjectionLeaksNoWorkspacePathOrRecommendation() throws {
        let lineage = validLineage()
        let layoutTurn = ConversationTurn(
            id: "layout_turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "layout_group", tools: [layoutTool]))],
            footer: nil,
            isLive: false
        )
        let previewTurn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [makeTool(
                toolName: "ui_preview",
                output: validResult(mode: "adaptation", lineage: lineage),
                assets: [fallbackAsset]
            )]))],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [layoutTurn, previewTurn],
                previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
            ),
            conversationID: "projection"
        )
        let encoded = try XCTUnwrap(
            String(data: JSONEncoder().encode(document), encoding: .utf8)
        )
        XCTAssertFalse(encoded.contains(".codeagent/"))
        XCTAssertFalse(encoded.contains("ui-preview/"))
        XCTAssertFalse(encoded.contains("ui-evidence/"))
        XCTAssertFalse(encoded.contains("recommended_"))
        XCTAssertFalse(encoded.contains("viewer_html"))
    }

    func testActionsRouteByStableIdentity() throws {
        let lineage = validLineage()
        var actions: [String: ConversationWebAction] = [:]
        var index = 0
        let tool = makeTool(
            toolName: "ui_preview",
            output: validResult(mode: "adaptation", lineage: lineage),
            assets: [fallbackAsset]
        )
        let layoutTurn = ConversationTurn(
            id: "layout_turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "layout_group", tools: [layoutTool]))],
            footer: nil,
            isLive: false
        )
        let previewTurn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [layoutTurn, previewTurn],
                previewArtifacts: [try makeArtifact(mode: "adaptation", lineage: lineage)]
            ),
            conversationID: "actions",
            registerAction: { action in
                index += 1
                let token = "action_\(index)"
                actions[token] = action
                return token
            }
        )
        let preview = try XCTUnwrap(
            document.turns.last?.blocks.first?.tools.first?.uiPreview
        )

        let rawAction = try XCTUnwrap(preview.rawActionID.flatMap { actions[$0] })
        guard case .transcript(let turnID, let transcriptAction) = rawAction else {
            return XCTFail("Expected transcript action")
        }
        XCTAssertEqual(turnID, "turn")
        if case .openUIPreview(let callID) = transcriptAction {
            XCTAssertEqual(callID, "call_preview")
        } else {
            XCTFail("Expected openUIPreview action")
        }

        for (expectedID, actionID) in zip(
            [fallbackID, layoutJSONID, evidenceID],
            [
                preview.fallback.viewActionID,
                preview.layoutJSON?.viewActionID,
                preview.evidenceJSON?.viewActionID,
            ].compactMap { $0 }
        ) {
            guard case .transcript(_, .openAsset(let reference)) = try XCTUnwrap(
                actions[actionID]
            ) else {
                return XCTFail("Expected openAsset action")
            }
            XCTAssertEqual(reference.structuredAsset?.id, expectedID)
        }
    }

    // MARK: - Fixtures

    private var fallbackPath: String {
        ".codeagent/assets/ui-preview/\(previewArtifactID)/fallback.png"
    }

    private var layoutJSONPath: String {
        ".codeagent/assets/ui-layout/\(layoutArtifactID)/revision-000003/layout.json"
    }

    private var overlayPath: String {
        ".codeagent/assets/ui-layout/\(layoutArtifactID)/revision-000003/overlay.png"
    }

    private var evidencePath: String {
        "ui-evidence/\(String(sourceSHA.prefix(16)))/evidence.json"
    }

    private var fallbackAsset: AgentAssetRef {
        AgentAssetRef(
            id: fallbackID,
            kind: "image",
            displayName: "fallback.png",
            workspaceID: "ws_current",
            workspaceRelativePath: fallbackPath,
            mimeType: "image/png",
            sourceCallID: "call_preview"
        )
    }

    private var shapeMetadata: [String: JSONValue] {
        [
            "asset_role": .string("layout_overlay"),
            "layout_artifact_id": .string(layoutArtifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(layoutRevisionSHA),
            "source_asset_id": .string(sourceAssetID),
            "source_asset_sha256": .string(sourceSHA),
            "canvas": .object(["width": .integer(200), "height": .integer(400)]),
            "node_count": .integer(3),
        ]
    }

    private var overlayAsset: AgentAssetRef {
        AgentAssetRef(
            id: overlayID,
            kind: "image",
            displayName: "overlay.png",
            workspaceID: "ws_current",
            workspaceRelativePath: overlayPath,
            mimeType: "image/png",
            sourceCallID: "call_layout",
            metadata: shapeMetadata
        )
    }

    private var layoutJSONAsset: AgentAssetRef {
        var metadata = shapeMetadata
        metadata["asset_role"] = .string("layout_json")
        return AgentAssetRef(
            id: layoutJSONID,
            kind: "file",
            displayName: "layout.json",
            workspaceID: "ws_current",
            workspaceRelativePath: layoutJSONPath,
            mimeType: "application/json",
            sourceCallID: "call_layout",
            metadata: metadata
        )
    }

    private var evidenceAsset: AgentAssetRef {
        AgentAssetRef(
            id: evidenceID,
            kind: "file",
            displayName: "evidence.json",
            workspaceID: "ws_current",
            workspaceRelativePath: evidencePath,
            mimeType: "application/json",
            sourceCallID: "call_evidence",
            metadata: [
                "asset_role": .string("evidence"),
                "schema": .string("ui_evidence.v1"),
                "source_asset_id": .string(sourceAssetID),
                "sha256": .string(evidenceSHA),
                "evidence_sha256": .string(evidenceSHA),
                "evidence_path": .string(evidencePath),
            ]
        )
    }

    private var layoutTool: ToolNodePayload {
        ToolNodePayload(
            callID: "call_layout",
            toolName: "ui_layout",
            args: nil,
            status: .completed,
            output: "layout",
            structuredOutput: validLayout(),
            assets: [overlayAsset, layoutJSONAsset, evidenceAsset]
        )
    }

    private func validLayout() -> JSONValue {
        .object([
            "schema": .string("ui_layout_result.v1"),
            "layout_artifact_id": .string(layoutArtifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(layoutRevisionSHA),
            "source_asset_id": .string(sourceAssetID),
            "source_asset_sha256": .string(sourceSHA),
            "evidence_sha256": .string(evidenceSHA),
            "canvas": .object([
                "width": .integer(200),
                "height": .integer(400),
            ]),
            "node_count": .integer(3),
            "assumption_count": .integer(1),
            "targets": .array(["duo_folded", "iphone_portrait"].map(JSONValue.string)),
            "created": .bool(true),
            "overlay_asset": .object([
                "asset_id": .string(overlayID),
                "asset_role": .string("layout_overlay"),
                "kind": .string("image"),
                "relative_path": .string(overlayPath),
                "filename": .string("overlay.png"),
                "mime_type": .string("image/png"),
                "width": .integer(200),
                "height": .integer(400),
                "sha256": .string(String(repeating: "1", count: 64)),
            ]),
            "layout_json_asset": .object([
                "asset_id": .string(layoutJSONID),
                "asset_role": .string("layout_json"),
                "kind": .string("file"),
                "relative_path": .string(layoutJSONPath),
                "filename": .string("layout.json"),
                "mime_type": .string("application/json"),
                "sha256": .string(String(repeating: "2", count: 64)),
            ]),
        ])
    }

    private func validLineage() -> JSONValue {
        .object([
            "schema": .string("ui_preview_lineage.v2"),
            "layout_artifact_id": .string(layoutArtifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(layoutRevisionSHA),
            "source_asset_id": .string(sourceAssetID),
            "source_asset_sha256": .string(sourceSHA),
            "evidence_sha256": .string(evidenceSHA),
            "approval": .object([
                "state": .string("user_confirmed"),
                "evidence_ref": .string("approval-note-1"),
            ]),
            "target": .string("duo_folded"),
            "state": .string("home"),
            "target_matrix": .object([
                "id": .string("matrix_duo_primary"),
                "targets": .array(["duo_folded", "iphone_portrait"].map(JSONValue.string)),
            ]),
        ])
    }

    private func legacyV1Lineage() -> JSONValue {
        .object([
            "schema": .string("ui_preview_lineage.v1"),
            "layout_artifact_id": .string(layoutArtifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(layoutRevisionSHA),
            "source_asset_id": .string(sourceAssetID),
            "source_asset_sha256": .string(sourceSHA),
            "approval": .object(["state": .string("not_required")]),
        ])
    }

    private func validResult(
        mode: String,
        lineage: JSONValue = .null
    ) -> JSONValue {
        .object([
            "schema": .string("ui_preview_result.v1"),
            "artifact_key": .string("preview_key"),
            "kind": .string("interactive_html"),
            "title": .string("DreamLog Duo Home"),
            "mode": .string(mode),
            "lineage": lineage,
            "fallback_asset": .object([
                "asset_id": .string(fallbackID),
                "relative_path": .string(fallbackPath),
                "mime_type": .string("image/png"),
                "width": .integer(200),
                "height": .integer(400),
                "sha256": .string(fallbackSHA),
            ]),
        ])
    }

    private func artifactJSON(
        mode: String?,
        lineage: JSONValue?,
        callID: String = "call_preview",
        title: String = "DreamLog Duo Home",
        sessionID: String = "projection",
        fallbackSHA256: String? = nil
    ) throws -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let mode { metadata["preview_mode"] = .string(mode) }
        if let lineage { metadata["ui_preview_lineage"] = lineage }

        let assetSHA = "sha256:" + (fallbackSHA256 ?? fallbackSHA)
        let assetRoute = "/v1/conversations/\(sessionID)/previews/\(previewArtifactID)/revisions/1/assets/\(fallbackID)/content"
        var object: [String: JSONValue] = [
            "schema_version": .string("preview.artifact.v1"),
            "artifact_id": .string(previewArtifactID),
            "revision": .integer(1),
            "status": .string("ready"),
            "kind": .string("interactive_html"),
            "title": .string(title),
            "summary": .string("Preview summary"),
            "capability": .string("ui-adaptation"),
            "producer_id": .string("ui_preview"),
            "session_id": .string(sessionID),
            "turn_id": .string("turn"),
            "call_id": .string(callID),
            "created_at": .string("2026-11-14T12:00:00Z"),
            "updated_at": .string("2026-11-14T12:00:00Z"),
            "expires_at": .null,
            "presentation": .object([
                "placement": .string("conversation_inline"),
                "preferred_aspect_ratio": .number(1.78),
                "min_height": .integer(420),
                "initial_state": .string("expanded"),
            ]),
            "viewer": .object([
                "url": .string("/v1/conversations/\(sessionID)/previews/\(previewArtifactID)/revisions/1/viewer"),
                "mime_type": .string("text/html; charset=utf-8"),
                "size_bytes": .integer(1034),
                "sha256": .string("sha256:" + String(repeating: "9", count: 64)),
            ]),
            "assets": .array([
                .object([
                    "asset_id": .string(fallbackID),
                    "role": .string("fallback"),
                    "mime_type": .string("image/png"),
                    "size_bytes": .integer(6213),
                    "sha256": .string(assetSHA),
                    "content_url": .string(assetRoute),
                    "width": .integer(200),
                    "height": .integer(400),
                    "alt": .string("DreamLog Duo preview fallback"),
                ]),
            ]),
            "fallback": .object([
                "asset_id": .string(fallbackID),
                "text": .string("Interactive preview unavailable. Showing static evidence."),
            ]),
            "security": .object([
                "profile": .string("preview.security.v1"),
                "javascript": .string("isolated_only"),
                "network": .string("deny"),
                "navigation": .string("deny"),
                "persistent_data": .string("deny"),
                "actions": .string("none"),
            ]),
            "error": .null,
            "metadata": .object(metadata),
        ]
        object["revision_sha256"] = .string(try PreviewRFC8785.sha256(.object(object)))
        return object
    }

    private func decodeArtifact(_ object: [String: JSONValue]) throws -> PreviewArtifact {
        try PreviewArtifact.decode(.object(object))
    }

    private func makeArtifact(
        mode: String?,
        lineage: JSONValue?,
        callID: String = "call_preview",
        title: String = "DreamLog Duo Home",
        sessionID: String = "projection"
    ) throws -> PreviewArtifact {
        try decodeArtifact(try artifactJSON(
            mode: mode,
            lineage: lineage,
            callID: callID,
            title: title,
            sessionID: sessionID
        ))
    }

    private func makeTool(
        callID: String = "call_preview",
        toolName: String,
        output: JSONValue,
        assets: [AgentAssetRef]
    ) -> ToolNodePayload {
        ToolNodePayload(
            callID: callID,
            toolName: toolName,
            args: nil,
            status: .completed,
            output: "ordinary output",
            structuredOutput: output,
            assets: assets
        )
    }

    private func project(
        _ tool: ToolNodePayload,
        artifacts: [PreviewArtifact] = [],
        registerActions: Bool = false
    ) throws -> ConversationWebDocument.Tool {
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "group", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        var index = 0
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: artifacts
            ),
            conversationID: "projection",
            registerAction: registerActions ? { _ in
                index += 1
                return "action_\(index)"
            } : nil
        )
        return try XCTUnwrap(document.turns.first?.blocks.first?.tools.first)
    }
}
