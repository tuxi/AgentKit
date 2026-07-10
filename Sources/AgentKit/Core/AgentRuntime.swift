//
//  AgentRuntime.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/30.
//

import Foundation
#if os(iOS)
import CodeAgentRuntime   // xcframework 的 module 名；仅 iOS 可用
import UIKit
#endif

#if os(iOS)
private final class RuntimeBackgroundTaskGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        let work = {
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                self.end()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func end() {
        lock.lock()
        let id = identifier
        identifier = .invalid
        lock.unlock()

        guard id != .invalid else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}

public final class AgentRuntime: @unchecked Sendable {
    private init() {}
    
    static public let shared = AgentRuntime()

    private var server: MobileServer?      // 前缀 Mobile 来自 Go 包名

    /// runtime 是否在本进程内存活。用作「同进程 suspend/thaw」与「jetsam 冷启动」的判据（见契约 §3.2）：
    /// - `server != nil` ⇒ 同进程（可能刚被 OS thaw）→ 复用现有端口，WS 直接重连；
    /// - `server == nil` ⇒ 冷启动（首次或 jetsam 后重启）→ 需 `launch()`。
    public var isAlive: Bool { server != nil }

    /// 幂等启动：runtime 已在运行则直接返回现有端口，否则冷启动一个。
    /// 替代旧的「每次 `start()` 都 `MobileStart` 新建」——那会覆盖 `server` 造成泄漏，且换 ephemeral 端口逼 WS 全量重连。
    /// scenePhase `.active` 走这里：同进程 thaw 时端口不变、WS 秒级重连，切走不再丢会话。
    @discardableResult
    public func ensureStarted() throws -> Int {
        if let server { return server.port() }
        return try launch()
    }

    /// 兼容旧调用点：语义等同 `ensureStarted()`（幂等）。需要强制重建 server 走 `restart()`；
    /// 改配置优先走 `reconfigure(secrets:model:)` 热加载，不再经 `restart` 的端口 churn。
    @discardableResult
    public func start() throws -> Int { try ensureStarted() }

    /// 后台生命周期钩子：在 iOS background grace window 内请求 Go runtime 做有界 checkpoint。
    /// Go 侧 `Suspend()` 负责取消在途 turn、标记 paused，并在 watchdog 预算内返回。
    public func suspendRuntime(timeoutMillis: Int = 2000) {
        guard let server else { return }

        DispatchQueue.global(qos: .background).async {
            let backgroundTask = RuntimeBackgroundTaskGuard()
            backgroundTask.begin(name: "AgentRuntime.Suspend")

            let watchdog = DispatchWorkItem {
                backgroundTask.end()
            }
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .milliseconds(timeoutMillis), execute: watchdog)

            do {
                try server.suspend()
            } catch {
                print("AgentRuntime suspend failed: \(error)")
            }

            watchdog.cancel()
            backgroundTask.end()
        }
    }

