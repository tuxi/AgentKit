//
//  ImageViewActivityTests.swift
//  AgentKitTests
//

import CryptoKit
import XCTest
import SwiftUI
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

    func testCodeAgentSourceOnlyWireFixtureLiveReplayAndActionTarget() async throws {
        let fixture = try loadCodeAgentFixture("source-only.wire.json")
        let output = try XCTUnwrap(fixture.result.output)
        let sourceAssetID = try XCTUnwrap(output["source_asset_id"].string)

        let (live, replay) = try await projectCodeAgentFixtureLiveAndReplay(fixture)
        XCTAssertEqual(live, replay)
        let imageView = try XCTUnwrap(replay.imageView)
        XCTAssertEqual(imageView.title, "Viewed image screen.png")
        XCTAssertEqual(imageView.assets.map(\.assetID), [sourceAssetID])
        XCTAssertEqual(imageView.assets.map(\.role), ["source"])
        XCTAssertNil(imageView.cropAssetID)

        let (actions, actionImageView) = try await projectCodeAgentFixtureActions(fixture)
        try await assertImageActionOpensAsset(
            actions[try XCTUnwrap(actionImageView.assets[0].viewActionID)],
            expectedAssetID: sourceAssetID
        )
    }

    func testCodeAgentSourceCropWireFixtureLiveReplayAndActionTargets() async throws {
        let fixture = try loadCodeAgentFixture("source-and-crop.wire.json")
        let output = try XCTUnwrap(fixture.result.output)
        let sourceAssetID = try XCTUnwrap(output["source_asset_id"].string)
        let cropAssetID = try XCTUnwrap(output["crop_asset_id"].string)

        let (live, replay) = try await projectCodeAgentFixtureLiveAndReplay(fixture)
        XCTAssertEqual(live, replay)
        XCTAssertEqual(replay.imageView?.assets.map(\.assetID), [sourceAssetID, cropAssetID])
        XCTAssertEqual(replay.imageView?.assets.map(\.role), ["source", "crop"])
        XCTAssertEqual(replay.imageView?.cropAssetID, cropAssetID)
        XCTAssertEqual(replay.imageView?.assets[1].sourceAssetID, sourceAssetID)
        XCTAssertEqual(replay.imageView?.sourceRegion, replay.imageView?.assets[1].sourceRegion)
        XCTAssertEqual(fixture.result.assets.map(\.id), [sourceAssetID, cropAssetID])

        let (actions, actionImageView) = try await projectCodeAgentFixtureActions(fixture)
        try await assertImageActionOpensAsset(
            actions[try XCTUnwrap(actionImageView.assets[0].viewActionID)],
            expectedAssetID: sourceAssetID
        )
        try await assertImageActionOpensAsset(
            actions[try XCTUnwrap(actionImageView.assets[1].viewActionID)],
            expectedAssetID: cropAssetID
        )
    }

    func testCodeAgentFixtureAssetBytesMatchRecordedSHA256() throws {
        let workspace = codeAgentFixtureRoot().appendingPathComponent("workspace", isDirectory: true)
        for name in ["source-only.wire.json", "source-and-crop.wire.json"] {
            let fixture = try loadCodeAgentFixture(name)
            for asset in fixture.result.assets {
                let relativePath = try XCTUnwrap(asset.workspaceRelativePath)
                let recordedSHA = try XCTUnwrap(
                    fixture.result.output?["assets"].array?
                        .first(where: { $0["asset_id"].string == asset.id })?["sha256"].string
                )
                let data = try Data(contentsOf: workspace.appendingPathComponent(relativePath))
                let actualSHA = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                XCTAssertEqual(actualSHA, recordedSHA, "\(asset.id) fixture bytes drifted")
            }
        }
    }

    func testCodeAgentRealOutputDoesNotRequireViewImageToolName() throws {
        let fixture = try loadCodeAgentFixture("source-and-crop.wire.json")
        let tool = ToolNodePayload(
            callID: fixture.callID,
            toolName: "renamed_image_surface",
            args: nil,
            status: .completed,
            output: fixture.result.observation ?? "",
            structuredOutput: fixture.result.output,
            assets: fixture.result.assets
        )
        let webTool = try project(tool)
        XCTAssertEqual(webTool.imageView?.assets.count, 2)
        XCTAssertEqual(webTool.imageView?.assets[1].sourceAssetID, webTool.imageView?.sourceAssetID)
    }

    func testCodeAgentMalformedRealMetadataFallsBackSafely() async throws {
        let data = try codeAgentFixtureData("source-and-crop.wire.json")
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var output = try XCTUnwrap(root["output"] as? [String: Any])
        var assets = try XCTUnwrap(output["assets"] as? [[String: Any]])
        var crop = assets[1]
        crop["source_asset_id"] = "asset_wrong_source"
        assets[1] = crop
        output["assets"] = assets
        root["output"] = output
        let malformedData = try JSONSerialization.data(withJSONObject: root)

        let wire = try JSONDecoder().decode(WireFrame.self, from: malformedData)
        guard case .toolFinished(let rawTurnID, let callID, let result) = AgentEvent.from(wire: wire),
              let turnID = rawTurnID else {
            return XCTFail("Expected tool_finished fixture")
        }
        let engine = RuntimeEngine(sessionID: "malformed-image-view")
        await engine.importHistory([
            .turnStarted(turnID: turnID, text: "inspect"),
            .toolStarted(
                turnID: turnID,
                callID: callID,
                tool: ToolCall(callID: callID, toolName: result.toolName, toolArgs: nil)
            ),
            .toolFinished(turnID: turnID, callID: callID, result: result),
            .turnFinished(turnID: turnID, text: "done", textAnnotations: [])
        ])
        let snapshot = await engine.currentSnapshot()
        let webTool = try XCTUnwrap(
            ConversationWebDocumentBuilder.build(
                snapshot: snapshot,
                conversationID: "malformed-image-view"
            ).turns.first?.blocks.first?.tools.first
        )
        XCTAssertNil(webTool.imageView)
        XCTAssertFalse(webTool.name.hasPrefix("Viewed image"))
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

    // MARK: - Real code-agent fixture helpers

    private struct DecodedCodeAgentFixture {
        let turnID: String
        let callID: String
        let result: ToolResult
    }

    private func codeAgentFixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/view-image/code-agent-80329b1", isDirectory: true)
    }

    private func codeAgentFixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: codeAgentFixtureRoot().appendingPathComponent(name))
    }

    private func loadCodeAgentFixture(_ name: String) throws -> DecodedCodeAgentFixture {
        let wire = try JSONDecoder().decode(WireFrame.self, from: codeAgentFixtureData(name))
        guard case .toolFinished(let rawTurnID, let callID, let result) = AgentEvent.from(wire: wire),
              let turnID = rawTurnID else {
            throw NSError(domain: "ImageViewActivityTests", code: 1)
        }
        return DecodedCodeAgentFixture(turnID: turnID, callID: callID, result: result)
    }

    private func projectCodeAgentFixtureLiveAndReplay(
        _ fixture: DecodedCodeAgentFixture
    ) async throws -> (live: ConversationWebDocument.Tool, replay: ConversationWebDocument.Tool) {
        let prefix: [AgentEvent] = [
            .turnStarted(turnID: fixture.turnID, text: "inspect"),
            .toolStarted(
                turnID: fixture.turnID,
                callID: fixture.callID,
                tool: ToolCall(
                    callID: fixture.callID,
                    toolName: fixture.result.toolName,
                    toolArgs: nil
                )
            ),
            .toolFinished(
                turnID: fixture.turnID,
                callID: fixture.callID,
                result: fixture.result
            )
        ]

        let liveEngine = RuntimeEngine(sessionID: "real-live")
        for event in prefix {
            await liveEngine.ingest(event)
        }
        let liveSnapshot = await liveEngine.currentSnapshot()
        let live = try XCTUnwrap(
            ConversationWebDocumentBuilder.build(
                snapshot: liveSnapshot,
                conversationID: "real-live"
            ).turns.first?.blocks.first?.tools.first
        )

        let replayEngine = RuntimeEngine(sessionID: "real-replay")
        await replayEngine.importHistory(prefix + [
            .turnFinished(
                turnID: fixture.turnID,
                text: "done",
                textAnnotations: []
            )
        ])
        let replaySnapshot = await replayEngine.currentSnapshot()
        let replay = try XCTUnwrap(
            ConversationWebDocumentBuilder.build(
                snapshot: replaySnapshot,
                conversationID: "real-replay"
            ).turns.first?.blocks.first?.tools.first
        )
        return (live, replay)
    }

    private func projectCodeAgentFixtureActions(
        _ fixture: DecodedCodeAgentFixture
    ) async throws -> (actions: [String: ConversationWebAction], imageView: ConversationWebDocument.ImageView) {
        let engine = RuntimeEngine(sessionID: "real-actions")
        await engine.importHistory([
            .turnStarted(turnID: fixture.turnID, text: "inspect"),
            .toolStarted(
                turnID: fixture.turnID,
                callID: fixture.callID,
                tool: ToolCall(
                    callID: fixture.callID,
                    toolName: fixture.result.toolName,
                    toolArgs: nil
                )
            ),
            .toolFinished(
                turnID: fixture.turnID,
                callID: fixture.callID,
                result: fixture.result
            ),
            .turnFinished(
                turnID: fixture.turnID,
                text: "done",
                textAnnotations: []
            )
        ])
        let snapshot = await engine.currentSnapshot()
        var actions: [String: ConversationWebAction] = [:]
        var nextAction = 0
        let document = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "real-actions",
            registerAction: { action in
                nextAction += 1
                let token = "action_\(nextAction)"
                actions[token] = action
                return token
            }
        )
        let imageView = try XCTUnwrap(
            document.turns.first?.blocks.first?.tools.first?.imageView
        )
        return (actions, imageView)
    }

    private func assertImageActionOpensAsset(
        _ action: ConversationWebAction?,
        expectedAssetID: String
    ) async throws {
        guard case .transcript(_, let transcriptAction) = try XCTUnwrap(action),
              case .openAsset(let reference) = transcriptAction,
              let asset = reference.structuredAsset else {
            return XCTFail("Expected an openAsset action")
        }
        XCTAssertEqual(asset.id, expectedAssetID)

        let fixture = try loadCodeAgentFixture("source-and-crop.wire.json")
        let engine = RuntimeEngine(sessionID: "real-action-dispatch")
        await engine.importHistory([
            .turnStarted(turnID: fixture.turnID, text: "inspect"),
            .toolFinished(
                turnID: fixture.turnID,
                callID: fixture.callID,
                result: fixture.result
            ),
            .turnFinished(
                turnID: fixture.turnID,
                text: "done",
                textAnnotations: []
            )
        ])
        let snapshot = await engine.currentSnapshot()
        let turn = try XCTUnwrap(snapshot.turns.first)
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let dispatcher = TurnActionDispatcher(
            turn: turn,
            store: store,
            openURL: OpenURLAction { _ in .handled }
        )
        dispatcher.handle(.openAsset(reference))
        guard case .asset(let payload) = store.inspectorSelection else {
            return XCTFail("Expected asset Inspector selection")
        }
        XCTAssertEqual(payload.asset.id, expectedAssetID)
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
