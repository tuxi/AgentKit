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
///   - `runtime_access` — external Runtime Server access (never injected as a
///     model Provider credential)
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

    /// Decodes the stable `namespace/name` representation used by Keychain
    /// accounts and Runtime `secretsJSON` keys.
    public init?(id: String) {
        guard let separator = id.firstIndex(of: "/") else { return nil }
        let namespacePart = String(id[..<separator])
        let namePart = String(id[id.index(after: separator)...])
        guard !namespacePart.isEmpty, !namePart.isEmpty else { return nil }
        self.namespace = namespacePart.removingPercentEncoding ?? namespacePart
        self.name = namePart.removingPercentEncoding ?? namePart
    }

    // MARK: - Presets

    public static let gateway = CredentialTarget(namespace: "gateway", name: "default")

    public static func llm(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "llm", name: name)
    }

    public static func mcp(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "mcp", name: name)
    }

    public static func runtimeAccess(_ connectionID: String) -> CredentialTarget {
        CredentialTarget(namespace: "runtime_access", name: connectionID)
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
    /// 扁平化（connection-flattening）期间此格式仍是**持久化身份**（Keychain
    /// account、UserDefaults、transcript 引用），不得改变。
    public var id: String {
        var componentAllowed = CharacterSet.urlPathAllowed
        componentAllowed.remove(charactersIn: "/")
        let escapedNamespace = namespace.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? namespace
        let escapedName = name.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? name
        return "\(escapedNamespace)/\(escapedName)"
    }

    /// 扁平化后的 flat connection id（v2 secretsJSON key，bridging 期间与 `id` 并存）。
    ///
    /// 规则（与 runtime 的 connection-id 方案对齐）：
    ///   - `gateway/default` → `gateway`
    ///   - `llm/<connectionID>` / `mcp/<name>` → `<name>`
    ///
    /// 注意：`llm/foo` 与 `mcp/foo` 会得到相同的 flat key；dual 模式下后者覆盖前者，
    /// 调用方应避免同名 target 并存。
    public var flatID: String {
        switch namespace {
        case "gateway": return "gateway"
        default: return name
        }
    }
}

// MARK: - CustomStringConvertible

extension CredentialTarget: CustomStringConvertible {
    public var description: String { id }
}
