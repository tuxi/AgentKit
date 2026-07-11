//
//  ModelSettingsStore.swift
//  AgentKit
//
//  模型设置管理器。
//  管理用户本地模型偏好（UserDefaults 持久化），不负责从 Gateway 拉取模型列表。
//  由宿主 App 调用 `setAvailableModels(_:defaultModel:)` 注入模型数据。
//
//  职责边界：
//    - Host App: 从 Gateway 获取模型列表 → 调用 setAvailableModels()
//    - AgentKit: 记住 last_used_model，管理 per-conversation 选择
//    - Runtime:  只接收 model 参数，不管理模型列表
//

import Foundation

// MARK: - ModelSettingsStore

/// 模型设置管理器。
/// 管理用户本地模型偏好，由宿主 App 注入可用模型列表。
@MainActor
@Observable
public final class ModelSettingsStore {

    // MARK: - State

    /// 可用模型列表（nil = 尚未注入）。
    public private(set) var gatewayModels: [GatewayModel]?

    /// 默认模型（首次使用提示）。
    public private(set) var gatewayDefaultModel: String?

    // MARK: - Private

    private static let lastModelKey = "code_agent.model.last_selected"
    private static let usedModelsKey = "code_agent.model.used_models"

    /// 每一个对话选择的模型：[conversationID: modelID]
    private var usedModels: [String: String] = [:]
    /// 最后一次选择模型（跨对话，用于新对话默认值）
    public private(set) var lastSelectedModel: String?

    // MARK: - Init

    public init() {
        // 从本地缓存恢复
        self.lastSelectedModel = UserDefaults.standard.string(forKey: Self.lastModelKey)
        self.usedModels = UserDefaults.standard.dictionary(forKey: Self.usedModelsKey) as? [String: String] ?? [:]
    }

    // MARK: - Persistence

    private func persistLastSelected() {
        if let model = lastSelectedModel {
            UserDefaults.standard.set(model, forKey: Self.lastModelKey)
        }
    }

    private func persistUsedModels() {
        UserDefaults.standard.set(usedModels, forKey: Self.usedModelsKey)
    }

    // MARK: - Model List Injection (called by host app)

    /// 由宿主 App 调用，注入从 Gateway 或其它来源获取的可用模型列表。
    public func setAvailableModels(_ models: [GatewayModel], defaultModel: String?) {
        gatewayModels = models
        gatewayDefaultModel = defaultModel
    }

    // MARK: - User Preferences

    /// 用户选择模型时调用。持久化到本地缓存。
    public func didUseModel(_ modelID: String, conversation: String) {
        setUserModel(modelID, for: conversation)
        self.lastSelectedModel = modelID
        persistLastSelected()
    }

    public func setUserModel(_ modelID: String, for conversation: String) {
        guard !conversation.isEmpty else { return }
        guard !modelID.isEmpty else { return }
        self.usedModels[conversation] = modelID
        persistUsedModels()
    }

    public func getModel(with conversation: String?) -> String? {
        guard let conversation, !conversation.isEmpty else {
            return modelForNewConversation
        }
        return usedModels[conversation] ?? modelForNewConversation
    }

    /// 模型的 display name（用于 UI）。
    public func displayName(for modelID: String) -> String {
        gatewayModels?.first(where: { $0.id == modelID })?.displayName ?? modelID
    }

    /// 可用模型 ID 列表。
    public var availableModelIDs: [String] {
        gatewayModels?.filter { $0.available != false }.map(\.id) ?? []
    }

    /// 新对话时使用的模型 ID。
    /// 优先 UserDefaults 持久化值 → 回退 default_model → 回退列表第一个。
    public var modelForNewConversation: String {
        if let stored = lastSelectedModel,
            let models = gatewayModels, models.contains(where: { $0.id == stored }) {
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
}
