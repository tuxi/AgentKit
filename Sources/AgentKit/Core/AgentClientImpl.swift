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

    private let host: String
    private let port: Int

    /// 待注册的客户端工具列表。在握手后自动发送。
    private var pendingTools: [ClientToolInfo] = []

    // MARK: - Init

    public init(host: String = "127.0.0.1", port: Int = 8787) {
        self.host = host
        self.port = port
        self.http = RuntimeHTTPClient(host: host, port: port)
    }

    // MARK: - AgentTransport: Session lifecycle

    public func createConversation(workspacePath: String = "") async throws -> ConversationRef {
        try await http.createConversation(workspacePath: workspacePath)
    }

    public func listConversations() async throws -> [ConversationRef] {
        try await http.listConversations()
    }

    public func attach(sessionID: String) async throws -> AsyncStream<AgentEvent> {
        await disconnect()

        let newSocket = AgentWireSocket(host: host, port: port, conversationID: sessionID)

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
        return wireFrames.compactMap { AgentEvent.from(wire: $0) }
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

    /// 便捷初始化：连接本地 CodeAgent backend。
    public convenience init(host: String = "127.0.0.1", port: Int = 8787) {
        self.init(transport: CodeAgentTransport(host: host, port: port))
    }

    // MARK: - RuntimeClient conformance

    public func createConversation(workspacePath: String = "") async throws -> ConversationRef {
        try await transport.createConversation(workspacePath: workspacePath)
    }

    public func listConversations() async throws -> [ConversationRef] {
        try await transport.listConversations()
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

    public func getConversationDetail(id: String) async throws -> ConversationDetail {
        try await transport.getConversationDetail(id: id)
    }

    public func getMessages(conversationID: String) async throws -> [Message] {
        try await transport.getMessages(conversationID: conversationID)
    }

    public func getEvents(conversationID: String) async throws -> [AgentEvent] {
        try await transport.getEvents(conversationID: conversationID)
    }
}
