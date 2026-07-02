//
//  AgentAssetRef.swift
//  AgentKit
//
//  Structured clickable asset references from agent-wire tool_finished events.
//

import Foundation

public struct AgentAssetRef: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let kind: String
    public let uri: String?
    public let displayName: String?
    public let workspaceID: String?
    public let workspaceRelativePath: String?
    public let absolutePath: String?
    public let range: AgentAssetRange?
    public let preview: String?
    public let mimeType: String?
    public let sourceTurnID: String?
    public let sourceCallID: String?
    public let metadata: [String: JSONValue]?

    public init(
        id: String,
        kind: String,
        uri: String? = nil,
        displayName: String? = nil,
        workspaceID: String? = nil,
        workspaceRelativePath: String? = nil,
        absolutePath: String? = nil,
        range: AgentAssetRange? = nil,
        preview: String? = nil,
        mimeType: String? = nil,
        sourceTurnID: String? = nil,
        sourceCallID: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.uri = uri
        self.displayName = displayName
        self.workspaceID = workspaceID
        self.workspaceRelativePath = workspaceRelativePath
        self.absolutePath = absolutePath
        self.range = range
        self.preview = preview
        self.mimeType = mimeType
        self.sourceTurnID = sourceTurnID
        self.sourceCallID = sourceCallID
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, uri, preview, metadata
        case displayName = "display_name"
        case workspaceID = "workspace_id"
        case workspaceRelativePath = "workspace_relative_path"
        case absolutePath = "absolute_path"
        case range
        case mimeType = "mime_type"
        case sourceTurnID = "source_turn_id"
        case sourceCallID = "source_call_id"
    }
}

public struct AgentAssetRange: Sendable, Hashable, Codable {
    public let startLine: Int?
    public let startColumn: Int?
    public let endLine: Int?
    public let endColumn: Int?

    public init(
        startLine: Int? = nil,
        startColumn: Int? = nil,
        endLine: Int? = nil,
        endColumn: Int? = nil
    ) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case startColumn = "start_column"
        case endLine = "end_line"
        case endColumn = "end_column"
    }
}
