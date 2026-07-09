//
//  CredentialTarget.swift
//  AgentKit
//
//  唯一标识一个 credential —— 与 Go 侧 `credential.Target` 对齐。
//

import Foundation

/// 唯一标识一个 credential target。
///
/// 为什么叫 `namespace` 而不是 `type`：
///   `Credential` 自身也有 `kind` 字段（`CredentialKind`），如果 Target 也用 `type`
///   会产生不可接受的歧义。
///
/// 命名空间约定：
///   - `gateway` — Agent Gateway
///   - `llm`     — BYOK 直连 LLM provider
///   - `mcp`     — MCP server OAuth
///
/// 注意：不存在 `search` namespace。web search 是 Gateway 的实现细节，
/// Runtime 不应该感知底层用的是 Tavily/Google/Bing —— 统一走 `gateway/default`。
public struct CredentialTarget: Hashable, Codable, Sendable {
    /// 命名空间：gateway | llm | mcp
    public let namespace: String
    /// 实例名称：default | deepseek | openai | anthropic | github
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    // MARK: - Presets

    public static let gateway = CredentialTarget(namespace: "gateway", name: "default")

    public static func llm(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "llm", name: name)
    }

    public static func mcp(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "mcp", name: name)
    }
}

// MARK: - Identifiable

extension CredentialTarget: Identifiable {
    /// 稳定编码的 target 标识符。
    ///
    /// 使用 `addingPercentEncoding(.urlPathAllowed)` 避免 namespace 或 name
    /// 中包含 `/` 导致解析歧义。
    /// 例如 `github.enterprise.com/org/project` → `github.enterprise.com%2Forg%2Fproject`。
    ///
    /// **此方法需与 Go 侧 `Target.String()` 保持完全一致。**
    public var id: String {
        let escapedNamespace = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let escapedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "\(escapedNamespace)/\(escapedName)"
    }
}

// MARK: - CustomStringConvertible

extension CredentialTarget: CustomStringConvertible {
    public var description: String { id }
}
