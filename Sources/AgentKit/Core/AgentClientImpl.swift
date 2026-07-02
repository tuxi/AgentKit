//
//  AgentClientImpl.swift
//  AgentKit
//
//  DefaultAgentClient — thin facade over AgentTransport.
//  CodeAgentTransport — AgentTransport impl for CodeAgent backend.
//
//  Protocol: AgentKit Runtime Protocol v1.1
//
//  分层：
//     UI → RuntimeClient → DefaultAgentClient (facade)
//        → AgentTransport → CodeAgentTransport (impl)
//

import Foundation

// MARK: - CodeAgentTransport

/// CodeAgent backend 的 `AgentTransport` 实现。
/// 组合 `RuntimeHTTPClient`（HTTP） + `AgentWireSocket`（WebSocket）。
///
/// 替换此类即可接入不同 backend：`DreamAITransport` / `MockTransport`。
public final class CodeAgentTransport: AgentTransport, @unchecked Sendable {

    private let http: RuntimeHTTPClient
    private var socket: AgentWireSocket?

    private let environment: RuntimeEnvironment

    /// 待注册的客户端工具列表。在握手后自动发送。
    private var pendingTools: [ClientToolInfo] = []

    // MARK: - Init

    public init(environment: RuntimeEnvironment) {
        self.environment = environment
        self.http = RuntimeHTTPClient(environment: environment)
    }

    // MARK: - AgentTransport: Session lifecycle

    public func createConversation(workspacePath: String = "") async throws -> ConversationRef {
        try await http.createConversation(workspacePath: workspacePath)
    }

    public func listConversations() async throws -> [ConversationRef] {
        try await http.listConversations()
    }

    public func renameConversation(id: String, name: String) async throws -> ConversationRef {
        try await http.renameConversation(id: id, name: name)
    }

    public func attach(sessionID: String) async throws -> AsyncStream<AgentEvent> {
        await disconnect()

        let newSocket = AgentWireSocket(environment: environment, conversationID: sessionID)

        // 握手完成后自动发送待注册的客户端工具
        let tools = pendingTools
        newSocket.onHandshake = { [weak newSocket] in
            guard !tools.isEmpty else { return }
            newSocket?.sendRegisterTools(tools)
        }

        self.socket = newSocket
        return newSocket.connect()
    }

    public func disconnect() async {
        socket?.disconnect()
        socket = nil
    }

    // MARK: - AgentTransport: Repos

    public func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo {
        try await http.cloneRepo(url: url, ref: ref)
    }

    // MARK: - AgentTransport: Session state

    public var isConnected: Bool { socket?.isConnected ?? false }
    public var activeSessionID: String? { socket?.activeSessionID }

    // MARK: - AgentTransport: Input

    public func send(input: AgentInput) async {
        socket?.send(input: input)
    }

    // MARK: - AgentTransport: Control plane

    public func approve(id: String, value: Bool) async {
        socket?.sendApproval(id: id, approved: value)
    }

    public func approvePlan(id: String, value: Bool) async {
        socket?.sendPlanApproval(id: id, approved: value)
    }

    public func cancelTurn() async {
        socket?.cancelTurn()
    }

    // MARK: - AgentTransport: History plane

    public func getConversationDetail(id: String) async throws -> ConversationDetail {
        try await http.getConversationDetail(id: id)
    }

    public func getMessages(conversationID: String) async throws -> [Message] {
        try await http.getMessages(conversationID: conversationID)
    }

    public func getEvents(conversationID: String) async throws -> [AgentEvent] {
        let wireFrames = try await http.getEvents(conversationID: conversationID)
        // Server returns events in chronological order (ORDER BY at ASC).
        // No client-side sorting needed.
        return wireFrames.compactMap { AgentEvent.from(wire: $0) }
    }

    public func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch {
        let wireFrames = try await http.getEvents(conversationID: conversationID, since: since)
        // nextSince 按服务端原始事件计数推进 —— 未知 kind 被 compactMap 丢弃后
        // 不能影响游标，否则会重复拉取同一批事件。
        return AgentEventBatch(
            events: wireFrames.compactMap { AgentEvent.from(wire: $0) },
            nextSince: since + wireFrames.count
        )
    }

