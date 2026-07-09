//
//  Credential.swift
//  AgentKit
//
//  凭据值 —— 与 Go 侧 `credential.Credential` 对齐。
//

import Foundation

/// 访问某个 Target 服务所需的凭据。
///
/// 字段 `secret` 对应 Go 的 `Secret`，语义精确表达 "这是不可展示的机密数据"。
///
/// 包含可选的 `expiresAt` 用于过期判断。
/// `metadata` 存储 `refresh_token` 等 AgentKit 内部状态 —— **禁止注入 Runtime**。
public struct Credential: Codable, Sendable {
    /// wire format 类型（bearer / secret / none）
    public let kind: CredentialKind
    /// 凭据机密值。不可展示、不可日志输出。
    public let secret: String
    /// 过期时间。nil = 永不过期（如静态 API key）。
    public let expiresAt: Date?
    /// 仅 AgentKit 使用的附加数据（refresh_token、scope 等）。
    /// **禁止** 注入到 Runtime —— `strippedForInjection()` 会剥离此字段。
    public var metadata: [String: String]

    // MARK: - Init

    public init(
        kind: CredentialKind,
        secret: String,
        expiresAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.secret = secret
        self.expiresAt = expiresAt
        self.metadata = metadata
    }

    // MARK: - Expiry

    /// 是否已过期。nil expiresAt = 永不过期。
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// 将在指定秒数内过期（用于预刷新判断）。
    public func expiresWithin(seconds: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(seconds) >= expiresAt
    }

    // MARK: - Injection

    /// 剥离 metadata 的纯凭据副本 —— 用于注入 Runtime。
    ///
    /// Runtime 只需要 kind + secret + expiresAt，不需要 refresh_token 等
    /// AgentKit 内部状态。此方法确保 Runtime 永远不会接触到 refresh_token。
    public func strippedForInjection() -> Credential {
        Credential(kind: kind, secret: secret, expiresAt: expiresAt, metadata: [:])
    }
}

// MARK: - CustomDebugStringConvertible

extension Credential: CustomDebugStringConvertible {
    public var debugDescription: String {
        let kindStr: String
        switch kind {
        case .bearer: kindStr = "bearer"
        case .secret: kindStr = "secret"
        case .none:   kindStr = "none"
        }
        let secretPreview = secret.isEmpty ? "(empty)" : "\(secret.prefix(4))***"
        let expiry = expiresAt.map { "expires=\($0)" } ?? "noexpiry"
        return "Credential(\(kindStr), \(secretPreview), \(expiry))"
    }
}
