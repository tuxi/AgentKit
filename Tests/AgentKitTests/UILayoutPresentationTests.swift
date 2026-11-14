//
//  UILayoutPresentationTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit

@MainActor
final class UILayoutPresentationTests: XCTestCase {
    private let overlayID = "asset_layout_overlay"
    private let layoutJSONID = "asset_layout_json"
    private let artifactID = "layout_abcdef0123456789"
    private let sourceSHA = String(repeating: "a", count: 64)
    private let evidenceSHA = String(repeating: "b", count: 64)
    private let revisionSHA = "sha256:" + String(repeating: "c", count: 64)

    func testValidResultProjectsBySchemaForArbitraryToolName() throws {
        let tool = makeTool(
            toolName: "future_layout_surface",
            output: validLayout(),
            assets: [overlayAsset, layoutJSONAsset]
        )
        let projected = try project(tool, registerActions: true)
        let layout = try XCTUnwrap(projected.uiLayout)

        XCTAssertEqual(layout.artifactID, artifactID)
        XCTAssertEqual(layout.revision, 3)
        XCTAssertEqual(layout.created, true)
        XCTAssertEqual(layout.nodeCount, 3)
        XCTAssertEqual(layout.assumptionCount, 1)
        XCTAssertEqual(layout.targets, ["duo_folded", "iphone_portrait"])
        XCTAssertEqual(layout.canvasWidth, 200)
        XCTAssertEqual(layout.canvasHeight, 400)
        XCTAssertEqual(layout.evidenceSHA256, evidenceSHA)
        XCTAssertEqual(layout.sourceAssetSHA256, sourceSHA)
        XCTAssertEqual(layout.revisionSHA256, revisionSHA)
        XCTAssertEqual(layout.overlay.assetID, overlayID)
        XCTAssertEqual(layout.overlay.role, "layout_overlay")
        XCTAssertEqual(layout.layoutJSON.assetID, layoutJSONID)
        XCTAssertEqual(layout.layoutJSON.role, "layout_json")
        XCTAssertNotNil(layout.overlay.viewActionID)
        XCTAssertNotNil(layout.layoutJSON.viewActionID)
        XCTAssertNotNil(layout.rawActionID)
        XCTAssertNil(projected.output, "structured layout JSON must not enter the transcript")
        XCTAssertNil(projected.detail)
        XCTAssertNil(projected.imageView)
        XCTAssertNil(projected.uiEvidence)
    }

    func testReusedRevisionIsPresentedAsReused() throws {
        let projected = try project(makeTool(
            toolName: "any",
            output: validLayout(created: false),
            assets: [overlayAsset, layoutJSONAsset]
        ))
        let layout = try XCTUnwrap(projected.uiLayout)
        XCTAssertFalse(layout.created)
        XCTAssertEqual(layout.title, "UI layout: reused revision 3")
    }

    func testToolNameAloneCannotCreateLayout() throws {
        let projected = try project(makeTool(
            toolName: "ui_layout",
            output: .object(["schema": .string("ui_layout_result.v1")]),
            assets: [overlayAsset, layoutJSONAsset]
        ))
        XCTAssertNil(projected.uiLayout)
        XCTAssertNil(projected.uiEvidence)
        XCTAssertNil(projected.imageView)
        XCTAssertEqual(projected.output, "ordinary output")
    }

