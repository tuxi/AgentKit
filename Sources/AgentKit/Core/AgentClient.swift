//
//  AgentClient.swift
//  AgentKit
//
//  向后兼容别名。新代码请直接使用 `RuntimeClient` 协议。
//  `DefaultAgentClient` 是 RuntimeClient 的唯一实现。
//

import Foundation

/// 向后兼容的类型别名。已迁移到 `RuntimeClient` 协议。
@available(*, deprecated, renamed: "RuntimeClient")
public typealias AgentClient = RuntimeClient

/// 向后兼容的工厂别名。
@available(*, deprecated, renamed: "DefaultAgentClient")
public typealias DefaultAgentClientDeprecated = DefaultAgentClient
