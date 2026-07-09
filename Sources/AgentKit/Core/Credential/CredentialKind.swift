//
//  CredentialKind.swift
//  AgentKit
//
//  Credential 在 HTTP 层的传输类型 —— 与 Go 侧 `credential.CredentialType` 对齐。
//  只描述 "如何放入 HTTP Header"，不描述 "凭证来自什么认证协议"。
//

import Foundation

/// credential 的 wire format 类型。
/// 与 Go 侧 `credential.CredentialType` 常量保持一一对应。
///
/// 为什么没有 `oauth2`：
///   OAuth2 是认证协议，不是 wire format。OAuth2 access token 在 HTTP 层
///   仍然是 `Authorization: Bearer <token>`。协议细节放在 `Credential.metadata` 中。
public enum CredentialKind: String, Codable, Sendable {
    /// `Authorization: Bearer <secret>`（JWT、API key、OAuth2 access token）
    case bearer = "bearer"
    /// 预留：AWS SigV4、mTLS client cert 等非 Bearer 机制
    case secret = "secret"
    /// 无需凭证（本地模型）
    case none = "none"
}
