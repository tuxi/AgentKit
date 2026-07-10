//
//  RuntimeEnvironment.swift
//  AgentKit
//
//  内嵌 CodeAgent Runtime 的连接目标。
//  替代传输层硬编码的 127.0.0.1:8797 — 端口由 OS 动态分配。
//

import Foundation

/// 当前 Runtime 的连接目标（host + port）。
///
/// 内部使用 provider 闭包延迟取值 — `fromRuntime()` 每次读取 `AgentRuntime.shared.port()`，
/// 不会在 init 时快照。传输层在发起连接时才取 port，避免拿到 start() 之前的旧值。
///
/// 生命周期：
/// 1. App 启动 → `AgentRuntime.shared.start()` → OS 分配动态端口
/// 2. `let env = RuntimeEnvironment.fromRuntime()` → 持有 provider（不读值）
/// 3. 发起连接时 provider 才执行 → 获取当前真实端口
public struct RuntimeEnvironment: Sendable {
    private let provider: @Sendable () -> (host: String, port: Int)

    // MARK: - Init

    /// 静态连接目标（如 macOS 远端 server）。
    public init(host: String, port: Int) {
        let h = host
        let p = port
        self.provider = { (h, p) }
    }

    /// 每次取值时动态执行 provider（用于 `.fromRuntime()`）。
    init(provider: @Sendable @escaping () -> (host: String, port: Int)) {
        self.provider = provider
    }

    // MARK: - Properties (lazy via provider)

    public var host: String { provider().host }
    public var port: Int    { provider().port }

    /// HTTP base URL。端口无效（≤0）时返回 nil。
    public var baseURL: URL? {
        let p = port
        guard p > 0 else { return nil }
        return URL(string: "http://\(host):\(p)")
    }

    /// WebSocket URL。端口无效（≤0）时返回 nil。
    public var wsURL: String? {
        let p = port
        guard p > 0 else { return nil }
        return "ws://\(host):\(p)"
    }

    // MARK: - Presets

    /// 占位值 — Runtime 启动前的 fallback（port = -1）。
    public static let placeholder = RuntimeEnvironment(host: "127.0.0.1", port: -1)
}

#if os(iOS)
extension RuntimeEnvironment {
    /// 从 `AgentRuntime.shared` 延迟读取动态端口。
    /// 每次访问 `host`/`port`/`baseURL`/`wsURL` 都会实时读取，不会快照。
    public static func fromRuntime() -> RuntimeEnvironment {
        RuntimeEnvironment {
            let rt = AgentRuntime.shared
            return (host: "127.0.0.1", port: rt.port())
        }
    }
}
#endif
