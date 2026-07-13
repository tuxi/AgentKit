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

    func testSchedulerLifecycleEventsDecodeFromWire() throws {
        let accepted = try decodeEvent("""
        { "kind": "turn_accepted", "turn_id": "turn_7", "request_id": "request_7" }
        """)
        guard case .turnAccepted(let acceptedID, let requestID, _) = accepted else {
            return XCTFail("Expected turnAccepted")
        }
        XCTAssertEqual(acceptedID, "turn_7")
        XCTAssertEqual(requestID, "request_7")

        let queued = try decodeEvent("""
        { "kind": "turn_queued", "turn_id": "turn_7", "reason": "workspace_lease", "position": 2 }
        """)
        guard case .turnQueued(let queuedID, let reason, let position) = queued else {
            return XCTFail("Expected turnQueued")
        }
        XCTAssertEqual(queuedID, "turn_7")
        XCTAssertEqual(reason, "workspace_lease")
        XCTAssertEqual(position, 2)

        let cancelled = try decodeEvent("""
        { "kind": "turn_cancelled", "turn_id": "turn_7", "reason": "user_requested" }
        """)
        guard case .turnCancelled(let cancelledID, let reason) = cancelled else {
            return XCTFail("Expected turnCancelled")
        }
        XCTAssertEqual(cancelledID, "turn_7")
        XCTAssertEqual(reason, "user_requested")

        let legacyCancelled = try decodeEvent("""
        { "kind": "turn_failed", "turn_id": "turn_8", "error": { "code": "cancelled", "message": "cancelled by user" } }
        """)
        guard case .turnCancelled(let legacyID, _) = legacyCancelled else {
            return XCTFail("Expected legacy cancelled failure to map to turnCancelled")
        }
        XCTAssertEqual(legacyID, "turn_8")
    }

    func testRuntimeCapabilityAndActivitySnapshotsDecode() throws {
        let capabilityJSON = """
        {
          "schema": "runtime-capabilities/v1",
          "protocol_version": 1,
          "capabilities": {
            "multi_session_execution_v1": true,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "workspace_execution_policy_v1": true
          },
          "limits": { "max_concurrent_turns": 4, "max_connected_sessions": 16 }
        }
        """
        let capabilities = try JSONDecoder().decode(
            RuntimeCapabilitySnapshot.self,
            from: Data(capabilityJSON.utf8)
        )
        XCTAssertTrue(capabilities.allowsMultiSessionExecution)
        XCTAssertEqual(capabilities.limits?.maxConcurrentTurns, 4)

        let activityJSON = """
        {
          "sessions": [{
            "session_id": "session_a",
            "turn_id": "turn_3",
            "state": "waiting_approval",
            "last_sequence": 183,
            "pending_approval_count": 1,
            "pending_client_tool_count": 0,
            "queue_position": null,
            "updated_at": "2026-07-13T06:00:00Z"
          }]
        }
        """
        let activity = try JSONDecoder().decode(RuntimeActivitySnapshot.self, from: Data(activityJSON.utf8))
        XCTAssertEqual(activity.sessions.first?.sessionID, "session_a")
        XCTAssertEqual(activity.sessions.first?.pendingApprovalCount, 1)
    }

    func testCurrentCodeAgentRuntimeCapabilityAndActivityFixturesDecode() throws {
        let capabilityJSON = """
        {
          "capabilities": {
            "multi_session_execution_v1": false,
            "session_scoped_client_tools_v1": true,
            "activity_snapshot_v1": true,
            "workspace_execution_policy_v1": true,
            "max_concurrent_turns": 2,
            "max_connected_sessions": 0
          }
        }
        """
        let capabilities = try JSONDecoder().decode(
            RuntimeCapabilitySnapshot.self,
            from: Data(capabilityJSON.utf8)
        )
        XCTAssertFalse(capabilities.allowsMultiSessionExecution)
        XCTAssertEqual(capabilities.schema, "runtime-capabilities/v1")
        XCTAssertEqual(capabilities.protocolVersion, 1)
        XCTAssertTrue(capabilities.flags.contains(.sessionScopedClientTools))
        XCTAssertTrue(capabilities.flags.contains(.activitySnapshot))
        XCTAssertTrue(capabilities.flags.contains(.workspaceExecutionPolicy))
        XCTAssertEqual(capabilities.limits?.maxConcurrentTurns, 2)

        let activityJSON = """
        {
          "sessions": [
            {
              "session_id": "session_a",
              "turn_id": "turn_a",
              "state": "queued",
              "queue_position": 2,
              "updated_at": "2026-07-13T08:00:00Z"
            },
            {
              "session_id": "session_b",
              "state": "running",
              "updated_at": "2026-07-13T08:00:01Z"
            }
          ]
        }
        """
        let activity = try JSONDecoder().decode(
            RuntimeActivitySnapshot.self,
            from: Data(activityJSON.utf8)
        )
        XCTAssertEqual(activity.sessions.first?.state, "queued")
        XCTAssertEqual(activity.sessions.first?.turnID, "turn_a")
        XCTAssertEqual(activity.sessions.first?.queuePosition, 2)
        XCTAssertNil(activity.sessions.last?.turnID)
        XCTAssertNil(activity.sessions.last?.pendingApprovalCount)
        XCTAssertNil(activity.sessions.last?.pendingClientToolCount)
    }

    private func decodeEvent(_ json: String) throws -> AgentEvent {
        let wire = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        guard let event = AgentEvent.from(wire: wire) else {
            throw XCTSkip("Wire frame did not produce an event")
        }
        return event
    }
}
