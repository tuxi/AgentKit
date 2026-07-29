//
//  RuntimeServerStatusMonitor.swift
//  AgentKit
//
//  Cross-platform status source for the embedded Runtime. External Server
//  probing is added in Phase C without changing the observable status model.
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
    var start: @MainActor () throws -> Int
    var restart: @MainActor () throws -> Int
    var endpoint: @MainActor () -> URL?
    var profile: @MainActor () -> String
    var healthCheck: @MainActor () async -> Bool

    static let live = EmbeddedRuntimeLifecycle(
        isAlive: { AgentRuntime.shared.isAlive },
        start: { try AgentRuntime.shared.ensureStarted() },
        restart: { try AgentRuntime.shared.restart() },
        endpoint: { RuntimeEnvironment.fromRuntime().baseURL },
        profile: { AgentRuntime.shared.currentConfiguration.profile.rawValue },
        healthCheck: {
            let client = RuntimeHTTPClient(environment: .fromRuntime())
            return (try? await client.healthCheck()) == true
        }
    )
}

@MainActor
@Observable
public final class RuntimeServerStatusMonitor {
    public static let embedded = RuntimeServerStatusMonitor()

    public private(set) var status: RuntimeServerConnectionStatus = .checking
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastConnectedAt: Date?
    public private(set) var lastErrorDescription: String?

    private let lifecycle: EmbeddedRuntimeLifecycle
    @ObservationIgnored private var inflight: Task<Bool, Never>?
    @ObservationIgnored private var inflightRepairsIfNeeded = false

    public convenience init() {
        self.init(lifecycle: .live)
    }

    init(lifecycle: EmbeddedRuntimeLifecycle) {
        self.lifecycle = lifecycle
    }

    public var diagnosticSnapshot: RuntimeServerDiagnosticSnapshot {
        RuntimeServerDiagnosticSnapshot(
            connectionID: RuntimeServerConnection.embeddedID,
            status: status,
            endpoint: lifecycle.endpoint(),
            runtimeInfo: nil,
            runtimeProfile: lifecycle.profile(),
            lastCheckedAt: lastCheckedAt,
            lastConnectedAt: lastConnectedAt,
            lastErrorDescription: lastErrorDescription
        )
    }

    /// Checks the embedded listener. When `repairIfNeeded` is true, a missing or
    /// stale listener is started/restarted. Calls are coalesced so foreground
    /// restoration and settings diagnostics cannot race one another.
    @discardableResult
    public func checkEmbedded(repairIfNeeded: Bool = false) async -> Bool {
        if let inflight {
            let joinedRepair = inflightRepairsIfNeeded
            let healthy = await inflight.value
            if !healthy, repairIfNeeded, !joinedRepair {
                return await runCheck(repairIfNeeded: true)
            }
            return healthy
        }
        let task = Task { await self.runCheck(repairIfNeeded: repairIfNeeded) }
        inflight = task
        inflightRepairsIfNeeded = repairIfNeeded
        let healthy = await task.value
        inflight = nil
        inflightRepairsIfNeeded = false
        return healthy
    }

    /// Explicit user-requested restart used by the Embedded Server settings row.
    @discardableResult
    public func restartEmbedded() async -> Bool {
        if let inflight {
            _ = await inflight.value
        }
        let task = Task { await self.runRestart() }
        inflight = task
        inflightRepairsIfNeeded = true
        let healthy = await task.value
        inflight = nil
        inflightRepairsIfNeeded = false
        return healthy
    }

    /// A successful Runtime HTTP request or Agent Wire handshake can avoid an
    /// extra health probe by reporting the connection directly.
    public func markConnected() {
        status = .connected
        lastCheckedAt = Date()
        lastConnectedAt = lastCheckedAt
        lastErrorDescription = nil
    }

    private func runCheck(repairIfNeeded: Bool) async -> Bool {
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
                _ = try lifecycle.start()
            } catch {
                status = .configurationError
                lastErrorDescription = Self.safeDescription(error)
                return false
            }
            return await finishHealthCheck()
        }

        status = .checking
        if await lifecycle.healthCheck() {
            markConnected()
            return true
        }

        guard repairIfNeeded else {
            status = .offline
            lastErrorDescription = "Embedded Runtime listener is unavailable."
            return false
        }
        return await runRestart()
    }

    private func runRestart() async -> Bool {
        status = .reconnecting
        lastCheckedAt = Date()
        lastErrorDescription = nil
        do {
            _ = try lifecycle.restart()
        } catch {
            status = .configurationError
            lastErrorDescription = Self.safeDescription(error)
            return false
        }
        return await finishHealthCheck()
    }

    private func finishHealthCheck() async -> Bool {
        lastCheckedAt = Date()
        if await lifecycle.healthCheck() {
            markConnected()
            return true
        }
        status = .offline
        lastErrorDescription = "Embedded Runtime did not pass its health check."
        return false
    }

    private static func safeDescription(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Embedded Runtime configuration failed." : description
    }
}
#endif
