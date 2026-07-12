//
//  AccountManager.swift
//  AgentKit
//
//  用户身份管理器 —— Identity Layer 的核心。
//
//  职责：
//   - 登录/注册/登出
//   - Token 刷新（双层策略：Timer + Lazy）
//   - 账号状态暴露（@Observable，UI 驱动）
//
//  不负责：
//   - Agent Loop、Tool Execution、Model Provider
//   - 不导入任何 Runtime 类型（AgentRuntime / RuntimeClient）
//

import Foundation
import AgentKit

#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - AccountManager

/// 用户身份管理器。
///
/// 使用 `@MainActor` + `@Observable` 供 SwiftUI 直接观察。
/// 依赖 `AuthClientProtocol`（Gateway API）+ `CredentialStore`（Keychain）。
///
/// Token 刷新采用双层策略（参考 AWS SDK credential cache）：
///   Layer 1 (Timer)：过期前 5 分钟主动刷新。
///   Layer 2 (Lazy)：每次 `gatewayCredential()` 前检查，即将过期则立即刷新。
///   macOS 睡眠 / iOS 后台冻结可能导致 timer 错过 → lazy refresh 兜底。
@MainActor
@Observable
public final class AccountManager {

    // MARK: - Published State

    public private(set) var state: AccountState = .anonymous
    public private(set) var usage: UsageInfo?

    // MARK: - Dependencies

    private let authClient: any AuthClientProtocol
    private let credentialStore: any CredentialStore
    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        authClient: any AuthClientProtocol = URLSessionAuthClient(),
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        self.authClient = authClient
        self.credentialStore = credentialStore
    }

    // MARK: - Lifecycle

    /// App 启动时调用。从 Keychain 恢复 session。
    public func restore() async {
        guard let cred = try? await credentialStore.resolve(.gateway),
              let payload = try? decodeJWTPayload(cred.secret),
              !cred.isExpired
        else {
            // 尝试刷新
            if let cred = try? await credentialStore.resolve(.gateway),
               cred.metadata["refresh_token"] != nil {
                do {
                    let newCred = try await refreshGatewayToken()
                    let payload = try decodeJWTPayload(newCred.secret)
                    state = .authenticated(AccountInfo(from: payload))
                    return
                } catch {
                    let info = (try? decodeJWTPayload(cred.secret))
                        .map(AccountInfo.init(from:)) ?? AccountInfo(userId: "unknown")
                    state = .expired(info)
                    return
                }
            }
            state = .anonymous
            return
        }

        let info = AccountInfo(from: payload)
        state = .authenticated(info)
        scheduleTimerRefresh(expiresAt: cred.expiresAt ?? .distantFuture)
    }

    // MARK: - Login

    /// 密码登录。
    public func login(email: String, password: String) async throws {
        let response = try await authClient.login(email: email, password: password)
        try await persistAndActivate(response)
    }

    /// Apple 登录。
    public func loginWithApple(
        identityToken: String,
        authorizationCode: String,
        email: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil
    ) async throws {
        let response = try await authClient.loginWithApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            email: email,
            givenName: givenName,
            familyName: familyName
        )
        try await persistAndActivate(response)
    }

    /// 匿名注册。
    public func registerAnonymous() async throws {
        let response = try await authClient.registerAnonymous()
        try await persistAndActivate(response)
    }

    private func persistAndActivate(_ response: AuthResponse) async throws {
        let cred = Credential(
            kind: .bearer,
            secret: response.accessToken,
            expiresAt: response.expiresAt,
            metadata: ["refresh_token": response.refreshToken]
        )
        try await credentialStore.set(cred, for: .gateway)

        let payload = try decodeJWTPayload(response.accessToken)
        state = .authenticated(AccountInfo(from: payload))
        scheduleTimerRefresh(expiresAt: response.expiresAt)
    }

    // MARK: - Logout

    public func logout() async throws {
        refreshTask?.cancel()
        refreshTask = nil

        // Best-effort 通知服务端
        if let cred = try? await credentialStore.resolve(.gateway) {
            try? await authClient.logout(accessToken: cred.secret)
        }
        try? await credentialStore.remove(.gateway)
        usage = nil
        state = .anonymous
    }

    // MARK: - Token Refresh

    /// 获取当前有效的 Gateway credential。
    ///
    /// 应在每次向 Runtime 注入 credential 前调用。
    /// Layer 2 (Lazy)：token 快过期（< 5 分钟）时自动刷新。
    /// 刷新失败不阻塞 —— 用即将过期的 token 继续（Gateway 可能拒绝，但不会 crash）。
    public func gatewayCredential() async throws -> Credential? {
        guard var cred = try? await credentialStore.resolve(.gateway) else {
            return nil
        }
        if cred.expiresWithin(seconds: 300) {
            if let refreshed = try? await refreshGatewayToken() {
                cred = refreshed
            }
        }
        return cred
    }

    /// 强制刷新 Gateway JWT。
    @discardableResult
    public func refreshGatewayToken() async throws -> Credential {
        guard let cred = try? await credentialStore.resolve(.gateway),
              let refreshToken = cred.metadata["refresh_token"] else {
            throw AuthError.noRefreshToken
        }

        let response = try await authClient.refresh(refreshToken: refreshToken)
        let newCred = Credential(
            kind: .bearer,
            secret: response.accessToken,
            expiresAt: response.expiresAt,
            metadata: ["refresh_token": response.refreshToken]
        )
        try await credentialStore.set(newCred, for: .gateway)

        let payload = try decodeJWTPayload(response.accessToken)
        state = .authenticated(AccountInfo(from: payload))

        // Layer 1: 主动定时刷新
        scheduleTimerRefresh(expiresAt: response.expiresAt)
        return newCred
    }

    private func scheduleTimerRefresh(expiresAt: Date) {
        refreshTask?.cancel()
        let delay = expiresAt.timeIntervalSinceNow - 300 // 提前 5 分钟
        guard delay > 0 else {
            refreshTask = Task { [weak self] in
                try? await self?.refreshGatewayToken()
            }
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try? await self?.refreshGatewayToken()
        }
    }

    // MARK: - Usage

    public func fetchUsage() async throws {
        guard let token = try? await credentialStore.resolve(.gateway)?.secret else {
            throw AuthError.notAuthenticated
        }
        usage = try await authClient.getUsage(accessToken: token)
    }
}

// MARK: - JWT Decoding

/// 解码 JWT payload（不做签名验证 —— Gateway 已验证）。
/// 客户端只读 claims，不依赖格式稳定（见 agent-gateway-api-v1.md 附录 B）。
private func decodeJWTPayload(_ token: String) throws -> [String: Any] {
    let segments = token.components(separatedBy: ".")
    guard segments.count >= 2 else {
        throw AuthError.invalidResponse
    }
    let base64 = segments[1]
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: padded),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AuthError.invalidResponse
    }
    return json
}
