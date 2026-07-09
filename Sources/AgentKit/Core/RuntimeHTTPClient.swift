//
//  RuntimeHTTPClient.swift
//  AgentKit
//
//  最小 HTTP 客户端 — 仅服务 CodeAgent Runtime 的端点。
//  支持可选的 credential 注入（macOS 远端 Runtime 路径）。
//

import Foundation

// MARK: - RuntimeHTTPClient

struct RuntimeHTTPClient: Sendable {
    private let environment: RuntimeEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder
    private let credentialStore: (any CredentialStore)?
    private let credentialTarget: CredentialTarget

    init(
        environment: RuntimeEnvironment,
        credentialStore: (any CredentialStore)? = nil,
        credentialTarget: CredentialTarget = .gateway
    ) {
        self.environment = environment
        self.session = URLSession(configuration: .ephemeral)
        self.decoder = JSONDecoder()
        self.credentialStore = credentialStore
        self.credentialTarget = credentialTarget
    }

    /// 每次调用时从 environment 延迟取 baseURL（Avoids snapshot stale port）。
    private func resolveBaseURL() throws -> URL {
        guard let url = environment.baseURL else {
            throw RuntimeHTTPError.runtimeNotStarted
        }
        return url
    }

    /// 为请求注入 Authorization header（如果有 credential store）。
    private func applyAuth(to request: inout URLRequest) async {
        guard let store = credentialStore,
              let cred = try? await store.resolve(credentialTarget),
              !cred.secret.isEmpty,
              cred.kind == .bearer
        else { return }
        request.setValue("Bearer \(cred.secret)", forHTTPHeaderField: "Authorization")
    }

    func resolveRuntimeURL(_ value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL = try? resolveBaseURL() else {
            return URL(string: value)
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Helpers

    /// 构建带 credential 注入的请求。
    private func buildRequest(
        _ method: String,
        pathComponents: String...,
        queryItems: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil,
        timeout: TimeInterval = 60
    ) async throws -> URLRequest {
        var url = try resolveBaseURL()
        for comp in pathComponents { url = url.appendingPathComponent(comp) }
        if let items = queryItems, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = items
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        await applyAuth(to: &request)
        DeviceContext.apply(to: &request)
        return request
    }

    // MARK: - Endpoints

    /// `POST /v1/conversations`
    func createConversation(workspacePath: String) async throws -> ConversationRef {
        var wp = workspacePath
        if wp.isEmpty { wp = "." }
        let request = try await buildRequest("POST", pathComponents: "v1/conversations", body: ["workspace_path": wp])
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationRef.self, from: data)
    }

    /// `GET /v1/conversations`
    func listConversations() async throws -> [ConversationRef] {
        let request = try await buildRequest("GET", pathComponents: "v1/conversations")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([ConversationRef].self, from: data)
    }

    // MARK: - 历史读取（§2 历史读取）

    /// `GET /v1/conversations/{id}` — 会话概要。
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        let request = try await buildRequest("GET", pathComponents: "v1/conversations", id)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationDetail.self, from: data)
    }

    /// `PATCH /v1/conversations/{id}` — 修改会话名称。
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        let request = try await buildRequest("PATCH", pathComponents: "v1/conversations", id, body: ["name": name])
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(ConversationRef.self, from: data)
    }

    /// `GET /v1/conversations/{id}/messages` — 对话主干。
    func getMessages(conversationID: String) async throws -> [Message] {
        let request = try await buildRequest("GET", pathComponents: "v1/conversations", conversationID, "messages")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([Message].self, from: data)
    }

    /// `GET /v1/conversations/{id}/events[?since=N]` — 历史事件。
    func getEvents(conversationID: String, since: Int = 0) async throws -> [WireFrame] {
        let queryItems = since > 0 ? [URLQueryItem(name: "since", value: String(since))] : nil
        let request = try await buildRequest("GET", pathComponents: "v1/conversations", conversationID, "events", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([WireFrame].self, from: data)
    }

    /// `GET /v1/jobs/{id}/events[?since=N]` — 后台 job 子流 backlog。
    func getJobEvents(jobID: String, since: Int = 0) async throws -> [WireFrame] {
        let queryItems = since > 0 ? [URLQueryItem(name: "since", value: String(since))] : nil
        let request = try await buildRequest("GET", pathComponents: "v1/jobs", jobID, "events", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode([WireFrame].self, from: data)
    }

    /// `GET /v1/conversations/{id}/assets/{asset_id}/preview`.
    func getAssetPreview(conversationID: String, assetID: String) async throws -> AgentAssetPreviewResponse {
        let request = try await buildRequest("GET", pathComponents: "v1/conversations", conversationID, "assets", assetID, "preview")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(AgentAssetPreviewResponse.self, from: data)
    }

    /// `GET /v1/conversations/{id}/assets/{asset_id}/content`.
    func getAssetContent(conversationID: String, assetID: String) async throws -> AgentAssetContentResponse {
        let request = try await buildRequest("GET", pathComponents: "v1/conversations", conversationID, "assets", assetID, "content")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return try decoder.decode(AgentAssetContentResponse.self, from: data)
    }

    /// `POST /v1/repos/clone` — go-git clone。
    func cloneRepo(url repoURL: String, ref: String?) async throws -> ClonedRepo {
        var body: [String: String] = ["url": repoURL]
        if let ref, !ref.isEmpty { body["ref"] = ref }
        let request = try await buildRequest("POST", pathComponents: "v1/repos/clone", body: body, timeout: 180)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RuntimeHTTPError.invalidResponse }
        guard (200...201).contains(http.statusCode) else {
            throw RuntimeHTTPError.unexpectedStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(ClonedRepo.self, from: data)
    }

    /// `GET /healthz` — 存活探针（不注入 credential，无需认证）。
    func healthCheck() async throws -> Bool {
        let request = try await buildRequest("GET", pathComponents: "healthz", timeout: 3)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              body == "ok" else { return false }
        return true
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
