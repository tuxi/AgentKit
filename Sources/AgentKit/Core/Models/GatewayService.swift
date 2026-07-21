//
//  GatewayService.swift
//  AgentKit
//
//  由宿主 App 实现的 Gateway API 抽象。
//  ModelSettingsStore 通过此协议主动获取模型列表，
//  不再依赖宿主调用 setAvailableModels() 被动注入。
//

public protocol GatewayService: Sendable {

    /// 从 Gateway 获取可用模型列表及默认模型。
    /// ModelSettingsStore 在 init 后通过 refreshModels() 调用。
    func refreshModels() async throws -> ModelsResponse
}
