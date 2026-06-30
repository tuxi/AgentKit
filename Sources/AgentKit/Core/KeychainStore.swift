//
//  KeychainStore.swift
//  AgentKit
//
//  极简 Keychain string 存取（Sendable，可在任意线程调用）。
//  用于持久化 API key 等敏感信息——不进 UserDefaults、不进源码。
//

import Foundation
import Security

public struct KeychainStore: Sendable {

    public let service: String

    public init(service: String) {
        self.service = service
    }

    // MARK: - Read

    /// 读取某 account 下的字符串值；不存在 / 解码失败返回 nil。
    public func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Write

    /// upsert：value 为空/nil 时删除该条目。
    @discardableResult
    public func set(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else { return remove(account) }
        let data = Data(value.utf8)
        let base = baseQuery(account)

        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        } else {
            var add = base
            add[kSecValueData as String] = data
            // AfterFirstUnlock：App 在后台被唤醒（scenePhase .active）时也能读到 key，
            // 满足 AgentRuntime.start() 在前台恢复时读取 secrets 的需要。
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    @discardableResult
    public func remove(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
