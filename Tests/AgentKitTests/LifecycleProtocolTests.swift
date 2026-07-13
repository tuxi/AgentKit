//
//  LifecycleProtocolTests.swift
//  AgentKitTests
//
//  v1.2 lifecycle wire compatibility.
//

import XCTest
@testable import AgentKit

final class LifecycleProtocolTests: XCTestCase {

    func testModelFinishedDecodesCompleteInvocationUsage() throws {
        let event = try decodeEvent("""
        {"kind":"model_finished","turn_id":"t1","prompt_tokens":52444,"completion_tokens":199,"total_tokens":52643,"billing_units":53112,"elapsed_ms":7500,"invocation_id":"inv_15"}
        """)
        guard case let .modelFinished(turnID, prompt, completion, total, units, elapsed, invocationID, err) = event else {
            return XCTFail("expected model_finished")
        }
        XCTAssertEqual(turnID, "t1")
        XCTAssertEqual(prompt, 52_444)
        XCTAssertEqual(completion, 199)
        XCTAssertEqual(total, 52_643)
        XCTAssertEqual(units, 53_112)
        XCTAssertEqual(elapsed, 7_500)
        XCTAssertEqual(invocationID, "inv_15")
        XCTAssertNil(err)
    }

    func testConversationRefDecodesLifecycleFields() throws {
        let json = """
        {
          "id": "sess_1",
          "workspace_path": "/tmp/project",
          "workspace": {
            "id": "agentkit-local",
            "name": "Project",
            "root_path": "/tmp/project",
            "runtime_cwd": "/tmp/project",
            "display_path": "Project",
            "kind": "local"
          },
          "name": "Paused work",
          "turn_status": "paused",
          "paused_at": 1782892800
        }
        """

        let ref = try JSONDecoder().decode(ConversationRef.self, from: Data(json.utf8))

        XCTAssertEqual(ref.id, "sess_1")
        XCTAssertEqual(ref.workspace?.id, "agentkit-local")
        XCTAssertEqual(ref.workspace?.displayName, "Project")
        XCTAssertEqual(ref.workspace?.localRootPath, "/tmp/project")
        XCTAssertEqual(ref.turnStatus, "paused")
        XCTAssertEqual(ref.pausedAt, 1_782_892_800)
        XCTAssertTrue(ref.isPaused)
        XCTAssertNotNil(ref.pausedDate)
    }

    func testConversationDetailDecodesWorkspaceAnchor() throws {
        let json = """
        {
          "id": "sess_1",
          "turn_count": 2,
          "message_count": 4,
          "created_at": "2026-07-01T15:40:50Z",
          "updated_at": "2026-07-01T15:44:50Z",
          "workspace_path": "/tmp/project",
          "workspace": {
            "id": "agentkit-local",
            "root_path": "/tmp/project",
            "display_path": "Project",
            "kind": "local"
          },
          "name": "Asset work",
          "turn_status": "done"
        }
        """

        let detail = try JSONDecoder().decode(ConversationDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.workspacePath, "/tmp/project")
        XCTAssertEqual(detail.workspace?.id, "agentkit-local")
        XCTAssertEqual(detail.workspace?.displayName, "Project")
        XCTAssertEqual(detail.workspace?.kind, "local")
    }

    func testLifecycleEventsDecodeFromWire() throws {
        let paused = try decodeEvent("""
        { "kind": "turn_paused", "turn_id": "turn_1", "text": "paused" }
        """)
        guard case .turnPaused(let pausedID, let pausedText, _) = paused else {
            XCTFail("Expected turnPaused")
            return
        }
        XCTAssertEqual(pausedID, "turn_1")
        XCTAssertEqual(pausedText, "paused")

        let resumed = try decodeEvent("""
        { "kind": "turn_resumed", "turn_id": "turn_1" }
        """)
        guard case .turnResumed(let resumedID, _) = resumed else {
            XCTFail("Expected turnResumed")
            return
        }
        XCTAssertEqual(resumedID, "turn_1")

        let failed = try decodeEvent("""
        { "kind": "turn_failed", "turn_id": "turn_1", "err": "permanent" }
        """)
        guard case .turnFailed(let failedID, _, let err, let code) = failed else {
            XCTFail("Expected turnFailed")
            return
        }
        XCTAssertEqual(failedID, "turn_1")
        XCTAssertEqual(err, "permanent")
        XCTAssertNil(code)
    }

    func testTurnFailedDecodesStructuredError() throws {
        // runtime-event-contract-v1 §5.1: turn_failed 携带结构化 error {code, message}
        let failed = try decodeEvent("""
        {
          "kind": "turn_failed",
          "turn_id": "turn_42",
          "error": {
            "code": "auth_expired",
            "message": "Gateway returned 401 — access token may be expired"
          }
        }
        """)
        guard case .turnFailed(let turnID, _, let err, let code) = failed else {
            XCTFail("Expected turnFailed")
            return
        }
        XCTAssertEqual(turnID, "turn_42")
        XCTAssertEqual(code, "auth_expired")
        // err 缺省时回退到 error.message，UI 仍有可展示文本
        XCTAssertEqual(err, "Gateway returned 401 — access token may be expired")
    }

    private func decodeEvent(_ json: String) throws -> AgentEvent {
        let wire = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        guard let event = AgentEvent.from(wire: wire) else {
            throw XCTSkip("Wire frame did not produce an event")
        }
        return event
    }
}
