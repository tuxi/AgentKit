//
//  ImageViewActivityTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit

@MainActor
final class ImageViewActivityTests: XCTestCase {
    func testSourceOnlyUsesStructuredSemanticWithoutToolNameBranching() throws {
        let tool = makeTool(
            toolName: "arbitrary_image_surface",
            output: sourceOnlyOutput(),
            assets: [sourceAsset]
        )
        let webTool = try project(tool)

        let imageView = try XCTUnwrap(webTool.imageView)
        XCTAssertEqual(imageView.title, "Viewed image screen.png")
        XCTAssertEqual(imageView.sourceAssetID, sourceID)
        XCTAssertNil(imageView.cropAssetID)
        XCTAssertNil(imageView.sourceRegion)
        XCTAssertEqual(imageView.assets.map(\.assetID), [sourceID])
        XCTAssertEqual(imageView.assets.map(\.role), ["source"])
        XCTAssertEqual(imageView.detailRequested, "high")
        XCTAssertEqual(imageView.detailEffective, "high")
        XCTAssertNil(webTool.output, "structured image metadata is not forced into the transcript")
    }

    func testToolNameAloneCannotCreateImageViewActivity() throws {
        let tool = makeTool(
            toolName: "view_image",
            output: .object(["kind": .string("plain_text")]),
            assets: [sourceAsset]
        )
        let webTool = try project(tool)

        XCTAssertNil(webTool.imageView)
        XCTAssertEqual(webTool.name, ToolTranscriptPresenter.presentation(for: tool).title)
    }

    func testSourceAndCropKeepSourcePrimaryAndCropLinkedByAssetID() throws {
        let tool = makeTool(
            toolName: "some_future_image_tool",
            output: sourceAndCropOutput(),
            assets: [cropAsset, sourceAsset] // intentionally not output order
        )
        let webTool = try project(tool, registerAction: true)

        let imageView = try XCTUnwrap(webTool.imageView)
        XCTAssertEqual(imageView.title, "Viewed image screen.png")
        XCTAssertEqual(imageView.sourceAssetID, sourceID)
        XCTAssertEqual(imageView.cropAssetID, cropID)
        XCTAssertEqual(imageView.assets.map(\.assetID), [sourceID, cropID])
        XCTAssertEqual(imageView.assets.map(\.role), ["source", "crop"])
        XCTAssertEqual(imageView.assets[1].sourceAssetID, sourceID)
        XCTAssertEqual(imageView.sourceRegion, imageView.assets[1].sourceRegion)
        XCTAssertNotNil(imageView.assets[0].viewActionID)
        XCTAssertNotNil(imageView.assets[1].viewActionID)
        XCTAssertNotEqual(imageView.assets[0].viewActionID, imageView.assets[1].viewActionID)
    }