    func testUnknownSchemaAndUnknownFieldFallBackToOrdinaryOutput() throws {
        var wrongSchema = try XCTUnwrap(validLayout().object)
        wrongSchema["schema"] = .string("ui_layout_result.v2")
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: .object(wrongSchema),
            assets: [overlayAsset, layoutJSONAsset]
        )).uiLayout)

        var unknownField = try XCTUnwrap(validLayout().object)
        unknownField["recommended_component"] = .string("sidebar")
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: .object(unknownField),
            assets: [overlayAsset, layoutJSONAsset]
        )).uiLayout)
    }

    func testBothCanonicalAssetsMustBeRegisteredAndConsistent() throws {
        // Missing either asset falls back.
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: validLayout(),
            assets: [overlayAsset]
        )).uiLayout)
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: validLayout(),
            assets: [layoutJSONAsset]
        )).uiLayout)

        // The layout JSON must stay a file asset, not an image.
        let wrongKind = AgentAssetRef(
            id: layoutJSONID,
            kind: "image",
            displayName: "layout.json",
            workspaceID: "ws_current",
            workspaceRelativePath: layoutPath,
            mimeType: "application/json"
        )
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: validLayout(),
            assets: [overlayAsset, wrongKind]
        )).uiLayout)

        // Metadata must bind to the same revision and source.
        var metadata = try XCTUnwrap(overlayAsset.metadata)
        metadata["layout_revision"] = .integer(2)
        let staleOverlay = AgentAssetRef(
            id: overlayAsset.id,
            kind: "image",
            displayName: overlayAsset.displayName,
            workspaceID: overlayAsset.workspaceID,
            workspaceRelativePath: overlayAsset.workspaceRelativePath,
            mimeType: overlayAsset.mimeType,
            metadata: metadata
        )
        XCTAssertNil(try project(makeTool(
            toolName: "ui_layout",
            output: validLayout(),
            assets: [staleOverlay, layoutJSONAsset]
        )).uiLayout)
    }

    func testImageResolverOnlyExposesOverlay() throws {
        let tool = makeTool(
            toolName: "ui_layout",
            output: validLayout(),
            assets: [overlayAsset, layoutJSONAsset]
        )
        XCTAssertEqual(
            UILayoutActivityProjection.validatedImageAssetIDs(in: tool),
            [overlayID]
        )
        XCTAssertEqual(
            StructuredImageActivityAssets.validatedAssetIDs(in: tool),
            [overlayID]
        )
    }

    func testLiveAndReplayProduceSameLayoutAndRepeatedReplayDoesNotDuplicateBlock() async throws {
        let tool = makeTool(
            toolName: "arbitrary_layout_producer",
            output: validLayout(),
            assets: [overlayAsset, layoutJSONAsset]
        )
        let prefix: [AgentEvent] = [
            .turnStarted(turnID: "turn", text: "layout"),
            .toolStarted(
                turnID: "turn",
                callID: "call_layout",
                tool: ToolCall(callID: "call_layout", toolName: tool.toolName, toolArgs: nil)
            ),
            .toolFinished(turnID: "turn", callID: "call_layout", result: ToolResult(
                callID: "call_layout",
                toolName: tool.toolName,
                observation: tool.output,
                error: nil,
                output: tool.structuredOutput,
                assets: tool.assets
            )),
        ]

        let liveEngine = RuntimeEngine(sessionID: "live")
        for event in prefix { await liveEngine.ingest(event) }
        let liveDocument = ConversationWebDocumentBuilder.build(
            snapshot: await liveEngine.currentSnapshot(),
            conversationID: "live"
        )
        let liveLayout = try XCTUnwrap(
            liveDocument.turns.first?.blocks.first?.tools.first?.uiLayout
        )

        let replayEngine = RuntimeEngine(sessionID: "replay")
        await replayEngine.importHistory(prefix + [
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
        let replayLayout = try XCTUnwrap(
            firstReplay.turns.first?.blocks.first?.tools.first?.uiLayout
        )
        XCTAssertEqual(liveLayout, replayLayout)

        let firstBlocks = firstReplay.turns.first?.blocks.flatMap(\.tools).filter {
            $0.uiLayout != nil
        } ?? []
        let secondBlocks = secondReplay.turns.first?.blocks.flatMap(\.tools).filter {
            $0.uiLayout != nil
        } ?? []
        XCTAssertEqual(firstBlocks.count, 1)
        XCTAssertEqual(secondBlocks.count, 1)
        XCTAssertEqual(firstBlocks, secondBlocks)
    }

    func testActionsRouteByStableIdentity() throws {
        var actions: [String: ConversationWebAction] = [:]
        var index = 0
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(
                id: "group",
                tools: [makeTool(
                    callID: "call_layout",
                    toolName: "ui_layout",
                    output: validLayout(),
                    assets: [overlayAsset, layoutJSONAsset]
                )]
            ))],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "actions",
            registerAction: { action in
                index += 1
                let token = "action_\(index)"
                actions[token] = action
                return token
            }
        )
        let layout = try XCTUnwrap(
            document.turns.first?.blocks.first?.tools.first?.uiLayout
        )

        let rawAction = try XCTUnwrap(layout.rawActionID.flatMap { actions[$0] })
        guard case .transcript(let turnID, let transcriptAction) = rawAction else {
            return XCTFail("Expected transcript action")
        }
        XCTAssertEqual(turnID, "turn")
        if case .openUILayout(let callID) = transcriptAction {
            XCTAssertEqual(callID, "call_layout")
        } else {
            XCTFail("Expected openUILayout action")
        }

        for (expectedID, actionID) in zip(
            [overlayID, layoutJSONID],
            [layout.overlay.viewActionID, layout.layoutJSON.viewActionID].compactMap { $0 }
        ) {
            guard case .transcript(_, .openAsset(let reference)) = try XCTUnwrap(actions[actionID]) else {
                return XCTFail("Expected openAsset action")
            }
            XCTAssertEqual(reference.structuredAsset?.id, expectedID)
        }
    }

    // MARK: - Fixtures

    private var overlayPath: String {
        ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/overlay.png"
    }

    private var layoutPath: String {
        ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/layout.json"
    }

    private var shapeMetadata: [String: JSONValue] {
        [
            "asset_role": .string("layout_overlay"),
            "layout_artifact_id": .string(artifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(revisionSHA),
            "source_asset_id": .string("asset_source_screen"),
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
            workspaceRelativePath: layoutPath,
            mimeType: "application/json",
            sourceCallID: "call_layout",
            metadata: metadata
        )
    }

    private func validLayout(
        created: Bool = true,
        targets: [String] = ["duo_folded", "iphone_portrait"]
    ) -> JSONValue {
        .object([
            "schema": .string("ui_layout_result.v1"),
            "layout_artifact_id": .string(artifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(revisionSHA),
            "source_asset_id": .string("asset_source_screen"),
            "source_asset_sha256": .string(sourceSHA),
            "evidence_sha256": .string(evidenceSHA),
            "canvas": .object([
                "width": .integer(200),
                "height": .integer(400),
            ]),
            "node_count": .integer(3),
            "assumption_count": .integer(1),
            "targets": .array(targets.map(JSONValue.string)),
            "created": .bool(created),
            "overlay_asset": .object([
                "asset_id": .string(overlayID),
                "asset_role": .string("layout_overlay"),
                "kind": .string("image"),
                "relative_path": .string(overlayPath),
                "filename": .string("overlay.png"),
                "mime_type": .string("image/png"),
                "width": .integer(200),
                "height": .integer(400),
                "sha256": .string(String(repeating: "d", count: 64)),
            ]),
            "layout_json_asset": .object([
                "asset_id": .string(layoutJSONID),
                "asset_role": .string("layout_json"),
                "kind": .string("file"),
                "relative_path": .string(layoutPath),
                "filename": .string("layout.json"),
                "mime_type": .string("application/json"),
                "sha256": .string(String(repeating: "c", count: 64)),
            ]),
        ])
    }

    private func makeTool(
        callID: String = "call_layout",
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
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "projection",
            registerAction: registerActions ? { _ in
                index += 1
                return "action_\(index)"
            } : nil
        )
        return try XCTUnwrap(document.turns.first?.blocks.first?.tools.first)
    }
}
