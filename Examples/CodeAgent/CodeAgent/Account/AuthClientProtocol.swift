//
//  AuthClientProtocol.swift
//  AgentKit
//
//  Gateway 认证 API 的抽象 —— 生产用 URLSession，测试用 Mock。
//

import Foundation
import AgentKit

// MARK: - AuthClientProtocol

/// Gateway 认证 API 的抽象。
///
/// 生产实现：`URLSessionAuthClient`（HTTP 调用 Gateway API）。
/// 测试实现：`MockAuthClient`。
///
/// 调用方：仅 `AccountManager`。不对 UI 层暴露。
public protocol AuthClientProtocol: Sendable {
    /// 密码登录。
    func login(email: String, password: String) async throws -> AuthResponse
    /// 密码注册。
    func register(email: String, password: String, displayName: String?) async throws -> AuthResponse
    /// Apple 登录。
    func loginWithApple(identityToken: String, authorizationCode: String, email: String?, givenName: String?, familyName: String?) async throws -> AuthResponse
    /// 匿名注册。
    func registerAnonymous() async throws -> AuthResponse
    /// 刷新 token。
    func refresh(refreshToken: String) async throws -> AuthResponse
    /// 登出（通知服务端使 token 失效）。
    func logout(accessToken: String) async throws
    /// 获取用量。
    func getUsage(accessToken: String) async throws -> UsageInfo
    /// 获取用户资料（可选）。
    func getProfile(accessToken: String) async throws -> AccountInfo
    /// 获取可用模型列表。
    func getModels(accessToken: String) async throws -> ModelsResponse
}

// MARK: - Types

/// 登录/刷新响应。
public struct AuthResponse: Codable, Sendable {
    /// JWT access token
    public let accessToken: String
    /// Refresh token（用于刷新）
    public let refreshToken: String
    /// access token 过期时间（Unix 秒）
    public let accessExp: Int64
    /// refresh token 过期时间（Unix 秒）
    public let refreshExp: Int64
    /// 是否新注册
    public let isNew: Bool
    /// 用户 ID
    public let userId: Int
    /// 用户展示名（登录时返回）
    public let nickname: String?

    /// access token 过期时间 → Date
    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(accessExp))
    }
}

/// 用量信息。
public struct UsageInfo: Codable, Sendable {
    public let dailyUnits: Int
    public let weeklyUnits: Int
    public let monthlyUnits: Int
    public let monthlyLimit: Int?
    public let currentModel: String?
    public let subscriptionTier: SubscriptionTier
}

// MARK: - Errors

public enum AuthError: Error, LocalizedError {
    case notAuthenticated
    case noRefreshToken
    case refreshFailed
    case networkError(Error)
    case invalidResponse
    case serverError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "未登录。"
        case .noRefreshToken:         return "无法刷新：缺少 refresh token。"
        case .refreshFailed:          return "Token 刷新失败，请重新登录。"
        case .networkError(let e):    return "网络错误：\(e.localizedDescription)"
        case .invalidResponse:        return "服务器响应无效。"
        case .serverError(let c, let m): return "[\(c)] \(m)"
        }
    }
}
