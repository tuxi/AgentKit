//
//  AgentRuntime.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/30.
//

import Foundation
#if os(iOS)
import CodeAgentRuntime   // xcframework 的 module 名；仅 iOS 可用
#endif

#if os(iOS)
public final class AgentRuntime: @unchecked Sendable {
    private init() {}
    
    static public let shared = AgentRuntime()

    private var server: MobileServer?      // 前缀 Mobile 来自 Go 包名

    /// 启动进程内 runtime，返回给 AgentKit 连接的回环端口。
    @discardableResult
    public func start() throws -> Int {
        let fm = FileManager.default
        // workspaceDir: 用户文件/项目所在，可写
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        // dataDir: 运行时自有数据(session DB)，放 Application Support（不进 iCloud 同步）
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true) // 首次可能不存在
        // secrets / model 从用户设置读取（Keychain + UserDefaults）——不再硬编码进源码。
        // 无 key 时 secretsJSON() 返回 "{}"，runtime 缺凭证；设置页引导用户填入后 restart()。
        let secrets = AgentSettings.secretsJSON()
        let model = AgentSettings.model
        // 模型路由 config（裁剪版，随 bundle 打包）。读不到则传 ""，回退 runtime 内置默认。
        let configYAML = Self.bundledConfigYAML()

        var error: NSError?
        // MobileStart 是 C 函数，NSError** 需显式传入（不会自动转 throwing）
        guard let srv = MobileStart(
            docs,     // workspaceDir
            support.path,    // dataDir  ← 新增；"" 则回退到 workspaceDir
            configYAML, // configYAML（模型别名/路由；不含明文 key，key 走 secretsJSON）
            model,    // modelName（"" → config.default_model）
            secrets,  // secretsJSON
            "",       // addr
            true,     // sandboxed
            &error
        ) else {
            throw error ?? NSError(domain: "CodeAgent", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MobileStart failed"])
        }
        server = srv
        return srv.port()
    }

    /// 重启 runtime（先 stop 再 start），让新的 secretsJSON / model 生效。
    /// 端口会换新（ephemeral）；WS 经 validator 现算端口自动重连（见 AgentWireSocket）。
    @discardableResult
    public func restart() throws -> Int {
        stop()
        return try start()
    }

    /// 读取随 bundle 打包的裁剪版 config.yaml 内容；缺失则返回 ""（回退 runtime 内置默认）。
    private static func bundledConfigYAML() -> String {
        guard let url = Bundle.module.url(forResource: "config", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    public func endpoint() -> String { server?.endpoint() ?? "" }  // ws://127.0.0.1:<port>
    public func port() -> Int { server?.port() ?? -1 }
    public func stop()              { try? server?.stop(); server = nil }
}
#endif
