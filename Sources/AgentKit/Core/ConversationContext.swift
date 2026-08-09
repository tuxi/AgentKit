//
//  ConversationContext.swift
//  AgentKit
//
//  DTO for `GET /v1/conversations/{id}/context` — 会话上下文窗口快照。
//  客户端据此实时获知距离压缩还有多远（usage_pct = prompt_tokens / context_window * 100）。
//

import Foundation

/// 会话上下文窗口快照（`GET /v1/conversations/{id}/context`）。
public struct ConversationContextSnapshot: Sendable, Codable, Hashable {
    public let model: ConversationContextModel
    public let current: ConversationContextCurrent
    public let compaction: ConversationContextCompaction
    public let structure: ConversationContextStructure

    public init(
        model: ConversationContextModel,
        current: ConversationContextCurrent,
        compaction: ConversationContextCompaction,
        structure: ConversationContextStructure
    ) {
        self.model = model
        self.current = current
        self.compaction = compaction
        self.structure = structure
    }

    enum CodingKeys: String, CodingKey {
        case model, current, compaction, structure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(ConversationContextModel.self, forKey: .model)
        current = try c.decode(ConversationContextCurrent.self, forKey: .current)
        compaction = try c.decode(ConversationContextCompaction.self, forKey: .compaction)
        structure = try c.decode(ConversationContextStructure.self, forKey: .structure)
    }
}

/// 当前模型及其上下文窗口配置。
public struct ConversationContextModel: Sendable, Codable, Hashable {
    public let name: String
    public let contextWindow: Int
    public let compactThreshold: Int
    public let compactRatio: Double

    public init(name: String, contextWindow: Int, compactThreshold: Int, compactRatio: Double) {
        self.name = name
        self.contextWindow = contextWindow
        self.compactThreshold = compactThreshold
        self.compactRatio = compactRatio
    }

    enum CodingKeys: String, CodingKey {
        case name
        case contextWindow = "context_window"
        case compactThreshold = "compact_threshold"
        case compactRatio = "compact_ratio"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        contextWindow = try c.decode(Int.self, forKey: .contextWindow)
        compactThreshold = try c.decode(Int.self, forKey: .compactThreshold)
        compactRatio = try c.decode(Double.self, forKey: .compactRatio)
    }
}

/// 当前上下文占用。
public struct ConversationContextCurrent: Sendable, Codable, Hashable {
    public let promptTokens: Int
    /// 已用百分比：`prompt_tokens / context_window * 100`（与 Claude Code 显示一致）。
    public let usagePct: Double
    /// 触发压缩的阈值百分比。
    public let thresholdPct: Double

    public init(promptTokens: Int, usagePct: Double, thresholdPct: Double) {
        self.promptTokens = promptTokens
        self.usagePct = usagePct
        self.thresholdPct = thresholdPct
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case usagePct = "usage_pct"
        case thresholdPct = "threshold_pct"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decode(Int.self, forKey: .promptTokens)
        usagePct = try c.decode(Double.self, forKey: .usagePct)
        thresholdPct = try c.decode(Double.self, forKey: .thresholdPct)
    }
}

/// 上下文压缩历史汇总。
public struct ConversationContextCompaction: Sendable, Codable, Hashable {
    public let totalCount: Int
    public let totalSavedTokens: Int
    /// 最近一次压缩；从未压缩过时为 nil。
    public let last: ConversationContextCompactEntry?

    public init(totalCount: Int, totalSavedTokens: Int, last: ConversationContextCompactEntry?) {
        self.totalCount = totalCount
        self.totalSavedTokens = totalSavedTokens
        self.last = last
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case totalSavedTokens = "total_saved_tokens"
        case last
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try c.decode(Int.self, forKey: .totalCount)
        totalSavedTokens = try c.decode(Int.self, forKey: .totalSavedTokens)
        last = try c.decodeIfPresent(ConversationContextCompactEntry.self, forKey: .last)
    }
}

/// 单次压缩记录。
public struct ConversationContextCompactEntry: Sendable, Codable, Hashable {
    public let beforeTokens: Int
    public let afterTokens: Int
    public let savedTokens: Int
    public let ratio: Double
    public let summaryChars: Int
    public let ineffective: Bool
    /// ISO-8601 时间戳（如 `2026-08-09T12:34:56.789Z`）。
    public let at: String

    public init(
        beforeTokens: Int,
        afterTokens: Int,
        savedTokens: Int,
        ratio: Double,
        summaryChars: Int,
        ineffective: Bool,
        at: String
    ) {
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.savedTokens = savedTokens
        self.ratio = ratio
        self.summaryChars = summaryChars
        self.ineffective = ineffective
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case beforeTokens = "before_tokens"
        case afterTokens = "after_tokens"
        case savedTokens = "saved_tokens"
        case ratio
        case summaryChars = "summary_chars"
        case ineffective
        case at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beforeTokens = try c.decode(Int.self, forKey: .beforeTokens)
        afterTokens = try c.decode(Int.self, forKey: .afterTokens)
        savedTokens = try c.decode(Int.self, forKey: .savedTokens)
        ratio = try c.decode(Double.self, forKey: .ratio)
        summaryChars = try c.decode(Int.self, forKey: .summaryChars)
        ineffective = try c.decode(Bool.self, forKey: .ineffective)
        at = try c.decode(String.self, forKey: .at)
    }
}

/// 会话结构概要。
public struct ConversationContextStructure: Sendable, Codable, Hashable {
    public let messageCount: Int
    public let estimatedTokens: Int
    public let hasSummary: Bool
    public let summaryChars: Int

    public init(messageCount: Int, estimatedTokens: Int, hasSummary: Bool, summaryChars: Int) {
        self.messageCount = messageCount
        self.estimatedTokens = estimatedTokens
        self.hasSummary = hasSummary
        self.summaryChars = summaryChars
    }

    enum CodingKeys: String, CodingKey {
        case messageCount = "message_count"
        case estimatedTokens = "estimated_tokens"
        case hasSummary = "has_summary"
        case summaryChars = "summary_chars"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        estimatedTokens = try c.decode(Int.self, forKey: .estimatedTokens)
        hasSummary = try c.decode(Bool.self, forKey: .hasSummary)
        summaryChars = try c.decodeIfPresent(Int.self, forKey: .summaryChars) ?? 0
    }
}
