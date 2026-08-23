//
//  RuntimeServerStatusMonitor.swift
//  AgentKit
//
//  Status monitor for any Runtime server (embedded or external).
//

import Foundation

public enum RuntimeServerConnectionStatus: String, Codable, Sendable, Equatable {
    case starting
    case checking
    case connected
    case reconnecting
    case offline
    case authenticationRequired = "authentication_required"
    case authenticationFailed = "authentication_failed"
    case protocolIncompatible = "protocol_incompatible"
    case tlsRequired = "tls_required"
    case configurationError = "configuration_error"
}

public struct RuntimeServerDiagnosticSnapshot: Sendable, Equatable {
    public let connectionID: String
    public let status: RuntimeServerConnectionStatus
    public let endpoint: URL?
    public let runtimeInfo: RuntimeServerInfo?
    public let runtimeProfile: String?
    public let lastCheckedAt: Date?
    public let lastConnectedAt: Date?
    public let lastErrorDescription: String?

    public init(
        connectionID: String,
        status: RuntimeServerConnectionStatus,
        endpoint: URL?,
        runtimeInfo: RuntimeServerInfo? = nil,
        runtimeProfile: String?,
        lastCheckedAt: Date?,
        lastConnectedAt: Date?,
        lastErrorDescription: String?
    ) {
        self.connectionID = connectionID
        self.status = status
        self.endpoint = endpoint
        self.runtimeInfo = runtimeInfo
        self.runtimeProfile = runtimeProfile
        self.lastCheckedAt = lastCheckedAt
        self.lastConnectedAt = lastConnectedAt
        self.lastErrorDescription = lastErrorDescription
    }
}

#if canImport(CodeAgentRuntime)

@MainActor
struct EmbeddedRuntimeLifecycle {
    var isAlive: @MainActor () -> Bool
    var start: @MainActor () async throws -> Int
    var restart: @MainActor () async throws -> Int
    var endpoint: @MainActor () -> URL?
    var profile: @MainActor () -> String
    var healthCheck: @MainActor () async -> Bool
    var runtimeInfo: @MainActor () async throws -> RuntimeServerInfo

    static let live = EmbeddedRuntimeLifecycle(
        isAlive: {
            AgentRuntime.shared.isAlive
        },
        start: {
            try await AgentRuntime.shared.ensureStarted()
        },
        restart: {
            try await AgentRuntime.shared.restart()
        },
        // 闭包是同步 @MainActor，直接读动态端口即可，避免走 async 的
        // RuntimeEnvironment（baseURL 现在需要 await）。
        endpoint: {
            let port = AgentRuntime.shared.port()
            guard port > 0 else { return nil }
            return URL(string: "http://127.0.0.1:\(port)")
        },
        profile: {
            AgentRuntime.shared.currentConfiguration.profile.rawValue
        },
        healthCheck: {
            let client = RuntimeHTTPClient(environment: .fromRuntime())
            return (try? await client.healthCheck()) == true
        },
        runtimeInfo: {
            let runtime = AgentRuntime.shared
            let client = RuntimeHTTPClient(
                environment: .fromRuntime(),
                credentialStore: runtime.runtimeAccessCredentialStore,
                credentialTarget: runtime.runtimeAccessCredentialStore.target
            )
            return try await client.runtimeInfo()
        }
    )
}

#endif // canImport(CodeAgentRuntime)

@MainActor
@Observable
public final class RuntimeServerStatusMonitor {

    public private(set) var status: RuntimeServerConnectionStatus = .checking
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastConnectedAt: Date?
    public private(set) var lastErrorDescription: String?
    public private(set) var runtimeInfo: RuntimeServerInfo?

    #if canImport(CodeAgentRuntime)
    /// Non-nil only when monitoring the embedded gomobile runtime.
    private let lifecycle: EmbeddedRuntimeLifecycle?
    #endif

    @ObservationIgnored private var inflight: Task<Bool, Never>?
    /// inflight 代数：只有最新一次检查可以清空 inflight，被超时弃置的旧任务
    /// 迟到完成时不得抹掉它的替代者。
    @ObservationIgnored private var inflightGeneration = 0

    // MARK: - Init

    #if canImport(CodeAgentRuntime)
    /// Creates a monitor for the embedded gomobile runtime.
    public static let embedded = RuntimeServerStatusMonitor(lifecycle: .live)

    private init(lifecycle: EmbeddedRuntimeLifecycle) {
        self.lifecycle = lifecycle
    }
    #endif

    /// Creates a monitor not tied to any specific runtime lifecycle.
    /// Use this for external/daemon servers that manage their own health checks.
    public init() {
#if canImport(CodeAgentRuntime)
        self.lifecycle = nil
#endif
    }

    // MARK: - Status queries (always available)

    public var diagnosticSnapshot: RuntimeServerDiagnosticSnapshot {
        #if canImport(CodeAgentRuntime)
        let endpoint = lifecycle?.endpoint()
        let profile = runtimeInfo?.runtimeProfile ?? lifecycle?.profile()
        #else
        let endpoint: URL? = nil
        let profile: String? = runtimeInfo?.runtimeProfile
        #endif
        return RuntimeServerDiagnosticSnapshot(
            connectionID: RuntimeServerConnection.embeddedID,
            status: status,
            endpoint: endpoint,
            runtimeInfo: runtimeInfo,
            runtimeProfile: profile,
            lastCheckedAt: lastCheckedAt,
            lastConnectedAt: lastConnectedAt,
            lastErrorDescription: lastErrorDescription
        )
    }

