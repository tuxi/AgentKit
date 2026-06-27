//
//  WireFrame.swift
//  AgentKit
//
//  Raw Codable envelope for agent-wire v1 JSON frames.
//  Internal to Core — never exposed to UI.
//

import Foundation

// MARK: - Raw wire frame

/// 一帧的原始 JSON 结构。所有字段可选；通过 `type` vs `kind` 分流。
/// 对照：`docs/client_integration_v1.md` §3.1、§3.3、§3.4。
struct WireFrame: Decodable {
    // ── 控制帧字段（有 `type`）──
    let type: String?
    let id: String?
    let protocolVersion: Int?
    let server: String?
    let deadlineMs: Int?

    // ── 事件帧字段（有 `kind`）──
    let kind: String?
    let at: String?
    let eventId: String?
    let sessionId: String?
    let parentSessionId: String?
    let turnId: String?
    let callId: String?
    let step: Int?
    let toolName: String?
    let toolArgs: JSONValue?
    let observation: String?
    let failure: String?
    let planId: String?
    let title: String?
    let content: String?
    let skillVersion: String?
    let todos: [WireTodo]?
    let text: String?
    let promptTokens: Int?
    let elapsedMs: Int?
    let beforeTokens: Int?
    let afterTokens: Int?
    let savedTokens: Int?
    let summaryChars: Int?
    let ratio: Double?
    let chunk: String?
    let err: String?

    enum CodingKeys: String, CodingKey {
        case type, kind, at, step, id, server
        case text, observation, failure, err, ratio, todos, chunk
        case eventId = "event_id"
        case sessionId = "session_id"
        case parentSessionId = "parent_session_id"
        case turnId = "turn_id"
        case callId = "call_id"
        case toolName = "tool_name"
        case toolArgs = "tool_args"
        case planId = "plan_id"
        case title, content
        case skillVersion = "skill_version"
        case promptTokens = "prompt_tokens"
        case elapsedMs = "elapsed_ms"
        case beforeTokens = "before_tokens"
        case afterTokens = "after_tokens"
        case savedTokens = "saved_tokens"
        case summaryChars = "summary_chars"
        case protocolVersion = "protocol_version"
        case deadlineMs = "deadline_ms"
    }
}

// MARK: - Wire todo

struct WireTodo: Decodable {
    let content: String
    let activeForm: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case content, status
        case activeForm = "active_form"
    }
}

// MARK: - Outgoing message encodable structs

/// 出站：驱动一个 turn。
struct OutgoingSendMessage: Encodable {
    let type = "send_message"
    let text: String
}

/// 出站：取消当前 turn。
struct OutgoingCancelTurn: Encodable {
    let type = "cancel_turn"
}

/// 出站：审批回复。
struct OutgoingApprovalResponse: Encodable {
    let type = "approval_response"
    let id: String
    let approved: Bool
}

/// 出站：计划审批回复。
struct OutgoingPlanApprovalResponse: Encodable {
    let type = "plan_approval_response"
    let id: String
    let approved: Bool
}
