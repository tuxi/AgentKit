//
//  AgentTextAnnotation.swift
//  AgentKit
//
//  Structured links for assistant markdown text from agent-wire turn_finished.
//

import Foundation

public struct AgentTextAnnotation: Sendable, Hashable, Codable {
    public let assetID: String
    public let kind: String
    public let text: String
    public let startByte: Int?
    public let endByte: Int?
    public let startUTF16: Int?
    public let endUTF16: Int?
    public let sourceTurnID: String?
    public let sourceCallID: String?

    public init(
        assetID: String,
        kind: String,
        text: String,
        startByte: Int? = nil,
        endByte: Int? = nil,
        startUTF16: Int? = nil,
        endUTF16: Int? = nil,
        sourceTurnID: String? = nil,
        sourceCallID: String? = nil
    ) {
        self.assetID = assetID
        self.kind = kind
        self.text = text
        self.startByte = startByte
        self.endByte = endByte
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.sourceTurnID = sourceTurnID
        self.sourceCallID = sourceCallID
    }

    enum CodingKeys: String, CodingKey {
        case kind, text
        case assetID = "asset_id"
        case startByte = "start_byte"
        case endByte = "end_byte"
        case startUTF16 = "start_utf16"
        case endUTF16 = "end_utf16"
        case sourceTurnID = "source_turn_id"
        case sourceCallID = "source_call_id"
    }
}
