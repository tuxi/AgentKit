//
//  MemoryCredentialStore.swift
//  AgentKit
//
//  内存实现的 CredentialStore —— 用于单元测试和 SwiftUI Preview。
//

import Foundation

/// 内存 CredentialStore 实现。
///
/// 用于：
/// - 单元测试（不依赖 Keychain）
/// - SwiftUI Preview（不触发 Keychain 权限弹窗）
/// - CI 环境
public actor MemoryCredentialStore: CredentialStore {
    
    private var entries: [CredentialTarget: Credential] = [:]

    public init() {}

    public func resolve(_ target: CredentialTarget) async throws -> Credential? {
        entries[target]
    }
    
    public func all() async throws -> CredentialMap {
        CredentialMap(entries: entries)
    }

    public func set(_ credential: Credential, for target: CredentialTarget) async throws {
        entries[target] = credential
    }

    public func remove(_ target: CredentialTarget) async throws {
        entries.removeValue(forKey: target)
    }

    public func clear() async throws {
        entries.removeAll()
    }
}
