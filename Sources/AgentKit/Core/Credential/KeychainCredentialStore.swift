//
//  KeychainCredentialStore.swift
//  AgentKit
//
//  基于 Keychain 的 CredentialStore 实现。
//  单个 Keychain entry 存储整个 CredentialMap 的 JSON。
//

import Foundation
import os

/// Keychain 实现的 CredentialStore。
///
/// 在 Keychain 中以**单个 entry** 存储整个 `CredentialMap` 的 JSON。
/// 类似 AWS credential file 的设计 —— 一个文件包含所有 profile。
///
/// 为什么不拆成多个 entry：
/// - CredentialMap 不大（几十个 entry 顶天），单 entry 读写性能足够
/// - macOS Keychain 对单个 app 的 entry 数量有限制
/// - 原子读写（读-改-写 在一个 entry 内完成）
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let keychain: KeychainStore
    private let account = "credential_map"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let state = OSAllocatedUnfairLock(initialState: ())

    /// - Parameters:
    ///   - service: Keychain service identifier。默认使用 AgentKit 的 service。
    public init(service: String = "com.codeagent.credentials") {
        self.keychain = KeychainStore(service: service)
    }

    // MARK: - CredentialStore

    public func resolve(_ target: CredentialTarget) async throws -> Credential? {
        loadMap().entries[target]
    }

    public func all() async throws -> CredentialMap {
        loadMap()
    }

    public func set(_ credential: Credential, for target: CredentialTarget) async throws {
        let map = state.withLock {
            var map = loadMapUnsafe()
            map.entries[target] = credential
            return map
        }
        try persistMap(map)
    }

    public func remove(_ target: CredentialTarget) async throws {
        let map = state.withLock {
            var map = loadMapUnsafe()
            map.entries.removeValue(forKey: target)
            return map
        }
        try persistMap(map)
    }

    public func clear() async throws {
        keychain.remove(account)
    }

    // MARK: - Private

    private func loadMap() -> CredentialMap {
        state.withLock { loadMapUnsafe() }
    }

    /// 必须在 `state.withLock` 中调用。
    private func loadMapUnsafe() -> CredentialMap {
        guard let json = keychain.string(for: account),
              let data = json.data(using: .utf8) else {
            return CredentialMap()
        }
        do {
            return try decoder.decode(CredentialMap.self, from: data)
        } catch {
            return CredentialMap()
        }
    }

    private func persistMap(_ map: CredentialMap) throws {
        let data = try encoder.encode(map)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }
        keychain.set(json, for: account)
    }
}

// MARK: - Errors

public enum CredentialStoreError: Error, LocalizedError {
    case encodingFailed
    case notFound(CredentialTarget)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "凭据编码失败。"
        case .notFound(let t): return "未找到凭据：\(t.id)。"
        }
    }
}
