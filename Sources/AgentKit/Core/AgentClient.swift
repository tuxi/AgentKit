//
//  AgentClient.swift
//  AgentKit
//
//  向后兼容别名。新代码请直接使用 `RuntimeClient` 协议。
//  `DefaultAgentClient` 现在是 thin facade over `AgentTransport`。
//
//  Protocol: AgentKit Runtime Protocol v1.1
//
//  架构：
//    UI → RuntimeClient → DefaultAgentClient (facade)
//       → AgentTransport → CodeAgentTransport (impl)
//

import Foundation

/// 向后兼容的类型别名。已迁移到 `RuntimeClient` 协议。
@available(*, deprecated, renamed: "RuntimeClient")
public typealias AgentClient = RuntimeClient

/// 向后兼容的工厂别名。
@available(*, deprecated, renamed: "DefaultAgentClient")
public typealias DefaultAgentClientDeprecated = DefaultAgentClient
