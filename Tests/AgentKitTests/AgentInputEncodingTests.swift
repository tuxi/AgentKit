//
//  AgentInputEncodingTests.swift
//  AgentKitTests
//
//  Verifies client tool_result structured side-channel encoding.
//

import XCTest
@testable import AgentKit

final class AgentInputEncodingTests: XCTestCase {

    func testToolResultInputEncodesStructuredOutputAndAssets() throws {
        let asset = AgentAssetRef(
            id: "asset_call_1_001_abcdef12",
            kind: "file_location",
            uri: "workspace://agentkit-local/Sources/App.swift#L12",
            displayName: "App.swift:12",
            workspaceRelativePath: "Sources/App.swift",
            range: AgentAssetRange(startLine: 12, startColumn: 3),
            preview: "let value = 42",
            mimeType: "text/x-swift",
            sourceCallID: "call_1"
        )
        let input = AgentInput.toolResult(ToolResultContent(
            toolUseID: "call_1",
            content: "[observation] ok",
            output: .object([
                "kind": .string("file"),
                "asset_id": .string(asset.id)
            ]),
            assets: [asset]
        ))

        let data = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let toolResult = try XCTUnwrap(object["tool_result"] as? [String: Any])
        let output = try XCTUnwrap(toolResult["output"] as? [String: Any])
        let assets = try XCTUnwrap(toolResult["assets"] as? [[String: Any]])
        let firstAsset = try XCTUnwrap(assets.first)
        let range = try XCTUnwrap(firstAsset["range"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "agent_input")
        XCTAssertEqual(object["kind"] as? String, "tool_result")
        XCTAssertEqual(toolResult["tool_use_id"] as? String, "call_1")
        XCTAssertEqual(toolResult["content"] as? String, "[observation] ok")
        XCTAssertEqual(toolResult["is_error"] as? Bool, false)
        XCTAssertEqual(output["kind"] as? String, "file")
        XCTAssertEqual(firstAsset["id"] as? String, "asset_call_1_001_abcdef12")
        XCTAssertEqual(firstAsset["workspace_relative_path"] as? String, "Sources/App.swift")
        XCTAssertNil(firstAsset["source_turn_id"])
        XCTAssertEqual(firstAsset["source_call_id"] as? String, "call_1")
        XCTAssertEqual(range["start_line"] as? Int, 12)
        XCTAssertEqual(range["start_column"] as? Int, 3)
    }

    func testStructuredClientToolCanReturnAssets() async throws {
        let tool = LocalFileTool()
        let result = try await tool.executeResult(args: nil)
        let bridgedText = try await tool.execute(args: nil)

        XCTAssertEqual(result.content, "Read Sources/App.swift")
        XCTAssertEqual(result.output?["kind"].stringValue, "file")
        XCTAssertEqual(result.assets.first?.workspaceRelativePath, "Sources/App.swift")
        XCTAssertEqual(bridgedText, result.content)
    }

    func testTextTurnCarriesStableClientRequestID() throws {
        let input = AgentInput.text("hello", model: "test-model")
        let data = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(input.requestID)
        XCTAssertEqual(object["request_id"] as? String, input.requestID)
    }

    func testConversationCreationEncodesExecutionPolicyIdentity() throws {
        let request = CreateConversationRequest(
            workspacePath: "/worktrees/task-42",
            workspaceExtID: "bookmark-1",
            executionPolicy: .isolatedWorktree,
            workspaceID: "worktree-42",
            baseWorkspaceID: "repo-main"
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["workspace_path"] as? String, "/worktrees/task-42")
        XCTAssertEqual(object["workspace_ext_id"] as? String, "bookmark-1")
        XCTAssertEqual(object["execution_policy"] as? String, "isolated_worktree")
        XCTAssertEqual(object["workspace_id"] as? String, "worktree-42")
        XCTAssertEqual(object["base_workspace_id"] as? String, "repo-main")
    }
}

private struct LocalFileTool: StructuredClientTool {
    let name = "local_file"
    let description = "Returns a local file asset"

    func executeResult(args: JSONValue?) async throws -> ClientToolExecutionResult {
        let asset = AgentAssetRef(
            id: "asset_local_file_001",
            kind: "file",
            displayName: "App.swift",
            workspaceRelativePath: "Sources/App.swift",
            preview: "import SwiftUI",
            mimeType: "text/x-swift"
        )
        return ClientToolExecutionResult(
            content: "Read Sources/App.swift",
            output: .object([
                "kind": .string("file"),
                "asset_id": .string(asset.id)
            ]),
            assets: [asset]
        )
    }
}
