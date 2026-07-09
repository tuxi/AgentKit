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

    /// 当前选择的模型 ID（Gateway 原生 ID，如 `"deepseek-v4-pro"`）。
    public var selectedModel: String

    /// 用户上次选择的有效模型。
    /// 优先 UserDefaults 持久化的值 → 回退 Gateway default_model → 回退空字符串。
    public var effectiveModel: String {
        let stored = lastUsedModel
        if let models = gatewayModels, models.contains(where: { $0.id == stored }) {
            return stored
        }
        if let def = gatewayDefaultModel, let models = gatewayModels,
           models.contains(where: { $0.id == def }) {
            return def
        }
        // 回退：使用 Gateway 列表中第一个可用模型
        if let first = gatewayModels?.first(where: { $0.available != false }) {
            return first.id
        }
        return ""
    }

    // MARK: - Private

    private static let lastModelKey = "code_agent.last_model"

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
        self.selectedModel = ""
    }

    // MARK: - Public

    /// 从 Gateway 获取模型列表。应在用户已登录时调用。
    /// 首次调用后 `selectedModel` 设为 effective model。
    public func fetchFromGateway() async {
        guard let token = try? await credentialStore.resolve(.gateway)?.secret else { return }
        do {
            let response = try await authClient.getModels(accessToken: token)
            gatewayModels = response.models
            gatewayDefaultModel = response.defaultModel

            // 首次加载：selectedModel = effective（未选择过则用默认）
            if selectedModel.isEmpty {
                selectedModel = effectiveModel
            }
        } catch {
            // 网络错误不覆盖已有数据
        }
    }

    /// 用户主动选择模型。持久化到本地。
    public func selectModel(_ modelID: String) {
        selectedModel = modelID
        lastUsedModel = modelID
    }

    /// 当前模型的 display name（用于 UI）。
    public func displayName(for modelID: String) -> String {
        gatewayModels?.first(where: { $0.id == modelID })?.displayName ?? modelID
    }

    /// 从 Gateway 获取的可用模型 ID 列表。
    public var availableModelIDs: [String] {
        gatewayModels?.filter { $0.available != false }.map(\.id) ?? []
    }
}
