//
//  RuntimeConnectionMonitor.swift
//  AgentKit
//
//  端侧 runtime 的连接状态 —— 由 /healthz 探针驱动的单一真相源。
//
//  背景：iOS 挂起 App 会回收进程的回环 listening socket，但 Go `Handle` 与端口仍在内存里，
//  于是 `AgentRuntime.isAlive`(=`server != nil`) 为真、`port()` 照返，而实际没人 listen →
//  所有 HTTP 请求打到已死端口 → `NSURLErrorCannotConnectToHost (-1004)`。
//  **指针存活 ≠ listener 存活**，真存活判断必须靠探针；探到死则重启 runtime（新端口，
//  会话从持久化 DB 重载）。
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

    /// 并发去重：同一时刻只跑一次实际探活/重启，其余 await 同一结果。
    @ObservationIgnored private var inflight: Task<Bool, Never>?

    /// 一次 HTTP 往返成功后调用，直接标记已连接（省一次探针）。
    public func markConnected() { state = .connected }

    /// 探活；未启动则启动，listener 已死则重启（新端口）。返回最终是否健康。
    @discardableResult
    public func ensureHealthy() async -> Bool {
        if let inflight { return await inflight.value }
        let task = Task { await self.runEnsureHealthy() }
        inflight = task
        let result = await task.value
        inflight = nil
        return result
    }

    private func runEnsureHealthy() async -> Bool {
        // 1. 未启动过（首次 / jetsam 冷启动）→ 启动
        if !AgentRuntime.shared.isAlive {
            state = .connecting
            guard (try? AgentRuntime.shared.ensureStarted()) != nil else {
                state = .disconnected
                return false
            }
            let ok = await Self.pingHealthz()
            state = ok ? .connected : .disconnected
            return ok
        }
        // 2. 指针在 → 探活
        if await Self.pingHealthz() {
            state = .connected
            return true
        }
        // 3. 指针在但 listener 死了（iOS 挂起回收 socket）→ 重启
        state = .reconnecting
        guard (try? AgentRuntime.shared.restart()) != nil else {
            state = .disconnected
            return false
        }
        let ok = await Self.pingHealthz()
        state = ok ? .connected : .disconnected
        return ok
    }

    private static func pingHealthz() async -> Bool {
        let client = RuntimeHTTPClient(environment: .fromRuntime())
        return (try? await client.healthCheck()) == true
    }
}
#endif