    /// 续跑一个已 paused 的会话。Go 侧校验后立即返回，实际进度继续走 WS 事件流。
    public func resumeRuntime(sessionID: String) throws {
        guard let server else {
            throw NSError(domain: "CodeAgent", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Runtime is not started"])
        }
        try server.resumeSession(sessionID)
    }

    /// 热切 secrets / model，不换端口、不断开 WS。传空字符串表示保留该项。
    public func reconfigure(secretsJSON: String = "", modelName: String = "") throws {
        guard let server else { return }
        try server.reconfigure(secretsJSON, modelName: modelName)
    }

    /// 实际冷启动一个 runtime server。启动前先 `stop()` 任何残留实例，杜绝覆盖泄漏。
    @discardableResult
    private func launch() throws -> Int {
        stop()   // 防御：绝不覆盖一个尚未释放的 server
        let fm = FileManager.default
        // workspaceDir: 用户文件/项目所在，可写
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        // dataDir: 运行时自有数据(session DB)，放 Application Support（不进 iCloud 同步）
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true) // 首次可能不存在
        // gap B：dataDir 及其内的 session DB(+ WAL -wal/-shm 边车) 必须在锁屏/后台可写，
        // 否则 iOS 会在锁屏后加密文件、令后台 checkpoint 写失败——把契约 §2.2.1 的 WAL 目标架空。
        Self.applyDataProtection(to: support)
        // secrets / model 从用户设置读取（Keychain + UserDefaults）——不再硬编码进源码。
        // 无 key 时 secretsJSON() 返回 "{}"，runtime 缺凭证；设置页引导用户填入后 restart()。
        let secrets = AgentSettings.secretsJSON()
        let model = AgentSettings.model
        // 模型路由 config（裁剪版，随 bundle 打包）。读不到则传 ""，回退 runtime 内置默认。
        let configYAML = Self.bundledConfigYAML()
        
        Self.installBundledSkillsIfNeeded()

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

    /// 强制重启（先 stop 再 launch），让新的 secretsJSON / model 生效。
    /// 端口会换新（ephemeral）；WS 经 validator 现算端口自动重连（见 AgentWireSocket）。
    /// 改配置优先走 `reconfigure(secrets:model:)` 热加载以避免端口 churn；此方法保留给真正需重建 server 的场景。
    @discardableResult
    public func restart() throws -> Int {
        stop()
        return try launch()
    }

    /// gap B：把 dataDir 设为 `completeUntilFirstUserAuthentication`——首次解锁后即可读写、锁屏与后台不受限。
    /// 目录级设置使 Go 在其中新建的 DB 及 `-wal`/`-shm` 边车继承该等级；已存在的 DB 文件再显式补设一遍。
    private static func applyDataProtection(to dir: URL) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(attrs, ofItemAtPath: dir.path)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in items {
            let name = url.lastPathComponent
            guard name.contains(".sqlite") || name.contains(".db") else { continue } // 含 .sqlite-wal/.sqlite-shm/.db-wal 等边车
            try? fm.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    /// 读取随 bundle 打包的裁剪版 config.yaml 内容；缺失则返回 ""（回退 runtime 内置默认）。
    private static func bundledConfigYAML() -> String {
        guard let url = Bundle.module.url(forResource: "config", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
    
    // copy into Application Support/skills (global/user-level)
    private static func installBundledSkillsIfNeeded() {
        let fm = FileManager.default
        
        // 1. 获取 Application Support 目录
        let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dst = appSupportDir.appendingPathComponent("skills")
        
        do {
            // 确保 Application Support 目录本身存在（非常重要！如果这个目录不存在，copyItem 会失败）
            if !fm.fileExists(atPath: appSupportDir.path) {
                try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            // 2. 正确检查 dst 是否存在
            // 注意：iOS 16 之后建议用 dst.path，或者保险起见用 dst.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: dst.path, isDirectory: &isDirectory)
            
            if exists {
                // 明确存在才删除
                try fm.removeItem(at: dst)
            }
            
            // 3. 执行拷贝
            guard let src = Bundle.module.url(forResource: "skills", withExtension: nil) else {
                print("Error: Source bundle 'skills' not found")
                return
            }
            
            try fm.copyItem(at: src, to: dst)
            
        } catch {
            print("Failed to install bundled skills: \(error)")
        }
    }

    // MARK: - CredentialStore Integration

    /// 使用 CredentialStore 启动 Runtime（替代直接传 secretsJSON）。
    /// 向后兼容：CredentialStore 为空时回退到旧的 AgentSettings.secretsJSON()。
    @discardableResult
    public func launch(with credentialStore: any CredentialStore) async throws -> Int {
        let map = (try? await credentialStore.all()) ?? CredentialMap()
        let secretsJSON = map.toSecretsJSON()
        let finalSecrets = secretsJSON == "{}"
            ? AgentSettings.secretsJSON()
            : secretsJSON
        return try launch(secretsJSON: finalSecrets)
    }

    /// 热更新 credential（用户登录/切换 BYOK key/Token 刷新后）。
    /// CredentialStore → CredentialMap → secretsJSON → Runtime。
    /// 注意：secretsJSON 已经 `strippedForInjection()`——不含 refresh_token。
    public func reconfigure(with credentialStore: any CredentialStore) async throws {
        guard let server else { return }
        let map = (try? await credentialStore.all()) ?? CredentialMap()
        try server.reconfigure(map.toSecretsJSON(), modelName: "")
    }

    // MARK: - Accessors

    public func endpoint() -> String { server?.endpoint() ?? "" }  // ws://127.0.0.1:<port>
    public func port() -> Int { server?.port() ?? -1 }
    public func stop()              {
        try? server?.stop(); server = nil
    }

    // MARK: - Private

    /// 内部冷启动入口。`secretsJSON` 为空时回退 AgentSettings。
    @discardableResult
    private func launch(secretsJSON: String = "") throws -> Int {
        stop()
        let finalSecrets = secretsJSON.isEmpty ? AgentSettings.secretsJSON() : secretsJSON
        return try _launch(secretsJSON: finalSecrets)
    }

    /// 原始冷启动逻辑（改名以避免与带参数版本冲突）。
    private func _launch(secretsJSON: String) throws -> Int {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        Self.applyDataProtection(to: support)
        let model = AgentSettings.model
        let configYAML = Self.bundledConfigYAML()
        Self.installBundledSkillsIfNeeded()
        var error: NSError?
        guard let srv = MobileStart(
            docs,
            support.path,
            configYAML,
            model,
            secretsJSON,
            "",
            true,
            &error
        ) else {
            throw error ?? NSError(domain: "CodeAgent", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MobileStart failed"])
        }
        server = srv
        return srv.port()
    }
}
#endif
