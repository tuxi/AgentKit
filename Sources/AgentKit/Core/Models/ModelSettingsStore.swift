//
//  ModelSettingsStore.swift
//  AgentKit
//
//  模型设置管理器。
//  管理用户本地模型偏好（UserDefaults 持久化），通过 GatewayService 主动获取模型列表。
//
//  职责边界：
//    - Host App: 实现 GatewayService 协议，提供 Gateway API 访问
//    - AgentKit: 通过 GatewayService 获取模型列表，管理 per-conversation 选择
//    - Runtime:  只接收 model 参数，不管理模型列表
//

import Foundation

// MARK: - ModelSettingsStore

/// 模型设置管理器。
/// 通过 GatewayService 主动获取并管理用户本地模型偏好。
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
    
    private let service: GatewayService
    private var refreshTask: Task<Void, Error>?

    // MARK: - Init

    public init(
        defaults: UserDefaults = .standard,
        service: GatewayService,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared
    ) {
        self.defaults = defaults
        self.localStateStore = localStateStore
        self.service = service
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

    // MARK: - Model List (via GatewayService)

    /// 模型列表是否已加载。
    public var isModelListLoaded: Bool { gatewayModels != nil }

    /// 通过 GatewayService 主动获取模型列表并更新本地缓存。
    /// 调用时机：App 启动、用户登录后。
    /// 失败时静默保留旧值，由调用方决定是否重试。
    public func refreshModels() async {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let response = try await service.refreshModels()
                gatewayModels = response.models
                gatewayDefaultModel = response.defaultModel
            } catch {
                // 静默保留旧值。宿主 App 可在登录回调等时机重试。
                DLLog(error)
            }
        }
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
        // An existing conversation without an explicit choice must not inherit
        // another conversation's latest selection. `lastSelectedModel` is only
        // the convenience default for a brand-new local draft.
        return usedModels[conversation] ?? defaultModelForExistingConversation
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
    /// 优先 Gateway 默认模型 → 回退上次选择的模型 → 回退列表第一个。
    /// 设计意图：新建对话应使用服务端指定的默认模型，而非继承其他对话的选择。
    public var modelForNewConversation: String {
        if let def = gatewayDefaultModel, let models = gatewayModels,
           models.contains(where: { $0.id == def && $0.available != false }) {
            return def
        }
        if let stored = lastSelectedModel,
           let models = gatewayModels, models.contains(where: { $0.id == stored && $0.available != false }) {
            return stored
        }
        if let first = gatewayModels?.first(where: { $0.available != false }) {
            return first.id
        }
        return ""
    }

    /// Existing sessions that have never selected a model use the Gateway
    /// default, independent from the app-wide recent model used by new drafts.
    public var defaultModelForExistingConversation: String {
        if let model = gatewayDefaultModel,
           let models = gatewayModels,
           models.contains(where: { $0.id == model && $0.available != false }) {
            return model
        }
        return gatewayModels?.first(where: { $0.available != false })?.id ?? ""
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
