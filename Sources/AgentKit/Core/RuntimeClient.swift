//
//  RuntimeClient.swift
//  AgentKit
//
//  RuntimeClient 协议 — Swift 侧消费 agent-wire v1 的唯一入口。
//  ViewModel 只依赖此协议，不直接接触 HTTP / WebSocket / WireFrame。
//

import Foundation

// MARK: - RuntimeClient protocol

public protocol RuntimeClient: Sendable {
    /// 新建会话。
    /// - Parameter workspacePath: 工作区路径（v1 服务端忽略，但按协议写入）。
    /// - Returns: 包含服务端分配 `id` 的引用。
    func createConversation(workspacePath: String) async throws -> ConversationRef

    /// 列出当前内存中的会话。
    func listConversations() async throws -> [ConversationRef]

    /// 连接指定会话的事件流。
    /// - Parameter conversationID: 会话 id。
    /// - Returns: 一个 `AsyncStream`，持续产生 `AgentEvent` 直到连接断开。
    func connect(conversationID: String) async throws -> AsyncStream<AgentEvent>

    /// 驱动一轮对话（fire-and-forget）。真正响应来自 event stream。
    func sendMessage(_ text: String) async

    /// 审批回复 — 对应某条 `approval_request`。
    func sendApproval(id: String, approved: Bool) async

    /// 计划审批回复 — 对应某条 `plan_approval_request`。
    func sendPlanApproval(id: String, approved: Bool) async

    /// 取消当前正在执行的 turn。
    func cancelTurn() async

    /// 断开当前连接。
    func disconnect() async

    // MARK: - 历史读取（§2）

    /// 会话概要（由已记录事件派生）。
    func getConversationDetail(id: String) async throws -> ConversationDetail

    /// 对话主干消息（user/assistant）。
    func getMessages(conversationID: String) async throws -> [Message]

    /// 历史事件 — 用于 Timeline 回放。
    /// 推荐恢复流程：先调此方法渲染历史，再调 `connect()` 收增量。
    func getEvents(conversationID: String) async throws -> [AgentEvent]
}
