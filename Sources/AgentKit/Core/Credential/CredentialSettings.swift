//
//  CredentialSettings.swift
//  AgentKit
//
//  从旧 AgentSettings（单 API key）到新 CredentialStore 的迁移 + 便捷访问。
//

import Foundation

/// 全局 credential 配置入口。
///
/// 与 `AgentSettings` 平行共存。
/// - `AgentSettings` — 旧路径（单 DeepSeek key），继续支持
/// - `CredentialSettings` — 新路径（CredentialStore），推荐使用
public enum CredentialSettings {

    /// 全局 credential store。
    /// 默认使用内存实现（测试/预览安全）。宿主 App 应在启动时注入自己的实现，
    /// 如 KeychainCredentialStore 或基于 AuthManager 的凭证提供者。
    nonisolated(unsafe) public static var store: any CredentialStore = MemoryCredentialStore()

    private static let migrationKey = "credential.migrated_v1"

    // MARK: - Migration

    /// 从旧 Keychain entries 迁移到 CredentialMap。
    ///
    /// 执行一次后设置标记，不再执行。
    /// - 旧 DEEPSEEK_API_KEY → `CredentialTarget.llm("deepseek")`
    /// - 旧 Tavily key **不迁移** → web search 是 Gateway 的实现细节
    public static func migrateFromLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        let legacyKey = AgentSettings.apiKey
        guard !legacyKey.isEmpty else { return }

        let cred = Credential(
            kind: .bearer,
            secret: legacyKey,
            expiresAt: nil,
            metadata: [:]
        )
        Task {
            try? await store.set(cred, for: .llm("deepseek"))
        }
    }

    // MARK: - Convenience

    /// 当前有效的 secretsJSON（v1 namespaced 模式，仅来自 CredentialStore）。
    ///
    /// 决策 A2.3（connection-flattening）：**删除** 旧 `AgentSettings.secretsJSON()`
    /// env-name key 通道（`DEEPSEEK_API_KEY` 等）。env-name 无法映射到扁平
    /// connection id，新注入通道只认 connection id；旧 Keychain 值由
    /// `migrateFromLegacyIfNeeded()` 迁移到 CredentialMap。空 store → `"{}"`。
    public static func currentSecretsJSON() async -> String {
        let map = (try? await store.all()) ?? CredentialMap()
        return map.toSecretsJSON()
    }
}
