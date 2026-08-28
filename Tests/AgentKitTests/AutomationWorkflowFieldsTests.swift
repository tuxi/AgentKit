import Foundation
import XCTest
@testable import AgentKit

// MARK: - Automation workflow_ref fields (P3)

final class AutomationWorkflowFieldsTests: XCTestCase {

    /// 解码：GET /v1/automations 返回 workflow_ref/workflow_input/overlap_policy。
    func testDecodeWorkflowFields() throws {
        let json = """
        {
            "id": "auto-1", "name": "trading", "prompt": "",
            "status": "ACTIVE", "schedule_type": "recurring", "timezone": "Asia/Shanghai",
            "mode_exec": "standalone",
            "workflow_ref": "/Users/me/code-agent#trading-strategy-engine",
            "workflow_input": {"instId": "BTC-USDT-SWAP"},
            "overlap_policy": "allow_all",
            "run_count": 0, "created_at": "2026-08-27T00:00:00Z", "updated_at": "2026-08-27T00:00:00Z"
        }
        """
        let automation = try JSONDecoder().decode(Automation.self, from: Data(json.utf8))
        XCTAssertEqual(automation.workflowRef, "/Users/me/code-agent#trading-strategy-engine")
        XCTAssertEqual(automation.workflowInput?["instId"].string, "BTC-USDT-SWAP")
        XCTAssertEqual(automation.overlapPolicy, "allow_all")
    }

    /// 缺省：老 DTO 不含三字段 → nil 且不崩溃。
    func testDecodeWithoutWorkflowFields() throws {
        let json = """
        {"id": "auto-2", "name": "digest", "prompt": "p", "status": "ACTIVE",
         "schedule_type": "recurring", "timezone": "Asia/Shanghai", "mode_exec": "standalone",
         "run_count": 0, "created_at": "2026-08-27T00:00:00Z", "updated_at": "2026-08-27T00:00:00Z"}
        """
        let automation = try JSONDecoder().decode(Automation.self, from: Data(json.utf8))
        XCTAssertNil(automation.workflowRef)
        XCTAssertNil(automation.workflowInput)
        XCTAssertNil(automation.overlapPolicy)
    }

    /// 编码：POST/PATCH body 用 snake_case 键，nil 字段省略。
    func testEncodeCreateRequestWorkflowFields() throws {
        let request = AutomationCreateRequest(
            name: "trading",
            prompt: "",
            scheduleType: .recurring,
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
            timezone: "Asia/Shanghai",
            workflowRef: "/Users/me/code-agent#trading-strategy-engine",
            workflowInput: ["instId": "BTC-USDT-SWAP"],
            overlapPolicy: "skip"
        )
        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["workflow_ref"] as? String, "/Users/me/code-agent#trading-strategy-engine")
        XCTAssertEqual(obj["overlap_policy"] as? String, "skip")
        let input = try XCTUnwrap(obj["workflow_input"] as? [String: String])
        XCTAssertEqual(input["instId"], "BTC-USDT-SWAP")
    }

    /// 对话模式：workflow 字段 nil → 编码时省略。
    func testEncodeConversationOmitsWorkflowFields() throws {
        let request = AutomationCreateRequest(
            name: "digest", prompt: "每日行情", scheduleType: .recurring,
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone: "Asia/Shanghai"
        )
        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["workflow_ref"])
        XCTAssertNil(obj["workflow_input"])
        XCTAssertNil(obj["overlap_policy"])
    }

    /// 编辑回显：Automation → PatchRequest 往返保留三字段。
    func testPatchRoundTripWorkflowFields() throws {
        let automation = Automation(
            id: "auto-1", name: "trading", prompt: "",
            status: .active, scheduleType: .recurring,
            rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timezone: "Asia/Shanghai",
            modeExec: .standalone, createdAt: "2026-08-27T00:00:00Z",
            updatedAt: "2026-08-27T00:00:00Z",
            workflowRef: "/Users/me/code-agent#trading-strategy-engine",
            workflowInput: ["instId": "BTC-USDT-SWAP"],
            overlapPolicy: "skip"
        )
        let patch = AutomationPatchRequest(
            workflowRef: automation.workflowRef,
            workflowInput: automation.workflowInput,
            overlapPolicy: automation.overlapPolicy
        )
        let data = try JSONEncoder().encode(patch)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["workflow_ref"] as? String, automation.workflowRef)
        XCTAssertEqual(obj["overlap_policy"] as? String, automation.overlapPolicy)
        let input = try XCTUnwrap(obj["workflow_input"] as? [String: String])
        XCTAssertEqual(input["instId"], "BTC-USDT-SWAP")
    }
}
