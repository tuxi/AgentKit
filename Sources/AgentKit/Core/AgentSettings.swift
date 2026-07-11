//
//  AgentSettings.swift
//  AgentKit
//
//  端侧 runtime 的用户配置：API key 走 Keychain，模型走 UserDefaults。
//  两层共用同一组 key，单一真相源：
//    - `AgentSettings`（静态只读）：供 `AgentRuntime` 在非主线程读取（构造 secretsJSON / model）。
//    - `AgentSettingsStore`（@MainActor @Observable）：供设置页双向绑定。
//

import Foundation

public enum AgentSettings {

    // MARK: - Keys（单一真相源）

    public static let keychainService = "com.codeagent.runtime"
    public static let apiKeyAccount = "deepseek_api_key"
    public static let tavilyApiKeyAccount = "tavily_api_key"
    public static let modelDefaultsKey = "code_agent.runtime.model"

    static let keychain = KeychainStore(service: keychainService)

    /// 可选模型 = bundled config（Resources/config.yaml）里注册的别名（`modelName` 按别名选择，
    /// 不是 provider 模型串）。空串 = 用 config.default_model（当前 = deepseek-pro）。
    /// ⚠️ 必须与 Resources/config.yaml 的 `models:` 别名保持同步（暂无 YAML 解析，手工对齐）。
    public static let availableModels: [String] = ["", "deepseek", "deepseek-pro"]

    // MARK: - Reads（runtime 用）

    public static var apiKey: String { keychain.string(for: apiKeyAccount) ?? "" }
    public static var tavilyApiKey: String { keychain.string(for: tavilyApiKeyAccount) ?? "" }

    /// 已选模型别名或 Gateway 模型 ID。
    /// 若是 Gateway 模式，model 是 Gateway 原生 ID（如 `"deepseek-v4-pro"`）。
    /// 若是 BYOK 模式，model 需在 `availableModels` 中。
    /// 回退规则：先在 `availableModels` 中查找 → 若非空且不在列表中 → 保留原值（Gateway ID）。
    public static var model: String {
        let stored = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        // 非空且在硬编码别名列表中 → 直接使用
        if availableModels.contains(stored) { return stored }
        // 非空但不在别名列表 → 可能是 Gateway 模型 ID，保留原值
        if !stored.isEmpty { return stored }
        // 空 → 回退默认
        return ""
    }

    /// MobileStart 的 `secretsJSON`。无 key → 返回 `{}`（runtime 将缺凭证，UI 应提示用户填写）。
    /// 用 JSONEncoder 转义，避免 key 中的特殊字符破坏 JSON。
    public static func secretsJSON() -> String {
        let key = apiKey
        let tavilyApiKey = tavilyApiKey
        guard !key.isEmpty else { return "{}" }
        guard let data = try? JSONEncoder().encode(["DEEPSEEK_API_KEY": key, "TAVILY_API_KEY": tavilyApiKey]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// MARK: - UI store

@MainActor
@Observable
public final class AgentSettingsStore {

    public var apiKey: String
    public var tavilyApiKey: String
    public var model: String

    public init() {
        self.apiKey = AgentSettings.apiKey
        self.tavilyApiKey = AgentSettings.tavilyApiKey
        self.model = AgentSettings.model
    }

    /// 是否已配置 API key（去空白后非空）。
    public var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 持久化到 Keychain / UserDefaults。
    public func save() {
        AgentSettings.keychain.set(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            for: AgentSettings.apiKeyAccount
        )
        AgentSettings.keychain.set(
            tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            for: AgentSettings.tavilyApiKeyAccount
        )
        UserDefaults.standard.set(model, forKey: AgentSettings.modelDefaultsKey)
    }
}