    func testMultipleImageActivitiesPreserveToolAndAssetOrder() throws {
        let first = makeTool(
            callID: "call_first",
            toolName: "image_surface_one",
            output: sourceAndCropOutput(),
            assets: [cropAsset, sourceAsset]
        )
        let second = makeTool(
            callID: "call_second",
            toolName: "image_surface_two",
            output: sourceOnlyOutput(assetID: "asset_second", filename: "second.png"),
            assets: [
                AgentAssetRef(
                    id: "asset_second",
                    kind: "image",
                    displayName: "second.png",
                    workspaceRelativePath: "images/second.png",
                    mimeType: "image/png"
                )
            ]
        )
        let group = ToolGroup(id: "images", tools: [first, second])
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(group)],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "images"
        )
        let tools = document.turns[0].blocks[0].tools

        XCTAssertEqual(tools.map(\.id), ["call_first", "call_second"])
        XCTAssertEqual(tools[0].imageView?.assets.map(\.assetID), [sourceID, cropID])
        XCTAssertEqual(tools[1].imageView?.assets.map(\.assetID), ["asset_second"])
    }

    func testLiveAndReplayProjectTheSameImageRelationship() async throws {
        let events: [AgentEvent] = [
            .turnStarted(turnID: "turn", text: "look"),
            .toolStarted(
                turnID: "turn",
                callID: "call",
                tool: ToolCall(callID: "call", toolName: "generic_image_tool", toolArgs: nil)
            ),
            .toolFinished(
                turnID: "turn",
                callID: "call",
                result: ToolResult(
                    callID: "call",
                    toolName: "generic_image_tool",
                    observation: "viewed",
                    error: nil,
                    output: sourceAndCropOutput(),
                    assets: [cropAsset, sourceAsset]
                )
            )
        ]

        let liveEngine = RuntimeEngine(sessionID: "live")
        for event in events {
            await liveEngine.ingest(event)
        }
        let liveSnapshot = await liveEngine.currentSnapshot()
        let live = ConversationWebDocumentBuilder.build(
            snapshot: liveSnapshot,
            conversationID: "live"
        ).turns[0].blocks[0].tools[0].imageView

        let replayEngine = RuntimeEngine(sessionID: "replay")
        await replayEngine.importHistory(events + [
            .turnFinished(turnID: "turn", text: "done", textAnnotations: [])
        ])
        let replaySnapshot = await replayEngine.currentSnapshot()
        let replay = ConversationWebDocumentBuilder.build(
            snapshot: replaySnapshot,
            conversationID: "replay"
        ).turns[0].blocks[0].tools[0].imageView

        XCTAssertEqual(live, replay)
        XCTAssertEqual(replay?.assets.map(\.assetID), [sourceID, cropID])
        XCTAssertEqual(replay?.assets[1].sourceAssetID, sourceID)
    }

    func testMalformedAndMissingMetadataFallsBackToGenericTool() throws {
        let malformed = makeTool(
            toolName: "image_surface",
            output: .object([
                "schema": .string("view_image_result.v1"),
                "kind": .string("image_view"),
                "source_asset_id": .string(sourceID),
                "crop_asset_id": .string(cropID),
                "assets": .array([
                    sourceAssetJSON(),
                    cropAssetJSON()
                ]),
                "detail_requested": .string("high"),
                "detail_effective": .string("high"),
                "source_region": .null
            ]),
            assets: [sourceAsset, cropAsset]
        )
        XCTAssertNil(try project(malformed).imageView)

        let missingAsset = makeTool(
            toolName: "image_surface",
            output: sourceAndCropOutput(),
            assets: [sourceAsset]
        )
        XCTAssertNil(try project(missingAsset).imageView)

        let nonImageAsset = AgentAssetRef(
            id: sourceID,
            kind: "file",
            displayName: "screen.png",
            workspaceRelativePath: "images/screen.png",
            mimeType: "text/plain"
        )
        let wrongAssetKind = makeTool(
            toolName: "image_surface",
            output: sourceOnlyOutput(),
            assets: [nonImageAsset]
        )
        XCTAssertNil(try project(wrongAssetKind).imageView)
    }

    func testProjectionEncodesSemanticDataWithoutImageHTML() throws {
        let webTool = try project(makeTool(
            toolName: "generic_image_tool",
            output: sourceAndCropOutput(),
            assets: [sourceAsset, cropAsset]
        ))
        let data = try JSONEncoder().encode(webTool)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"imageView\""))
        XCTAssertTrue(json.contains(sourceID))
        XCTAssertTrue(json.contains(cropID))
        XCTAssertFalse(json.lowercased().contains("<img"))
        XCTAssertFalse(json.lowercased().contains("<figure"))
    }

    // MARK: - Fixtures and helpers

    private let sourceID = "asset_source_001"
    private let cropID = "asset_crop_001"

    private var sourceAsset: AgentAssetRef {
        AgentAssetRef(
            id: sourceID,
            kind: "image",
            displayName: "screen.png",
            workspaceRelativePath: "images/screen.png",
            mimeType: "image/png"
        )
    }

    private var cropAsset: AgentAssetRef {
        AgentAssetRef(
            id: cropID,
            kind: "image",
            displayName: "screen-crop.png",
            workspaceRelativePath: "images/screen-crop.png",
            mimeType: "image/png"
        )
    }

    private func makeTool(
        callID: String = "call_image",
        toolName: String,
        output: JSONValue,
        assets: [AgentAssetRef]
    ) -> ToolNodePayload {
        ToolNodePayload(
            callID: callID,
            toolName: toolName,
            args: nil,
            status: .completed,
            output: "structured image result",
            structuredOutput: output,
            assets: assets
        )
    }

    private func project(
        _ tool: ToolNodePayload,
        registerAction: Bool = false
    ) throws -> ConversationWebDocument.Tool {
        let group = ToolGroup(id: "images", tools: [tool])
        let turn = ConversationTurn(
            id: "turn",
            userPrompt: nil,
            blocks: [.toolGroup(group)],
            footer: nil,
            isLive: false
        )
        var actionIndex = 0
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "images",
            registerAction: registerAction ? { _ in
                actionIndex += 1
                return "action_\(actionIndex)"
            } : nil
        )
        return try XCTUnwrap(document.turns.first?.blocks.first?.tools.first)
    }

    private func sourceOnlyOutput(
        assetID: String = "asset_source_001",
        filename: String = "screen.png"
    ) -> JSONValue {
        .object([
            "schema": .string("view_image_result.v1"),
            "kind": .string("image_view"),
            "source_asset_id": .string(assetID),
            "crop_asset_id": .null,
            "assets": .array([
                sourceAssetJSON(assetID: assetID, filename: filename)
            ]),
            "detail_requested": .string("high"),
            "detail_effective": .string("high"),
            "source_region": .null
        ])
    }

    private func sourceAndCropOutput() -> JSONValue {
        let bbox: JSONValue = .object([
            "x": .number(0.1),
            "y": .number(0.2),
            "width": .number(0.5),
            "height": .number(0.4)
        ])
        return .object([
            "schema": .string("view_image_result.v1"),
            "kind": .string("image_view"),
            "source_asset_id": .string(sourceID),
            "crop_asset_id": .string(cropID),
            "assets": .array([
                sourceAssetJSON(),
                cropAssetJSON(bbox: bbox)
            ]),
            "detail_requested": .string("original"),
            "detail_effective": .string("original"),
            "source_region": bbox
        ])
    }

    private func sourceAssetJSON(
        assetID: String = "asset_source_001",
        filename: String = "screen.png"
    ) -> JSONValue {
        .object([
            "asset_id": .string(assetID),
            "role": .string("source"),
            "asset_role": .string("source"),
            "relative_path": .string("images/\(filename)"),
            "filename": .string(filename),
            "mime_type": .string("image/png"),
            "width": .integer(640),
            "height": .integer(400),
            "sha256": .string(String(repeating: "a", count: 64))
        ])
    }

    private func cropAssetJSON(bbox: JSONValue? = nil) -> JSONValue {
        let region = bbox ?? .object([
            "x": .number(0.1),
            "y": .number(0.2),
            "width": .number(0.5),
            "height": .number(0.4)
        ])
        return .object([
            "asset_id": .string(cropID),
            "role": .string("crop"),
            "asset_role": .string("crop"),
            "relative_path": .string("images/screen-crop.png"),
            "filename": .string("screen-crop.png"),
            "mime_type": .string("image/png"),
            "width": .integer(320),
            "height": .integer(160),
            "sha256": .string(String(repeating: "b", count: 64)),
            "source_asset_id": .string(sourceID),
            "source_bbox": region,
            "purpose": .string("detail")
        ])
    }
}
