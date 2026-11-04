import Foundation

/// Runtime audit identity is observation, never a replacement for input settings.
public struct ModelSelectionIdentity: Decodable, Sendable, Equatable {
    public let requestedModel: String?
    public let resolvedModel: String?
    public let actualModel: String?
    public let provider: String?

    /// Pair the concrete served model with the configured provider alias.
    /// The resolved route is authoritative for that alias; `provider` on a
    /// request can instead name an adapter protocol.
    var modelRoute: String? {
        guard let actualModel, !actualModel.isEmpty else { return resolvedModel }
        let routeParts = resolvedModel?.split(separator: "/", maxSplits: 1) ?? []
        let alias = routeParts.count == 2 ? String(routeParts[0]) : provider
        guard let alias, !alias.isEmpty else { return actualModel }
        return actualModel.hasPrefix("\(alias)/") ? actualModel : "\(alias)/\(actualModel)"
    }

    enum CodingKeys: String, CodingKey {
        case requestedModel = "requested_model"
        case resolvedModel = "resolved_model"
        case actualModel = "actual_model"
        case provider
    }
}

public struct ConversationModelIdentity: Sendable, Equatable {
    public private(set) var turnID: String?
    public private(set) var resolvedModel: String?
    public private(set) var actualModel: String?
    public private(set) var actualTurnID: String?
    public private(set) var actualInvocationID: String?

    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .modelRequest(let turn, _, let request):
            if turnID != turn { resolvedModel = nil }
            turnID = turn
            if let resolved = request.selection?.resolvedModel, !resolved.isEmpty {
                resolvedModel = resolved
            } else if resolvedModel == nil, let model = request.modelName, !model.isEmpty {
                // Legacy wire IDs are a fallback, never overwrite a verified
                // namespaced route with a later request in this same Turn.
                resolvedModel = model
            }
        case .modelFinished(let turn, _, _, _, _, _, let invocation, let err, _, let selection):
            if let resolved = selection?.resolvedModel, !resolved.isEmpty {
                turnID = turn
                resolvedModel = resolved
            }
            guard err == nil, let actual = selection?.actualModel, !actual.isEmpty else { return }
            actualModel = actual
            actualTurnID = turn
            actualInvocationID = invocation
        default:
            break
        }
    }
}