    public func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse {
        try await http.getAssetPreview(conversationID: conversationID, assetID: assetID)
    }

    public func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse {
        try await http.getAssetContent(conversationID: conversationID, assetID: assetID)
    }

    // MARK: - AgentTransport: Tool registration

    public func registerTools(_ tools: [ClientToolInfo]) async {
        pendingTools = tools
        // 如果已经连上（握手已完成），立即发送
        if let socket, socket.isConnected {
            socket.sendRegisterTools(tools)
        }
        // 否则在下次 attach 时通过 onHandshake 发送
    }

    // MARK: - AgentTransport: Capability discovery

    public func capabilities() async -> AgentCapabilityFlags {
        let serverCaps = Set(socket?.serverCapabilities ?? [])
        var flags = AgentCapabilityFlags.default

        if serverCaps.contains("client_tool_execution") {
            // 服务端支持将工具委托给客户端执行
            flags.insert(.clientToolExecution)
        }

        return flags
    }
}

// MARK: - DefaultAgentClient

/// `RuntimeClient` 的 thin facade — 零业务逻辑，只转发到 `AgentTransport`。
///
/// UI 通过 `AgentDependencies` 拿到 `RuntimeClient` 协议实例。
/// 要替换 backend，替换 `transport` 即可，不修改 UI 层。
public final class DefaultAgentClient: RuntimeClient, @unchecked Sendable {

    private let transport: any AgentTransport

    // MARK: - Init

    /// 使用指定的 transport 创建。
    public init(transport: any AgentTransport) {
        self.transport = transport
    }

    /// 便捷初始化：连接指定 Runtime。
    public convenience init(environment: RuntimeEnvironment) {
        self.init(transport: CodeAgentTransport(environment: environment))
    }

    /// 便捷初始化：使用默认占位环境。调用方应在 Runtime 启动后替换为真实端口。
    public convenience init() {
        self.init(environment: .placeholder)
    }

    #if os(iOS)
    /// 便捷初始化：从 `AgentRuntime.shared` 读取已启动 server 的动态端口。
    public static func fromRuntime() -> DefaultAgentClient {
        DefaultAgentClient(environment: .fromRuntime())
    }
    #endif

    // MARK: - RuntimeClient conformance

    public func createConversation(workspacePath: String = "") async throws -> ConversationRef {
        try await transport.createConversation(workspacePath: workspacePath)
    }

    public func listConversations() async throws -> [ConversationRef] {
        try await transport.listConversations()
    }

    public func renameConversation(id: String, name: String) async throws -> ConversationRef {
        try await transport.renameConversation(id: id, name: name)
    }

    public func connect(conversationID: String) async throws -> AsyncStream<AgentEvent> {
        try await transport.attach(sessionID: conversationID)
    }

    public func send(input: AgentInput) async {
        await transport.send(input: input)
    }

    public func registerTools(_ tools: [ClientToolInfo]) async {
        await transport.registerTools(tools)
    }

    public func sendApproval(id: String, approved: Bool) async {
        await transport.approve(id: id, value: approved)
    }

    public func sendPlanApproval(id: String, approved: Bool) async {
        await transport.approvePlan(id: id, value: approved)
    }

    public func cancelTurn() async {
        await transport.cancelTurn()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    public func cloneRepo(url: String, ref: String?) async throws -> ClonedRepo {
        try await transport.cloneRepo(url: url, ref: ref)
    }

    public func getConversationDetail(id: String) async throws -> ConversationDetail {
        try await transport.getConversationDetail(id: id)
    }

    public func getMessages(conversationID: String) async throws -> [Message] {
        try await transport.getMessages(conversationID: conversationID)
    }

    public func getEvents(conversationID: String) async throws -> [AgentEvent] {
        try await transport.getEvents(conversationID: conversationID)
    }

    public func getEventBatch(conversationID: String, since: Int) async throws -> AgentEventBatch {
        try await transport.getEventBatch(conversationID: conversationID, since: since)
    }

    public func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse {
        try await transport.getAssetPreview(conversationID: conversationID, assetID: assetID)
    }

    public func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse {
        try await transport.getAssetContent(conversationID: conversationID, assetID: assetID)
    }
}
