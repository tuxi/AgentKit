import Foundation

/// A complete observation snapshot for one context transaction. Missing usage
/// is distinct from zero, and preparation is provisional until committed.
public struct ContextMaintenance: Codable, Sendable, Equatable {
    public let operationID: String
    public let phase: String
    public let status: String
    public let committed: Bool
    public let beforeTokens: Int?
    public let afterTokens: Int?
    public let estimatedSavedTokens: Int?
    public let clearedResults: Int
    public let summaryGenerated: Bool
    public let measurementSource: String
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case phase, status, committed, error
        case beforeTokens = "before_tokens"
        case afterTokens = "after_tokens"
        case estimatedSavedTokens = "estimated_saved_tokens"
        case clearedResults = "cleared_results"
        case summaryGenerated = "summary_generated"
        case measurementSource = "measurement_source"
    }
}
