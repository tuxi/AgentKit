//
//  RuntimeHTTPClient.swift
//  AgentKit
//
//  最小 HTTP 客户端 — 仅服务 CodeAgent Runtime 的 2 个端点。
//  v1 无需 auth / interceptor / 加密，URLSession 直连。
//

import Foundation

// MARK: - RuntimeHTTPClient

struct RuntimeHTTPClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(host: String = "192.168.1.4", port: Int = 8787) {
        guard let url = URL(string: "http://\(host):\(port)") else {
            fatalError("Invalid runtime base URL: http://\(host):\(port)")
        }
        self.baseURL = url
        self.session = URLSession(configuration: .ephemeral)
        self.decoder = JSONDecoder()
    }

    // MARK: - Endpoints

    /// `POST /v1/conversations`
    func createConversation(workspacePath: String) async throws -> ConversationRef {
        let url = baseURL.appendingPathComponent("v1/conversations")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var workspacePath = workspacePath
        if workspacePath.isEmpty {
            workspacePath = "."
        }

        let body: [String: String] = ["workspace_path": workspacePath]
        
        DLLog(body)
        
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationRef.self, from: data)
    }

    /// `GET /v1/conversations`
    func listConversations() async throws -> [ConversationRef] {
        let url = baseURL.appendingPathComponent("v1/conversations")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([ConversationRef].self, from: data)
    }

    // MARK: - 历史读取（§2 历史读取）

    /// `GET /v1/conversations/{id}` — 会话概要。
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        let url = baseURL
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationDetail.self, from: data)
    }

    /// `PATCH /v1/conversations/{id}` — 修改会话名称。
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        let url = baseURL
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["name": name]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationRef.self, from: data)
    }

    /// `GET /v1/conversations/{id}/messages` — 对话主干。
    func getMessages(conversationID: String) async throws -> [Message] {
        let url = baseURL
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    /// `GET /v1/conversations/{id}/events` — 历史事件（WireEvent 格式，用于 Timeline 回放）。
    /// 返回原始 `[WireFrame]`，由调用方转为 `[AgentEvent]`。
    func getEvents(conversationID: String) async throws -> [WireFrame] {
        let url = baseURL
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("events")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
//        DLLog(String(data: data, encoding: .utf8)!)
        return try decoder.decode([WireFrame].self, from: data)
    }

    /// `GET /healthz` — 存活探针。
    func healthCheck() async throws -> Bool {
        let url = baseURL.appendingPathComponent("healthz")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              body == "ok" else {
            return false
        }
        return true
    }

    // MARK: - Helpers

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeHTTPError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200, 201:
            return
        case 404:
            throw RuntimeHTTPError.notFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeHTTPError.unexpectedStatus(httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Errors

enum RuntimeHTTPError: Error {
    case invalidResponse
    case notFound
    case unexpectedStatus(Int, body: String)
}
