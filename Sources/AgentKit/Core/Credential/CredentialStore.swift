//
//  CredentialStore.swift
//  AgentKit
//
//  AgentKit 的 credential 存储抽象。
//  实现方：KeychainCredentialStore（生产）、MemoryCredentialStore（测试/预览）。
//  纯 Foundation 协议，不依赖 UI 框架，可在任意线程调用。
//

import Foundation

/// AgentKit 的 credential 存储抽象。
///
/// 对应 Go 侧 `credential.Resolver` 接口，但职责不同：
///   - Go `Resolver` 是 "消费方"（Runtime 问 "我需要这个 target 的 credential"）
///   - Swift `CredentialStore` 是 "管理方"（AgentKit 负责保存/刷新/删除/注入）
///
/// AgentKit **不实现** Go 的 `Resolver` 接口。
/// 注入方向是单向的：`CredentialStore → CredentialMap → secretsJSON → Runtime`。
public protocol CredentialStore: Sendable {
    /// 获取单个 credential（async）。
    func resolve(_ target: CredentialTarget) async throws -> Credential?

    /// 获取所有 credential（用于构建 secretsJSON 注入 Runtime）。
    func all() async throws -> CredentialMap

    /// 写入/更新 credential。
    func set(_ credential: Credential, for target: CredentialTarget) async throws

    /// 删除指定 target 的 credential。
    func remove(_ target: CredentialTarget) async throws

    /// 清空所有 credential（登出时调用）。
    func clear() async throws

    /// 同步解析（用于 WebSocket 连接校验等不能 async 的上下文）。
    /// 默认返回 nil。实现方可覆盖以提供同步访问。
    func resolveSync(_ target: CredentialTarget) -> Credential?
}

// MARK: - Default impl

public extension CredentialStore {
    func resolveSync(_ target: CredentialTarget) -> Credential? { nil }
}
