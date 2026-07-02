//
//  AssetAPIResponseTests.swift
//  AgentKitTests
//
//  Runtime Asset API response compatibility.
//

import XCTest
@testable import AgentKit

final class AssetAPIResponseTests: XCTestCase {

    func testAssetPreviewResponseDecodes() throws {
        let json = """
        {
          "kind": "asset_preview",
          "source": "file_window",
          "content": "12\\tlet value = 42",
          "mime_type": "text/x-swift",
          "size_bytes": 4096,
          "truncated": false,
          "asset": {
            "id": "asset_turn_1_call_1_001",
            "kind": "file_location",
            "display_name": "App.swift:12",
            "workspace_relative_path": "Sources/App.swift",
            "range": { "start_line": 12 },
            "source_turn_id": "turn_1",
            "source_call_id": "call_1"
          }
        }
        """

        let response = try JSONDecoder().decode(AgentAssetPreviewResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.kind, "asset_preview")
        XCTAssertEqual(response.source, "file_window")
        XCTAssertEqual(response.content, "12\tlet value = 42")
        XCTAssertEqual(response.mimeType, "text/x-swift")
        XCTAssertEqual(response.sizeBytes, 4096)
        XCTAssertFalse(response.truncated)
        XCTAssertEqual(response.asset.id, "asset_turn_1_call_1_001")
        XCTAssertEqual(response.asset.range?.startLine, 12)
    }

    func testAssetContentResponseDecodes() throws {
        let json = """
        {
          "content": "import SwiftUI",
          "mime_type": "text/x-swift",
          "size_bytes": 1200000,
          "truncated": true,
          "asset": {
            "id": "asset_turn_1_call_1_001",
            "kind": "file",
            "display_name": "App.swift",
            "workspace_relative_path": "Sources/App.swift",
            "source_turn_id": "turn_1",
            "source_call_id": "call_1"
          }
        }
        """

        let response = try JSONDecoder().decode(AgentAssetContentResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.content, "import SwiftUI")
        XCTAssertEqual(response.mimeType, "text/x-swift")
        XCTAssertEqual(response.sizeBytes, 1_200_000)
        XCTAssertTrue(response.truncated)
        XCTAssertEqual(response.asset.workspaceRelativePath, "Sources/App.swift")
    }
}
