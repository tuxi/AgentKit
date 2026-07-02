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
    private let environment: RuntimeEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder

    init(environment: RuntimeEnvironment) {
        self.environment = environment
        self.session = URLSession(configuration: .ephemeral)
        self.decoder = JSONDecoder()
    }

    /// 每次调用时从 environment 延迟取 baseURL（Avoids snapshot stale port）。
    private func resolveBaseURL() throws -> URL {
        guard let url = environment.baseURL else {
            throw RuntimeHTTPError.runtimeNotStarted
        }
        return url
    }

    // MARK: - Endpoints

    /// `POST /v1/conversations`
    func createConversation(workspacePath: String) async throws -> ConversationRef {
        let url = try resolveBaseURL().appendingPathComponent("v1/conversations")
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
        let url = try resolveBaseURL().appendingPathComponent("v1/conversations")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([ConversationRef].self, from: data)
    }

    // MARK: - 历史读取（§2 历史读取）

    /// `GET /v1/conversations/{id}` — 会话概要。
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        let url = try resolveBaseURL()
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
        let url = try resolveBaseURL()
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
        let url = try resolveBaseURL()
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    /// `GET /v1/conversations/{id}/events[?since=N]` — 历史事件（WireEvent 格式，用于 Timeline 回放）。
    /// 返回原始 `[WireFrame]`，由调用方转为 `[AgentEvent]`。
    /// `since` > 0 时增量读取（P8.7 子流轮询）。N = 已收到帧里最大的 `seq`（v1.2 §4，
    /// seq 单调递增但有空洞，不能按条数推进）——见 docs/p8.7-client-plan.md §4。
    func getEvents(conversationID: String, since: Int = 0) async throws -> [WireFrame] {
        var url = try resolveBaseURL()
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("events")
        if since > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "since", value: String(since))]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        DLLog(String(data: data, encoding: .utf8)!)
        return try decoder.decode([WireFrame].self, from: data)
    }

    /// `GET /v1/conversations/{id}/assets/{asset_id}/preview`.
    func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse {
        let url = try assetURL(conversationID: conversationID, assetID: assetID)
            .appendingPathComponent("preview")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(AgentAssetPreviewResponse.self, from: data)
    }

    /// `GET /v1/conversations/{id}/assets/{asset_id}/content`.
    func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse {
        let url = try assetURL(conversationID: conversationID, assetID: assetID)
            .appendingPathComponent("content")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(AgentAssetContentResponse.self, from: data)
    }

    /// `POST /v1/repos/clone` — go-git 把公开仓库 clone 进 workspaceRoot/<name> 下。
    /// 同步：阻塞到 clone 完成。clone 可能慢 → 单独设较长超时（默认 60s 不够）。
    func cloneRepo(url repoURL: String, ref: String?) async throws -> ClonedRepo {
        let endpoint = try resolveBaseURL().appendingPathComponent("v1/repos/clone")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180   // clone 同步、可能慢

        var body: [String: String] = ["url": repoURL]
        if let ref, !ref.isEmpty { body["ref"] = ref }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        // 不走 validateHTTP：clone 的 404=repo_not_found 等结构化错误带消息体，
        // 直接透传 body 供 LocalizedError 提取，避免被通用 .notFound 吞掉。
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeHTTPError.invalidResponse
        }
        guard (200...201).contains(http.statusCode) else {
            throw RuntimeHTTPError.unexpectedStatus(http.statusCode,
                                                    body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(ClonedRepo.self, from: data)
    }

    /// `GET /healthz` — 存活探针。
    func healthCheck() async throws -> Bool {
        let url = try resolveBaseURL().appendingPathComponent("healthz")
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

    private func assetURL(conversationID: String, assetID: String) throws -> URL {
        try resolveBaseURL()
            .appendingPathComponent("v1/conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("assets")
            .appendingPathComponent(assetID)
    }

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

// MARK: - Clone result

/// `POST /v1/repos/clone` 返回。host 主要用 `workspacePath` 建会话；
/// `workspaceRef` 与 workspace-path spec 一致（持久身份），此处可选解码。
public struct ClonedRepo: Decodable, Sendable {
    public let workspacePath: String

    enum CodingKeys: String, CodingKey {
        case workspacePath = "workspace_path"
    }
}

// MARK: - Errors

enum RuntimeHTTPError: Error {
    case invalidResponse
    case notFound
    case runtimeNotStarted
    case unexpectedStatus(Int, body: String)
    /// 当前 client/transport 不支持该能力（如 mock）。
    case unsupported
}

extension RuntimeHTTPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:   return "服务器响应无效。"
        case .notFound:          return "未找到。"
        case .runtimeNotStarted: return "运行时尚未启动。"
        case .unsupported:       return "当前后端不支持该操作。"
        case .unexpectedStatus(let code, let body):
            let msg = Self.extractMessage(from: body)
            return msg.isEmpty ? "请求失败（HTTP \(code)）。" : msg
        }
    }

    /// 从结构化错误体提取可读消息（`{"error":...}` / `{"message":...}`），失败则回退原文。
    private static func extractMessage(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }
        if let e = obj["error"] as? String { return e }
        if let m = obj["message"] as? String { return m }
        return trimmed
    }
}
