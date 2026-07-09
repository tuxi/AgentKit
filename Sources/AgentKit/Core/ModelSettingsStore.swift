//
//  ModelSettingsStore.swift
//  AgentKit
//
//  模型设置管理器。
//  从 Gateway 动态获取可用模型列表，管理用户本地模型偏好。
//
//  职责边界：
//    - Gateway:  提供 available models + default_model（首次提示）
//    - AgentKit: 调用 GET /agent/models，记住 last_used_model
//    - Runtime:  只接收 model 参数，不管理模型列表
//

import Foundation

// MARK: - ModelSettingsStore

/// 模型设置管理器。
/// 从 Agent Gateway 获取可用模型，管理用户本地偏好。
@MainActor
@Observable
public final class ModelSettingsStore {

    // MARK: - State

    /// 从 Gateway 获取的可用模型列表（nil = 尚未加载）。
    public private(set) var gatewayModels: [GatewayModel]?

    /// Gateway 的默认模型（首次使用提示）。
    public private(set) var gatewayDefaultModel: String?

    /// 新对话时使用的模型 ID。
    /// 优先 UserDefaults 持久化值 → 回退 Gateway default_model → 回退列表第一个。
    public var modelForNewConversation: String {
        let stored = lastUsedModel
        if let models = gatewayModels, models.contains(where: { $0.id == stored }) {
            return stored
        }
        if let def = gatewayDefaultModel, let models = gatewayModels,
           models.contains(where: { $0.id == def }) {
            return def
        }
        if let first = gatewayModels?.first(where: { $0.available != false }) {
            return first.id
        }
        return ""
    }

    // MARK: - Private

    private static let lastModelKey = "code_agent.last_model"

    /// 全局记忆：用户最近一次在任意对话中使用的模型。
    private var lastUsedModel: String {
        get { UserDefaults.standard.string(forKey: Self.lastModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastModelKey) }
    }

    private let authClient: any AuthClientProtocol
    private let credentialStore: any CredentialStore

    // MARK: - Init

    public init(
        authClient: any AuthClientProtocol = URLSessionAuthClient(),
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        self.authClient = authClient
        self.credentialStore = credentialStore
    }

    // MARK: - Public

    /// 从 Gateway 获取模型列表。应在用户已登录时调用。
    public func fetchFromGateway() async {
        guard let token = try? await credentialStore.resolve(.gateway)?.secret else { return }
        do {
            let response = try await authClient.getModels(accessToken: token)
            gatewayModels = response.models
            gatewayDefaultModel = response.defaultModel
        } catch {
            // 网络错误不覆盖已有数据
        }
    }

    /// 用户选择模型时调用。持久化为全局 "last used"（用于新对话默认值）。
    public func didUseModel(_ modelID: String) {
        guard !modelID.isEmpty else { return }
        lastUsedModel = modelID
    }

    /// 模型的 display name（用于 UI）。
    public func displayName(for modelID: String) -> String {
        gatewayModels?.first(where: { $0.id == modelID })?.displayName ?? modelID
    }

    /// 从 Gateway 获取的可用模型 ID 列表。
    public var availableModelIDs: [String] {
        gatewayModels?.filter { $0.available != false }.map(\.id) ?? []
    }
}
