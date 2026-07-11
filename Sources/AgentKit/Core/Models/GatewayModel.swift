//
//  GatewayModel.swift
//  AgentKit
//
//  Gateway 模型列表相关数据模型。纯数据结构，不依赖任何账号或网络层。
//

import Foundation

// MARK: - Gateway Model Types

/// Gateway 返回的可用模型。
public struct GatewayModel: Codable, Sendable, Identifiable {
    /// 模型 ID，用于 `POST /chat/completions` 的 `model` 字段。如 `"deepseek-v4-pro"`
    public let id: String
    /// UI 展示名称。如 `"DeepSeek V4 Pro"`
    public let displayName: String
    /// 提供商
    public let provider: String
    /// 上下文窗口
    public let contextWindow: Int?
    /// 是否支持流式
    public let supportsStreaming: Bool?
    /// 是否支持 tool calling
    public let supportsToolCalls: Bool?
    /// 模型分类
    public let category: String?
    /// 当前用户是否可用
    public let available: Bool?
}

/// Gateway `GET /agent/models` 的响应 data 部分。
public struct ModelsResponse: Codable, Sendable {
    public let models: [GatewayModel]
    public let defaultModel: String
}
