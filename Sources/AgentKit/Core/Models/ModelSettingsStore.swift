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

    /// Unified multi-connection catalog. Nil keeps the legacy Gateway-only
    /// behavior during host migration; an empty array is an explicit no-model state.
    public private(set) var unifiedModels: [UnifiedModelDescriptor]?

    /// Stable ID selected as the default by the unified catalog.
    public private(set) var unifiedDefaultModelID: String?

    // MARK: - Private

    private static let lastModelKey = "code_agent.model.last_selected"

    private let defaults: UserDefaults
    private let localStateStore: any ConversationLocalStateStore

    /// 最后一次选择模型（跨对话，用于新对话默认值）
    public private(set) var lastSelectedModel: UnifiedModel?
    
    private let service: (any GatewayService)?
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
        self.loadLastSelected()
    }

    /// Creates a model store that is driven exclusively by Provider Connections.
    public init(
        defaults: UserDefaults = .standard,
        localStateStore: any ConversationLocalStateStore = SQLiteConversationLocalStateStore.shared
    ) {
        self.defaults = defaults
        self.localStateStore = localStateStore
        self.service = nil
        self.loadLastSelected()
        self.unifiedModels = []
    }

    // MARK: - Persistence
    
    private func loadLastSelected() {
        if let data = defaults.data(forKey: Self.lastModelKey) {
            let decoder = JSONDecoder()

            do {
                let item = try? decoder.decode(UnifiedModel.self, from: data)
                self.lastSelectedModel = item
            } catch {
                DLLog(error)
            }
        }
    }

    private func persistLastSelected() {
        if let model = lastSelectedModel {
           let encoder = JSONEncoder()
            do {
                let data = try encoder.encode(model)
                defaults.set(data, forKey: Self.lastModelKey)
            } catch {
                DLLog(error)
            }
        }
    }

    // MARK: - Model List (via GatewayService)

    /// 模型列表是否已加载。
    public var isModelListLoaded: Bool { gatewayModels != nil }

    /// 通过 GatewayService 主动获取模型列表并更新本地缓存。
    /// 调用时机：App 启动、用户登录后。
    /// 失败时静默保留旧值，由调用方决定是否重试。
    public func refreshModels() async {
        guard let service else { return }
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

    // MARK: - Unified Provider Catalog

    /// Injects a secret-free catalog snapshot. The host calls this after every
    /// Provider Registry mutation; publishing through this observable store
    /// immediately updates the existing Composer.
    public func applyUnifiedCatalog(
        _ models: [UnifiedModelDescriptor],
        defaultModelID: String?
    ) {
        unifiedModels = models
        unifiedDefaultModelID = defaultModelID.flatMap { requested in
            models.contains(where: { $0.id == requested }) ? requested : nil
        }
    }

    public func applyUnifiedCatalog(_ catalog: UnifiedModelCatalogStore) {
        applyUnifiedCatalog(catalog.models, defaultModelID: catalog.defaultModelID)
    }

    public func descriptor(for modelID: String) -> UnifiedModelDescriptor? {
        unifiedModels?.first {
            if $0.id == modelID {
                return true
            }
            let items = modelID.components(separatedBy: "/")
            if items.count >= 2 {
                let providerID = items[0]
                let wireModelID = items[1...].joined(separator: "/")
                return $0.providerID == providerID && $0.wireModelID == wireModelID
            }
            
            return false
        }
    }

    /// The runtime wire alias for a model ID (from the unified catalog).
    /// Nil when the model is unknown (historical / removed).
    public func runtimeAlias(for modelID: String) -> String? {
        descriptor(for: modelID)?.runtimeAlias
    }

    public func isModelAvailable(_ modelID: String?) -> Bool {
        guard let modelID, !modelID.isEmpty else { return false }
        if let unifiedModels {
            let index = unifiedModels.first {
                $0.id == modelID || modelID == $0.providerID + "/" + $0.wireModelID
            }
            return index != nil
        }
        return gatewayModels?.contains { $0.id == modelID && $0.available != false } ?? false
    }

    /// Whether a usable Runtime default can be resolved. Legacy local state must
    /// not be normalized before this is true; an empty catalog is not evidence.
    public var hasResolvedModelCatalog: Bool {
        !runtimeDefaultModelID.isEmpty
    }

    /// The model the Runtime will use when a request omits `model`.
    public var runtimeDefaultModelID: String {
        if let unifiedModels {
            if let unifiedDefaultModelID,
               unifiedModels.contains(where: { $0.id == unifiedDefaultModelID }) {
                return unifiedDefaultModelID
            }
            return unifiedModels.first?.id ?? ""
        }
        if let model = gatewayDefaultModel,
           let models = gatewayModels,
           models.contains(where: { $0.id == model && $0.available != false }) {
            return model
        }
        return gatewayModels?.first(where: { $0.available != false })?.id ?? ""
    }

    public var runtimeDefaultModel: UnifiedModel? {
        let id = runtimeDefaultModelID
        guard !id.isEmpty else { return nil }
        return UnifiedModel(model: id, reasoningEffort: nil)
    }

    /// Matches both the stable catalog ID and its `provider/wire` presentation.
    public func isRuntimeDefaultModel(_ modelID: String) -> Bool {
        guard !modelID.isEmpty else { return false }
        let defaultID = runtimeDefaultModelID
        guard !defaultID.isEmpty else { return false }
        if modelID == defaultID { return true }
        if let descriptor = descriptor(for: defaultID) {
            return modelID == descriptor.id
            || modelID == descriptor.model
            || modelID == descriptor.providerID + "/" + descriptor.wireModelID
        }
        if let model = gatewayModels?.first(where: { $0.id == defaultID }) {
            return modelID == model.id || modelID == model.model
        }
        return false
    }

    /// Resolves persisted input intent. Nil mode means legacy state: without any
    /// durable provenance, a stored model cannot be proven to be a user choice,
    /// so it must not keep routing future turns. Legacy state migrates to the
    /// Runtime default; explicit intent is only recognized when it was persisted
    /// by a version that records the mode.
    public func composerSelection(
        selectedModelID: String?,
        storedMode: ComposerModelSelectionMode?,
        storedVersion: Int? = nil,
        reasoningEffort: String?
    ) -> ComposerModelSelection {
        if let storedMode {
            switch storedMode {
            case .followDefault:
                return .followDefault
            case .explicit:
                // Unversioned explicit values were written by older migration
                // heuristics, not by a picker action. Normalize them once.
                guard storedVersion == ConversationLocalState.currentComposerSelectionVersion else {
                    return .followDefault
                }
                guard let selectedModelID, !selectedModelID.isEmpty else {
                    return .followDefault
                }
                return .explicit(UnifiedModel(
                    model: selectedModelID,
                    reasoningEffort: ModelReasoningEffort(rawValue: reasoningEffort ?? "")
                ))
            }
        }
        return .followDefault
    }

    public func composerSelection(for conversation: String?) -> ComposerModelSelection {
        guard let conversation, !conversation.isEmpty else { return .followDefault }
        let state = try? localStateStore.state(for: .session(conversation))
        return composerSelection(
            selectedModelID: state?.selectedModelID,
            storedMode: state?.modelSelectionMode,
            storedVersion: state?.composerSelectionVersion,
            reasoningEffort: state?.reasoningEffort
        )
    }

    public func getWireModelID(for modelID: String) -> String? {
        if let unifiedModels {
            let curModel = unifiedModels.first { $0.id == modelID }
            if let curModel {
                return curModel.connectionID + "/" + curModel.wireModelID
            }
        }
        return isModelAvailable(modelID) ? modelID : nil
    }

    public var unifiedModelGroups: [(connectionID: String, name: String, models: [UnifiedModelDescriptor])] {
        guard let unifiedModels else { return [] }
        var order: [String] = []
        var grouped: [String: [UnifiedModelDescriptor]] = [:]
        for model in unifiedModels {
            if grouped[model.connectionID] == nil {
                order.append(model.connectionID)
            }
            grouped[model.connectionID, default: []].append(model)
        }
        return order.compactMap { connectionID in
            guard let models = grouped[connectionID], let first = models.first else { return nil }
            return (connectionID, first.providerDisplayName, models)
        }
    }

    // MARK: - User Preferences

    /// 用户选择模型时调用。持久化到本地缓存。
    public func didUseModel(_ modelID: String, reasoningEffort: ModelReasoningEffort?, conversation: String) {
        setUserModel(modelID, reasoningEffort: reasoningEffort, for: conversation)
        self.lastSelectedModel = UnifiedModel(model: modelID, reasoningEffort: reasoningEffort)
        persistLastSelected()
    }

    public func setUserModel(_ modelID: String, reasoningEffort: ModelReasoningEffort?, for conversation: String) {
        guard !conversation.isEmpty else { return }
        guard !modelID.isEmpty else { return }
        try? localStateStore.updateState(for: .session(conversation)) { state in
            state.modelSelectionMode = .explicit
            state.composerSelectionVersion = ConversationLocalState.currentComposerSelectionVersion
            state.selectedModelID = modelID
            state.reasoningEffort = reasoningEffort?.rawValue
            state.recentModelIDs.removeAll { $0 == modelID }
            state.recentModelIDs.insert(modelID, at: 0)
            if state.recentModelIDs.count > 8 {
                state.recentModelIDs.removeLast(state.recentModelIDs.count - 8)
            }
        }
    }

    /// Switches a conversation back to Runtime-default routing and removes any
    /// stale explicit model or reasoning override from local state.
    public func useRuntimeDefaultModel(for conversation: String) {
        guard !conversation.isEmpty else { return }
        try? localStateStore.updateState(for: .session(conversation)) { state in
            state.modelSelectionMode = .followDefault
            state.composerSelectionVersion = ConversationLocalState.currentComposerSelectionVersion
            state.selectedModelID = nil
            state.reasoningEffort = nil
        }
    }

    public func getModel(with conversation: String?) -> UnifiedModel? {
        guard let conversation, !conversation.isEmpty else {
            return modelForNewConversation
        }
        if let persisted = try? localStateStore.state(for: .session(conversation)),
           persisted.modelSelectionMode == .followDefault {
            return UnifiedModel(model: defaultModelForExistingConversation, reasoningEffort: nil)
        }
        if let persisted = try? localStateStore.state(for: .session(conversation)), let model = persisted.selectedModelID, !model.isEmpty {
            return UnifiedModel(model: model, reasoningEffort: ModelReasoningEffort(rawValue: persisted.reasoningEffort ?? ""))
        }
        // An existing conversation without an explicit choice must not inherit
        // another conversation's latest selection. `lastSelectedModel` is only
        // the convenience default for a brand-new local draft.
        return UnifiedModel(model: defaultModelForExistingConversation, reasoningEffort: nil)
    }

    /// 模型的 display name（用于 UI）。
    public func displayName(for modelID: String) -> String {
        if let unifiedModels {
            if let model = unifiedModels.first(where: { $0.id == modelID }) {
               return model.model
            }
            if let identity = UnifiedModelDescriptor.parseRuntimeAlias(modelID) {
                return identity.wireModelID
            }
        }
        if let model = gatewayModels?.first(where: { $0.id == modelID }) {
            return model.model
        }
        return modelID
    }

    /// Display text for the current Composer selection. Historical choices stay
    /// selected but are explicitly marked unavailable until the user chooses a
    /// model from a live Provider connection.
    public func selectionDisplayName(for modelID: String) -> String {
        let name = displayName(for: modelID)
        guard !modelID.isEmpty, !isModelAvailable(modelID) else { return name }
        return String(
            format: AgentKitLocalized.string("composer.model_unavailable_format"),
            name
        )
    }

    /// 可用模型 ID 列表。
    public var availableModelIDs: [String] {
        if let unifiedModels {
            let models = unifiedModels.map {
                $0.model
            }
            return models
        }
        let models = gatewayModels?.filter { $0.available != false }.map {
            $0.model
        }
        return models ?? []
    }

    /// 新对话时使用的模型 ID。
    /// 优先 Gateway 默认模型 → 回退上次选择的模型 → 回退列表第一个。
    /// 设计意图：新建对话应使用服务端指定的默认模型，而非继承其他对话的选择。
    public var modelForNewConversation: UnifiedModel? {
        if let unifiedModels {
            if let unifiedDefaultModelID,
               unifiedModels.contains(where: { $0.id == unifiedDefaultModelID }) {
                return UnifiedModel(model: unifiedDefaultModelID, reasoningEffort: nil)
            }
            if let stored = lastSelectedModel,
               unifiedModels.contains(where: {
                   $0.model == stored.model
               }) {
                return stored
            }
            if let model = unifiedModels.first?.model, !model.isEmpty {
                return UnifiedModel(model: model, reasoningEffort: unifiedModels.first?.reasoningEffort)
            }
            return nil
        }
        if let def = gatewayDefaultModel, let models = gatewayModels,
           models.contains(where: {
               $0.model == def && $0.available != false
           }) {
            return UnifiedModel(model: def, reasoningEffort: nil)
        }
        if let stored = lastSelectedModel,
           let models = gatewayModels, models.contains(where: {
               $0.model == stored.model && $0.available != false
           }) {
            return stored
        }
        if let first = gatewayModels?.first(where: { $0.available != false }) {
            return UnifiedModel(model: first.id, reasoningEffort: nil)
        }
        return nil
    }

    /// Existing sessions that have never selected a model use the Gateway
    /// default, independent from the app-wide recent model used by new drafts.
    public var defaultModelForExistingConversation: String {
        if let unifiedModels {
            if let unifiedDefaultModelID,
               unifiedModels.contains(where: { $0.id == unifiedDefaultModelID }) {
                return unifiedDefaultModelID
            }
            return unifiedModels.first?.id ?? ""
        }
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

}

/// Next-input model intent. The wire payload is derived from this value; it is
/// never derived from `ConversationModelIdentity`.
public struct ComposerModelSelection: Equatable, Sendable {
    public let mode: ComposerModelSelectionMode
    public let model: UnifiedModel?

    public static let followDefault = ComposerModelSelection(mode: .followDefault, model: nil)

    public static func explicit(_ model: UnifiedModel) -> ComposerModelSelection {
        ComposerModelSelection(mode: .explicit, model: model)
    }

    /// Nil means "omit `model` from the request".
    public var wireModelID: String? {
        mode == .explicit ? model?.model : nil
    }

    /// Nil means "omit reasoning overrides from the request".
    public var reasoningEffort: ModelReasoningEffort? {
        mode == .explicit ? model?.reasoningEffort : nil
    }
}
