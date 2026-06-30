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
    static let modelDefaultsKey = "code_agent.runtime.model"

    static let keychain = KeychainStore(service: keychainService)

    /// 可选模型 = bundled config（Resources/config.yaml）里注册的别名（`modelName` 按别名选择，
    /// 不是 provider 模型串）。空串 = 用 config.default_model（当前 = deepseek-pro）。
    /// ⚠️ 必须与 Resources/config.yaml 的 `models:` 别名保持同步（暂无 YAML 解析，手工对齐）。
    public static let availableModels: [String] = ["", "deepseek", "deepseek-pro"]

    // MARK: - Reads（runtime 用）

    public static var apiKey: String { keychain.string(for: apiKeyAccount) ?? "" }

    /// 已选模型别名。**清洗**：若持久化的值不在 `availableModels`（例如旧版本存过的非法名）
    /// → 回退到 ""，避免把 runtime 不认得的 modelName 传给 MobileStart 导致启动崩溃。
    public static var model: String {
        let stored = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        return availableModels.contains(stored) ? stored : ""
    }

    /// MobileStart 的 `secretsJSON`。无 key → 返回 `{}`（runtime 将缺凭证，UI 应提示用户填写）。
    /// 用 JSONEncoder 转义，避免 key 中的特殊字符破坏 JSON。
    public static func secretsJSON() -> String {
        let key = apiKey
        guard !key.isEmpty else { return "{}" }
        guard let data = try? JSONEncoder().encode(["DEEPSEEK_API_KEY": key]),
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
    public var model: String

    public init() {
        self.apiKey = AgentSettings.apiKey
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
        UserDefaults.standard.set(model, forKey: AgentSettings.modelDefaultsKey)
    }
}
