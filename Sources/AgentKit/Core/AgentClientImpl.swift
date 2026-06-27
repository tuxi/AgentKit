//
//  AgentClientImpl.swift
//  AgentKit
//
//  DefaultAgentClient — RuntimeClient 协议的唯一实现。
//  组合 RuntimeHTTPClient + AgentWireSocket。
//  UI 通过 AgentDependencies 拿到 RuntimeClient 协议实例，不感知此类。
//

import Foundation

// MARK: - DefaultAgentClient

public final class DefaultAgentClient: RuntimeClient, @unchecked Sendable {

    private let http: RuntimeHTTPClient
    private var socket: AgentWireSocket?

    private let host: String
    private let port: Int

    // MARK: - Init

    public init(host: String = "127.0.0.1", port: Int = 8787) {
        self.host = host
        self.port = port
        self.http = RuntimeHTTPClient(host: host, port: port)
    }

    // MARK: - RuntimeClient conformance

    public func createConversation(workspacePath: String = "") async throws -> ConversationRef {
        try await http.createConversation(workspacePath: workspacePath)
    }

    public func listConversations() async throws -> [ConversationRef] {
        try await http.listConversations()
    }

    public func connect(conversationID: String) async throws -> AsyncStream<AgentEvent> {
        // 断开旧连接
        await disconnect()

        let newSocket = AgentWireSocket(host: host, port: port, conversationID: conversationID)
        self.socket = newSocket
        return newSocket.connect()
    }

    public func sendMessage(_ text: String) async {
        socket?.sendMessage(text)
    }

    public func sendApproval(id: String, approved: Bool) async {
        socket?.sendApproval(id: id, approved: approved)
    }

    public func sendPlanApproval(id: String, approved: Bool) async {
        socket?.sendPlanApproval(id: id, approved: approved)
    }

    public func cancelTurn() async {
        socket?.cancelTurn()
    }

    public func disconnect() async {
        socket?.disconnect()
        socket = nil
    }

    // MARK: - 历史读取

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
}
