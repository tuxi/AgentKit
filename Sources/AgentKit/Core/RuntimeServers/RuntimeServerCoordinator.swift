//
//  RuntimeServerCoordinator.swift
//  AgentKit
//
//  Active Runtime boundary. Phase A exposes the embedded connection; Phase C
//  extends client construction to validated Local/Remote connections.
//

import Foundation

public enum RuntimeServerCoordinatorError: Error, LocalizedError, Equatable {
    case externalServerUnavailableInPhaseA

    public var errorDescription: String? {
        switch self {
        case .externalServerUnavailableInPhaseA:
            "External Runtime Servers are not available until the Phase B server contract is installed."
        }
    }
}

#if canImport(CodeAgentRuntime)
@MainActor
@Observable
public final class RuntimeServerCoordinator {
    public let registry: RuntimeServerRegistry
    public let embeddedStatusMonitor: RuntimeServerStatusMonitor

    /// Hosts can use this value as a SwiftUI `.id(...)` to rebuild a
    /// Server-scoped Workspace root after an explicit Active Server change.
    public private(set) var activeRevision: UInt64 = 0

    public init(
        registry: RuntimeServerRegistry = RuntimeServerRegistry(),
        embeddedStatusMonitor: RuntimeServerStatusMonitor = .embedded
    ) {
        self.registry = registry
        self.embeddedStatusMonitor = embeddedStatusMonitor
    }

    public var activeConnection: RuntimeServerConnection {
        registry.activeConnection
    }

    public var activeConnectionID: String {
        registry.activeConnectionID
    }

    public var activeIdentityRevision: String {
        "\(activeConnectionID):\(activeRevision)"
    }

    public func makeActiveClient() throws -> any RuntimeClient {
        guard activeConnection.kind == .embedded else {
            throw RuntimeServerCoordinatorError.externalServerUnavailableInPhaseA
        }
        return DefaultAgentClient.fromRuntime()
    }

    /// Registry switching exists for host integration tests, but Phase A product
    /// UI must expose only the embedded connection.
    @discardableResult
    public func setActive(connectionID: String) throws -> RuntimeServerConnection {
        let previous = registry.activeConnectionID
        let selected = try registry.setActive(connectionID: connectionID)
        if previous != selected.id {
            activeRevision &+= 1
        }
        return selected
    }

    @discardableResult
    public func checkEmbedded(repairIfNeeded: Bool = false) async -> Bool {
        await embeddedStatusMonitor.checkEmbedded(repairIfNeeded: repairIfNeeded)
    }

    @discardableResult
    public func restartEmbedded() async -> Bool {
        await embeddedStatusMonitor.restartEmbedded()
    }

    public var embeddedDiagnostics: RuntimeServerDiagnosticSnapshot {
        embeddedStatusMonitor.diagnosticSnapshot
    }
}
#endif
