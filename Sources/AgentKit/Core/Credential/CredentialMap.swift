//
//  CredentialMap.swift
//  AgentKit
//
//  一组 credential 的不可变快照。用于序列化到 Keychain / 构造 secretsJSON。
//

import Foundation

/// 一组 credential 的不可变快照。
///
/// 在 Keychain 中以单个 entry 存储整个 map 的 JSON。
/// 注入 Runtime 时通过 `toSecretsJSON()` 转为 Go Runtime 能理解的格式。
public struct CredentialMap: Codable, Sendable {
    public var entries: [CredentialTarget: Credential]

    // MARK: - Init

    public init(entries: [CredentialTarget: Credential] = [:]) {
        self.entries = entries
    }

    // MARK: - Codable

    /// Codable 不支持 [CredentialTarget: Credential] 作为顶层 key（JSON key 必须是 string）。
    /// 内部转换为 `[String: Credential]` 数组格式。
    private struct Entry: Codable {
        let target: CredentialTarget
        let credential: Credential
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let list = try container.decode([Entry].self)
        var dict: [CredentialTarget: Credential] = [:]
        for entry in list {
            dict[entry.target] = entry.credential
        }
        self.entries = dict
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let list = entries.map { Entry(target: $0.key, credential: $0.value) }
        try container.encode(list)
    }

    // MARK: - secretsJSON

    /// secretsJSON 顶层 key 的编码模式（connection-flattening bridging 期）。
    ///
    /// - `namespaced`: v1 的 `{namespace}/{name}`（`gateway/default`、`llm/deepseek`）——
    ///   持久化身份，默认模式，输出与历史字节一致。
    /// - `flat`: v2 扁平 connection id（`gateway`、`deepseek`）。
    /// - `dual`: bridging 期同时输出两种 key；flat key 追加在后，因此当多个
    ///   namespace 的 name 相同（如 `llm/foo` 与 `mcp/foo`）时 flat 后者覆盖前者。
    public enum SecretsJSONKeyMode: String, Sendable {
        case namespaced
        case flat
        case dual
    }

    /// 默认（v1）模式：`{namespace}/{name}` key，输出与历史完全一致。
    public func toSecretsJSON() -> String {
        toSecretsJSON(keyMode: .namespaced)
    }

    /// 转为 Runtime 能理解的 secretsJSON 格式。
    ///
    /// key = `CredentialTarget.id`（namespace/name，url.PathEscape 编码）或
    /// `CredentialTarget.flatID`（v2 扁平 connection id），由 `keyMode` 决定。
    /// value = Go credential wire JSON 的字符串（`type` / `secret` /
    /// `expires_at`，不含 metadata），**三种模式下 value 形状字节一致**。
    /// 顶层保持 `[String:String]`，兼容 `MobileStart` 的 gomobile 边界；
    /// Go Runtime 会再解析字符串内的对象。
    ///
    /// **关键：`refresh_token` 永不进入 Runtime**。
    public func toSecretsJSON(keyMode: SecretsJSONKeyMode) -> String {
        struct RuntimeCredential: Encodable {
            let type: String
            let secret: String
            let expiresAt: Int64?

            enum CodingKeys: String, CodingKey {
                case type
                case secret
                case expiresAt = "expires_at"
            }
        }

        let encoder = JSONEncoder()
        var dict: [String: String] = [:]
        for (target, cred) in entries {
            let wire = RuntimeCredential(
                type: cred.kind.rawValue,
                secret: cred.secret,
                expiresAt: cred.expiresAt.map { Int64($0.timeIntervalSince1970) }
            )
            guard let data = try? encoder.encode(wire),
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }
            switch keyMode {
            case .namespaced:
                dict[target.id] = value
            case .flat:
                dict[target.flatID] = value
            case .dual:
                dict[target.id] = value
                dict[target.flatID] = value
            }
        }
        guard let data = try? encoder.encode(dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Subscript

    public subscript(target: CredentialTarget) -> Credential? {
        get { entries[target] }
        set {
            if let newValue {
                entries[target] = newValue
            } else {
                entries.removeValue(forKey: target)
            }
        }
    }

    /// 是否为空（无任何凭据）。
    public var isEmpty: Bool { entries.isEmpty }
}