    /// Report a successful connection (HTTP request / Agent Wire handshake).
    /// Avoids an extra health probe by setting status directly.
    public func markConnected() {
        status = .connected
        lastCheckedAt = Date()
        lastConnectedAt = lastCheckedAt
        lastErrorDescription = nil
    }

    // MARK: - Embedded lifecycle (only when gomobile runtime is linked)

    #if canImport(CodeAgentRuntime)

    @discardableResult
    public func checkEmbedded(repairIfNeeded: Bool = false) async -> Bool {
        guard let lifecycle else { return false }
        if let existing = inflight {
            // 上一次检查可能钉在一个已死的 listener 上（如检查中途进程被冻结，
            // 回环 socket 被回收，HTTP 探针迟迟不返回）。join 必须有界；超窗后
            // 弃旧结果，针对当前 runtime 状态重新发起检查。
            if let joined = await Self.boundedJoin(existing, limit: .seconds(10)) {
                if joined || !repairIfNeeded { return joined }
                return await beginCheck(lifecycle: lifecycle, repairIfNeeded: true)
            }
        }
        return await beginCheck(lifecycle: lifecycle, repairIfNeeded: repairIfNeeded)
    }

    @discardableResult
    public func restartEmbedded() async -> Bool {
        guard let lifecycle else { return false }
        if let existing = inflight {
            _ = await Self.boundedJoin(existing, limit: .seconds(10))
        }
        return await beginRestart(lifecycle: lifecycle)
    }

    private func beginCheck(
        lifecycle: EmbeddedRuntimeLifecycle,
        repairIfNeeded: Bool
    ) async -> Bool {
        inflightGeneration += 1
        let generation = inflightGeneration
        let task = Task { await self.runCheck(lifecycle: lifecycle, repairIfNeeded: repairIfNeeded) }
        inflight = task
        let healthy = await task.value
        // 只有最新一次检查可以清空 inflight；被超时弃置的旧任务迟到完成时
        // 不得抹掉它的替代者。
        if inflightGeneration == generation {
            inflight = nil
        }
        return healthy
    }

    private func beginRestart(lifecycle: EmbeddedRuntimeLifecycle) async -> Bool {
        inflightGeneration += 1
        let generation = inflightGeneration
        let task = Task { await self.runRestart(lifecycle: lifecycle) }
        inflight = task
        let healthy = await task.value
        if inflightGeneration == generation {
            inflight = nil
        }
        return healthy
    }

    /// 等待 `task` 至多 `limit` 时间。返回其结果；超窗返回 nil（旧任务继续
    /// 在后台跑完，但不再被视为权威结果）。
    private static func boundedJoin(
        _ task: Task<Bool, Never>,
        limit: Duration
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func runCheck(lifecycle: EmbeddedRuntimeLifecycle, repairIfNeeded: Bool) async -> Bool {
        lastCheckedAt = Date()
        lastErrorDescription = nil

        if !lifecycle.isAlive() {
            guard repairIfNeeded else {
                status = .offline
                lastErrorDescription = "Embedded Runtime is not running."
                return false
            }
            status = .starting
            do {
                _ = try await lifecycle.start()
            } catch {
                status = .configurationError
                lastErrorDescription = Self.safeDescription(error)
                return false
            }
            return await finishHealthCheck(lifecycle: lifecycle)
        }

        status = .checking
        if await lifecycle.healthCheck() {
            return await finishAuthenticatedCheck(lifecycle: lifecycle)
        }

        guard repairIfNeeded else {
            status = .offline
            lastErrorDescription = "Embedded Runtime listener is unavailable."
            return false
        }
        return await runRestart(lifecycle: lifecycle)
    }

    private func runRestart(lifecycle: EmbeddedRuntimeLifecycle) async -> Bool {
        status = .reconnecting
        lastCheckedAt = Date()
        lastErrorDescription = nil
        do {
            _ = try await lifecycle.restart()
        } catch {
            status = .configurationError
            lastErrorDescription = Self.safeDescription(error)
            return false
        }
        return await finishHealthCheck(lifecycle: lifecycle)
    }

    private func finishHealthCheck(lifecycle: EmbeddedRuntimeLifecycle) async -> Bool {
        lastCheckedAt = Date()
        if await lifecycle.healthCheck() {
            return await finishAuthenticatedCheck(lifecycle: lifecycle)
        }
        status = .offline
        lastErrorDescription = "Embedded Runtime did not pass its health check."
        return false
    }

    private func finishAuthenticatedCheck(lifecycle: EmbeddedRuntimeLifecycle) async -> Bool {
        do {
            let info = try await lifecycle.runtimeInfo()
            guard info.isAgentWireV1Compatible else {
                status = .protocolIncompatible
                lastErrorDescription = "Embedded Runtime Agent Wire protocol is incompatible."
                return false
            }
            runtimeInfo = info
            markConnected()
            return true
        } catch RuntimeHTTPError.authenticationRequired {
            status = .authenticationRequired
            lastErrorDescription = "Embedded Runtime did not receive its access token."
            return false
        } catch RuntimeHTTPError.authenticationInvalid {
            status = .authenticationFailed
            lastErrorDescription = "Embedded Runtime rejected its access token."
            return false
        } catch {
            status = .configurationError
            lastErrorDescription = Self.safeDescription(error)
            return false
        }
    }

    private static func safeDescription(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Embedded Runtime configuration failed." : description
    }

    #endif // canImport(CodeAgentRuntime)
}
