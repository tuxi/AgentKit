//
//  RuntimeConnectionMonitor.swift
//  AgentKit
//
//  Legacy iOS compatibility facade over RuntimeServerStatusMonitor.
//
//  New host code should observe RuntimeServerStatusMonitor directly. This type
//  remains source-compatible with existing Conversation views during migration.
//

#if os(iOS)
import Foundation
import Observation

/// runtime 连接状态。UI 观察此值渲染横幅；恢复路径写入此值。
public enum RuntimeConnectionState: Sendable, Equatable {
    case connecting     // 尚未确认或正在探活
    case connected      // /healthz 返回 ok
    case reconnecting   // 探到 listener 已死，正在重启 runtime
    case disconnected   // 重启后仍不可用
}

@MainActor
@Observable
public final class RuntimeConnectionMonitor {

    public static let shared = RuntimeConnectionMonitor()
    private init() {}

    public private(set) var state: RuntimeConnectionState = .connecting

    /// 一次 HTTP 往返成功后调用，直接标记已连接（省一次探针）。
    public func markConnected() {
        RuntimeServerStatusMonitor.embedded.markConnected()
        state = .connected
    }

    /// 探活；未启动则启动，listener 已死则重启（新端口）。返回最终是否健康。
    @discardableResult
    public func ensureHealthy() async -> Bool {
        state = mappedState(RuntimeServerStatusMonitor.embedded.status)
        let healthy = await RuntimeServerStatusMonitor.embedded.checkEmbedded(
            repairIfNeeded: true
        )
        state = mappedState(RuntimeServerStatusMonitor.embedded.status)
        return healthy
    }

    private func mappedState(
        _ status: RuntimeServerConnectionStatus
    ) -> RuntimeConnectionState {
        switch status {
        case .starting, .checking:
            .connecting
        case .connected:
            .connected
        case .reconnecting:
            .reconnecting
        case .offline, .authenticationRequired, .authenticationFailed,
             .protocolIncompatible, .tlsRequired, .configurationError:
            .disconnected
        }
    }
}
#endif
