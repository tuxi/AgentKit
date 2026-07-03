//
//  AgentAssetReadResponse.swift
//  AgentKit
//
//  Runtime Asset Read API DTOs.
//

import Foundation

public struct AgentAssetPreviewResponse: Sendable, Hashable, Decodable {
    public let asset: AgentAssetRef
    public let kind: String?
    public let content: String?
    public let mimeType: String?
    public let sizeBytes: Int64?
    public let truncated: Bool
    public let source: String?
    public let metadata: [String: JSONValue]?

    public init(
        asset: AgentAssetRef,
        kind: String? = nil,
        content: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil,
        truncated: Bool = false,
        source: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.asset = asset
        self.kind = kind
        self.content = content
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.truncated = truncated
        self.source = source
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case asset, kind, content, source, truncated, metadata
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asset = try container.decode(AgentAssetRef.self, forKey: .asset)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.content = try container.decodeIfPresent(String.self, forKey: .content)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        self.truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }
}

public struct AgentAssetContentResponse: Sendable, Hashable, Decodable {
    public let asset: AgentAssetRef
    public let content: String
    public let mimeType: String?
    public let sizeBytes: Int64?
    public let truncated: Bool

    public init(
        asset: AgentAssetRef,
        content: String,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil,
        truncated: Bool = false
    ) {
        self.asset = asset
        self.content = content
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case asset, content, truncated
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asset = try container.decode(AgentAssetRef.self, forKey: .asset)
        self.content = try container.decode(String.self, forKey: .content)
        self.truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
    }
}
