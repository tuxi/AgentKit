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

    /// 转为 Runtime 能理解的 secretsJSON 格式。
    ///
    /// key = `CredentialTarget.id`（url.PathEscape 编码）。
    /// value = stripped `Credential` JSON（不含 metadata）。
    ///
    /// **关键：`refresh_token` 永不进入 Runtime**。
    public func toSecretsJSON() -> String {
        var dict: [String: Credential] = [:]
        for (target, cred) in entries {
            dict[target.id] = cred.strippedForInjection()
        }
        guard let data = try? JSONEncoder().encode(dict),
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
