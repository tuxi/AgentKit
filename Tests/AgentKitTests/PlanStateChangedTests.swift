//
//  PlanStateChangedTests.swift
//  AgentKitTests
//
//  v1.4 — `plan_state_changed` 事件解码与 RuntimeSnapshot.planState 追踪。
//  前向兼容底线：未知 kind 仍被丢弃（不崩），未知/缺失 plan_state 优雅降级。
//

import XCTest
@testable import AgentKit

final class PlanStateChangedTests: XCTestCase {

    // MARK: - Wire decode

    private func decodeEvent(_ json: String) throws -> AgentEvent? {
        let frame = try JSONDecoder().decode(WireFrame.self, from: Data(json.utf8))
        return AgentEvent.from(wire: frame)
    }

    func testDecodePlanStateChanged() throws {
        let event = try decodeEvent(
            #"{"kind":"plan_state_changed","plan_state":"planning"}"#
        )
        guard case .planStateChanged(let planState)? = event else {
            return XCTFail("expected planStateChanged, got \(String(describing: event))")
        }
        XCTAssertEqual(planState, .planning)
    }

    func testDecodeAllKnownPlanStates() throws {
        let cases: [(String, PlanState)] = [
            ("none", .none),
            ("planning", .planning),
            ("proposing", .proposing),
            ("approved", .approved),
            ("rejected", .rejected),
            ("executing", .executing),
        ]
        for (raw, expected) in cases {
            let event = try decodeEvent(
                #"{"kind":"plan_state_changed","plan_state":"\#(raw)"}"#
            )
            guard case .planStateChanged(let planState)? = event else {
                return XCTFail("expected planStateChanged for \(raw)")
            }
            XCTAssertEqual(planState, expected, "plan_state=\(raw)")
        }
    }

    // 缺失/未知 plan_state 优雅降级，解码永不失败（前向兼容）。
    func testDecodeMissingAndUnknownPlanStateGraceful() throws {
        // 缺失 plan_state 字段 → .none
        let missing = try decodeEvent(#"{"kind":"plan_state_changed"}"#)
        guard case .planStateChanged(let missingState)? = missing else {
            return XCTFail("expected planStateChanged even without plan_state field")
        }
        XCTAssertEqual(missingState, .none)

        // 未知值 → .unknown(rawValue)，原样保留
        let future = try decodeEvent(
            #"{"kind":"plan_state_changed","plan_state":"future_state"}"#
        )
        guard case .planStateChanged(let futureState)? = future else {
            return XCTFail("expected planStateChanged for unknown plan_state")
        }
        XCTAssertEqual(futureState, .unknown("future_state"))
    }

    // 前向兼容底线：未知 kind 仍被丢弃，不崩（client_integration_v1.md §5.5）。
    func testUnknownKindStillDropped() throws {
        let event = try decodeEvent(
            #"{"kind":"plan_state_future_unknown","plan_state":"planning"}"#
        )
        XCTAssertNil(event)
    }

    // MARK: - RuntimeSnapshot tracking

    func testRuntimeEngineTracksPlanState() async throws {
        let engine = RuntimeEngine(sessionID: "s1")

        await engine.ingest(.planStateChanged(planState: .planning))
        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.planState, .planning)

        await engine.ingest(.planStateChanged(planState: .approved))
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.planState, .approved)

        // 空快照默认 .none
        let empty = RuntimeSnapshot.empty(sessionID: "s1")
        XCTAssertEqual(empty.planState, .none)
    }
}
