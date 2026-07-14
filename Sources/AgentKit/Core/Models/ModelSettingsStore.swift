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

    private let defaults: UserDefaults
    private let localStateStore: any ConversationLocalStateStore

    /// 每一个对话选择的模型：[conversationID: modelID]
    private var usedModels: [String: String] = [:]
    /// 最后一次选择模型（跨对话，用于新对话默认值）
    public private(set) var lastSelectedModel: String?

    // MARK: - Init

    public init(
        defaults: UserDefaults = .standard,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared
    ) {
        self.defaults = defaults
        self.localStateStore = localStateStore
        // 从本地缓存恢复
        self.lastSelectedModel = defaults.string(forKey: Self.lastModelKey)
        self.usedModels = defaults.dictionary(forKey: Self.usedModelsKey) as? [String: String] ?? [:]
        migrateLegacyConversationModels()
    }

    // MARK: - Persistence

    private func persistLastSelected() {
        if let model = lastSelectedModel {
            defaults.set(model, forKey: Self.lastModelKey)
        }
    }

    private func persistUsedModels() {
        // Per-session values moved to ConversationLocalStateStore. Removing the
        // legacy dictionary prevents two writable sources of truth.
        defaults.removeObject(forKey: Self.usedModelsKey)
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
        try? localStateStore.updateState(for: .session(conversation)) { state in
            state.selectedModelID = modelID
            state.recentModelIDs.removeAll { $0 == modelID }
            state.recentModelIDs.insert(modelID, at: 0)
            if state.recentModelIDs.count > 8 {
                state.recentModelIDs.removeLast(state.recentModelIDs.count - 8)
            }
        }
    }

    public func getModel(with conversation: String?) -> String? {
        guard let conversation, !conversation.isEmpty else {
            return modelForNewConversation
        }
        if let persisted = try? localStateStore.state(for: .session(conversation))?.selectedModelID,
           !persisted.isEmpty {
            usedModels[conversation] = persisted
            return persisted
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

    public func recentModels(for conversation: String) -> [String] {
        guard !conversation.isEmpty else { return [] }
        return (try? localStateStore.state(for: .session(conversation))?.recentModelIDs) ?? []
    }

    private func migrateLegacyConversationModels() {
        guard !usedModels.isEmpty else { return }
        var migrationSucceeded = true
        for (sessionID, modelID) in usedModels {
            do {
                try localStateStore.updateState(for: .session(sessionID)) { state in
                    if state.selectedModelID == nil {
                        state.selectedModelID = modelID
                    }
                    if !state.recentModelIDs.contains(modelID) {
                        state.recentModelIDs.append(modelID)
                    }
                }
            } catch {
                migrationSucceeded = false
            }
        }
        if migrationSucceeded {
            defaults.removeObject(forKey: Self.usedModelsKey)
        }
    }
}
