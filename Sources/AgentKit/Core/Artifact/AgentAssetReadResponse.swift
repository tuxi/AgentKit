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

    public init(
        asset: AgentAssetRef,
        kind: String? = nil,
        content: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int64? = nil,
        truncated: Bool = false,
        source: String? = nil
    ) {
        self.asset = asset
        self.kind = kind
        self.content = content
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.truncated = truncated
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case asset, kind, content, source, truncated
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
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
}
