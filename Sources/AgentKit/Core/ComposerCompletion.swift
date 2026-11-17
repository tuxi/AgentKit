import Foundation

public struct ComposerQuery: Codable, Sendable {
    public var sessionID: String?
    public var workspacePath: String?
    public var kind: String
    public var query: String
    public var revision: Int64
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", workspacePath = "workspace_path", kind, query, revision }
    public init(sessionID: String? = nil, workspacePath: String? = nil, kind: String, query: String, revision: Int64) {
        self.sessionID = sessionID; self.workspacePath = workspacePath; self.kind = kind; self.query = query; self.revision = revision
    }
}

public struct ComposerCompletionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var label: String
    public var detail: String
    public var insertText: String
    public var action: String
    public var relativePath: String?
    public var sessionID: String?
    public var contextText: String?
    public var contextRevision: String?
    enum CodingKeys: String, CodingKey { case id, kind, label, detail, action, insertText = "insert_text", relativePath = "relative_path", sessionID = "session_id", contextText = "context_text", contextRevision = "context_revision" }
}

public struct ComposerCompletionResult: Codable, Sendable {
    public var schema: String
    public var revision: Int64
    public var items: [ComposerCompletionItem]
    public var truncated: Bool
}

public protocol ComposerReading: Sendable {
    func composerValidatePaths(_ scope: ComposerQuery, paths: [String]) async throws
    func composerReference(_ scope: ComposerQuery, sourceSessionID: String) async throws -> ComposerReferenceSnapshot
    func composerQuery(_ query: ComposerQuery) async throws -> ComposerCompletionResult
    func composerSuggestion(sessionID: String, turnID: String) async throws -> ComposerSuggestion
}

extension ComposerReading {
    public func composerValidatePaths(_ scope: ComposerQuery, paths: [String]) async throws { throw RuntimeHTTPError.unsupported }
    public func composerReference(_ scope: ComposerQuery, sourceSessionID: String) async throws -> ComposerReferenceSnapshot { throw RuntimeHTTPError.unsupported }
    public func composerSuggestion(sessionID: String, turnID: String) async throws -> ComposerSuggestion { throw RuntimeHTTPError.unsupported }
    public func composerQuery(_ query: ComposerQuery) async throws -> ComposerCompletionResult { throw RuntimeHTTPError.unsupported }
}

/// UTF-16 ranges match NSTextView. Only explicit menu selections create tokens.
public struct ComposerToken: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var location: Int
    public var length: Int
    public var workspacePath: String?
    public var item: ComposerCompletionItem
    public init(location: Int, length: Int, item: ComposerCompletionItem, workspacePath: String? = nil) {
        self.id = UUID(); self.location = location; self.length = length; self.item = item; self.workspacePath = workspacePath
    }
}

public struct ComposerFileReference: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var path: String
    public var workspacePath: String?
    public var relativePath: String?
    public var isDirectory: Bool
    public init(path: String, workspacePath: String?, isDirectory: Bool) {
        self.path = path; self.workspacePath = workspacePath; self.isDirectory = isDirectory
        if let root = workspacePath, path.hasPrefix(root + "/") { relativePath = String(path.dropFirst(root.count + 1)) }
    }
    public var displayPath: String { relativePath ?? (path as NSString).abbreviatingWithTildeInPath }
    public var typeLabel: String { isDirectory ? "FOLDER" : ((path as NSString).pathExtension.isEmpty ? "FILE" : (path as NSString).pathExtension.uppercased()) }
}

public struct ComposerSuggestion: Codable, Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public let historyRevision: String
    public let text: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", turnID = "turn_id", historyRevision = "history_revision", text }
}

public struct ComposerReferenceSnapshot: Codable, Sendable {
    public let sessionID: String
    public let historyRevision: String
    public let label: String
    public let contextText: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", historyRevision = "history_revision", label, contextText = "context_text" }
}

public struct ComposerSubmissionIssue: Equatable, Sendable {
    public let key: ConversationLocalStateKey
    public let message: String
}
