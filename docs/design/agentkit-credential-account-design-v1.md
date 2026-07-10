# AgentKit Credential & Account Design v1

> 状态：草案 v1
> 作者：AgentKit 端
> 关联：`runtime-credential-design-v1.md`（Go 侧，待产出）
>
> **核心原则**：AgentKit 是 Identity Layer，不是 Runtime Controller。它负责 "用户是谁 / 有什么凭证"，
> 不负责 "Agent 怎么循环 / Tool 怎么执行"。

---

## 0. 当前架构诊断

### 0.1 现状

```
┌──────────────────────────────────────────────────────────┐
│  SettingsView                                            │
│  - "DeepSeek API Key" 文本框                              │
│  - "Tavily API Key" 文本框                                │
│  - Model Picker (deepseek / deepseek-pro)                │
│  - 保存 → KeychainStore                                  │
└───────────────────────┬──────────────────────────────────┘
                        │
        AgentSettings.secretsJSON()
        → {"DEEPSEEK_API_KEY":"sk-xxx","TAVILY_API_KEY":"tvly-xxx"}
                        │
        ┌───────────────▼──────────────────────────────────┐
        │  AgentRuntime.launch()           (iOS only)       │
        │  → MobileStart(configYAML, secretsJSON, model)   │
        └──────────────────────────────────────────────────┘
```

**关键事实：**

| 维度 | 当前状态 |
|------|---------|
| Provider | 硬编码 DeepSeek（`config.yaml` 只有两个 deepseek 别名） |
| Credential | 单一 API key，注入为环境变量 JSON |
| 用户身份 | 不存在 |
| Token 刷新 | 不存在（API key 不过期） |
| macOS 路径 | `AppContainer` 直连 `127.0.0.1:8797`——无 credential 注入 |
| 注入通道 | `secretsJSON`：单向，静态，仅在 `launch()` 时生效 |
| 热更新 | `reconfigure(secretsJSON:modelName:)`：复用同一 JSON 格式 |

### 0.2 核心瓶颈

1. **单一 provider 硬编码**：`AgentSettings.availableModels = ["", "deepseek", "deepseek-pro"]` — 无法添加 OpenAI/Anthropic/Ollama
2. **单 credential 模式**：只有一个 `DEEPSEEK_API_KEY`，不支持 Gateway JWT + BYOK 多 key 共存
3. **无用户身份层**：SettingsView 是 "填 key"，不是 "登录"
4. **macOS 空白**：远端 Runtime 的 credential 注入路径完全不存在
5. **注入格式是 env var map**：`{"DEEPSEEK_API_KEY": "sk-xxx"}` — 语义不足，无法表达 "这个 key 是用于 gateway 还是用于直连"

---

## 1. 设计目标

### 1.1 功能目标

1. **支持 Agent Gateway 登录**（Email/Apple ID → JWT → Keychain）
2. **支持 BYOK**（用户自行提供 OpenAI/DeepSeek/Anthropic API key）
3. **支持多 credential 并存**（Gateway JWT + 多个 BYOK key + MCP OAuth token）
4. **支持 Usage 展示**（调用 Gateway `/api/v1/agent/usage`）
5. **支持 Subscription 状态**
6. **macOS/iOS 共享账号体系**（iCloud Keychain 同步或独立登录）

### 1.2 架构原则

| 原则 | 含义 | 红线 |
|------|------|------|
| **AgentKit = Identity Layer** | 只做登录/Token/Keychain/Usage UI | 不碰 Agent Loop/Tool Execution/Model Provider |
| **单向注入** | credentials 从 AgentKit → Runtime，不回传 | Runtime 不回调 AgentKit 要 credential |
| **协议优先** | `CredentialStore` protocol，UI 不依赖 Keychain 实现 | 可单测、可替换 backend |
| **平台差异显式化** | `#if os(iOS)` / `#if os(macOS)` 只在注入路径，不污染协议层 | `CredentialStore` 是跨平台协议 |
| **向后兼容** | 旧的 `DEEPSEEK_API_KEY` 设置页继续工作 | 迁移路径：单 key → CredentialStore |

---

## 2. Credential 数据模型

### 2.1 CredentialKind

```swift
/// credential 类型 —— 与 Go 侧 `credential.Type` 对齐。
public enum CredentialKind: String, Codable, Sendable {
    case apiKey = "api_key"    // OpenAI/DeepSeek/Anthropic API key
    case bearer  = "bearer"     // Gateway JWT
    case oauth2  = "oauth2"     // MCP OAuth access token（含 refresh）
}
```

### 2.2 CredentialTarget

```swift
/// 唯一标识一个 credential —— 与 Go 侧 `credential.Target` 对齐。
public struct CredentialTarget: Hashable, Codable, Sendable {
    /// 命名空间：gateway | llm | mcp
    /// 注意：不存在 `search` namespace。web search 是 Gateway 的实现细节，
    /// Runtime 不应该感知底层用的是 Tavily/Google/Bing——统一走 `gateway/default`。
    public let namespace: String
    /// 名称：default | deepseek | openai | anthropic | github
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// 常用预设
    public static let gateway = CredentialTarget(namespace: "gateway", name: "default")
    public static func llm(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "llm", name: name)
    }
    public static func mcp(_ name: String) -> CredentialTarget {
        CredentialTarget(namespace: "mcp", name: name)
    }
}

extension CredentialTarget: Identifiable {
    /// 稳定编码的 target 标识符。
    /// 使用 `url.PathEscape` 避免 namespace/name 中包含 `/` 导致解析歧义。
    /// 例如 `github.enterprise.com/org/project` → `github.enterprise.com%2Forg%2Fproject`。
    /// 此方法需与 Go 侧 `Target.String()` 保持完全一致。
    public var id: String {
        "\(namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
    }
}
```

### 2.3 Credential

```swift
/// 凭据值 —— 与 Go 侧 `credential.Credential` 对齐。
/// 字段 `secret` 对应 Go 的 `Secret`，语义更精确（不是任意 "value"，是凭据机密）。
public struct Credential: Codable, Sendable {
    public let kind: CredentialKind
    public let secret: String
    public let expiresAt: Date?
    /// 仅 AgentKit 使用（refresh_token 等），**禁止**注入到 Runtime。
    /// toSecretsJSON() 会剥离 metadata，Runtime 永远不会收到 refresh_token。
    public var metadata: [String: String]

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// 将在 N 秒内过期（用于预刷新）。
    public func expiresWithin(seconds: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(seconds) >= expiresAt
    }

    /// 剥离 metadata 的纯凭据副本——用于注入 Runtime。
    /// Runtime 只需要 kind + secret + expiresAt，不需要 refresh_token 等 AgentKit 内部状态。
    public func strippedForInjection() -> Credential {
        Credential(kind: kind, secret: secret, expiresAt: expiresAt, metadata: [:])
    }
}
```

### 2.4 CredentialMap

```swift
/// 一组 credential 的不可变快照。用于序列化到 Keychain / 注入 Runtime。
public struct CredentialMap: Codable, Sendable {
    public let entries: [CredentialTarget: Credential]

    public init(entries: [CredentialTarget: Credential]) {
        self.entries = entries
    }

    /// 转为 secretsJSON 格式（Go Runtime 能理解的 JSON map）。
    /// key = Target.String()（url.PathEscape 编码），value = stripped Credential JSON。
    ///
    /// 关键：**剥离 metadata**——refresh_token 永不进入 Runtime。
    /// Runtime 只看到 kind + secret + expires_at，不感知 refresh_token。
    public func toSecretsJSON() -> String {
        var dict: [String: Credential] = [:]
        for (target, cred) in entries {
            dict[target.id] = cred.strippedForInjection()
        }
        guard let data = try? JSONEncoder().encode(dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
```

---

## 3. CredentialStore 协议

### 3.1 协议定义

```swift
/// AgentKit 的 credential 存储抽象。
///
/// 实现方：KeychainCredentialStore（生产）、MemoryCredentialStore（测试/预览）。
/// 不依赖任何 UI 框架（纯 Foundation），可在非主线程调用。
public protocol CredentialStore: Sendable {
    /// 获取单个 credential。
    func resolve(_ target: CredentialTarget) async throws -> Credential?

    /// 获取所有 credential（用于注入 Runtime）。
    func all() async throws -> CredentialMap

    /// 写入/更新 credential。
    func set(_ credential: Credential, for target: CredentialTarget) async throws

    /// 删除 credential。
    func remove(_ target: CredentialTarget) async throws

    /// 清空所有 credential（登出时调用）。
    func clear() async throws
}
```

### 3.2 与 Go Resolver 的对应关系

```
AgentKit                           Go Runtime
───────                            ──────────
CredentialStore (protocol)         credential.Resolver (interface)
  │                                  │
  │  resolve(target) → Credential    │  Resolve(ctx, target) → Credential
  │  all() → CredentialMap           │
  │                                  │
  │  实现：KeychainCredentialStore    │  实现：InjectedProvider (从 secretsJSON)
  │        MemoryCredentialStore      │        EnvProvider
  │                                  │        FileProvider
  │                                  │        Chain (fallback)
```

**AgentKit 不实现 Go 的 `credential.Resolver` 接口。**
AgentKit 通过 `secretsJSON` 单向注入给 Runtime，Runtime 的 `InjectedProvider` 解析并暴露为 `Resolver`。

### 3.3 KeychainCredentialStore

```swift
/// 基于 Keychain 的 CredentialStore 实现。
///
/// 在 Keychain 中以单个 entry 存储整个 CredentialMap 的 JSON。
/// 原因：
/// - CredentialMap 不大（几十个 entry 顶天），单 entry 读写性能足够
/// - macOS Keychain 对单个 app 的 entry 数量有限制
/// - 原子写入（读-改-写 在一个 entry 内完成）
public final class KeychainCredentialStore: CredentialStore, Sendable {
    private let keychain: KeychainStore
    private let account = "credential_map"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(service: String = "com.codeagent.credentials") {
        self.keychain = KeychainStore(service: service)
    }

    /// 线程安全：KeychainStore 是 Sendable，读写天然串行（SecItem API 是线程安全的）。
    private func loadMap() -> CredentialMap {
        guard let json = keychain.string(for: account),
              let data = json.data(using: .utf8),
              let map = try? decoder.decode(CredentialMap.self, from: data) else {
            return CredentialMap(entries: [:])
        }
        return map
    }

    private func saveMap(_ map: CredentialMap) throws {
        guard let data = try? encoder.encode(map),
              let json = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }
        keychain.set(json, for: account)
    }

    public func resolve(_ target: CredentialTarget) async throws -> Credential? {
        return loadMap().entries[target]
    }

    public func all() async throws -> CredentialMap {
        return loadMap()
    }

    public func set(_ credential: Credential, for target: CredentialTarget) async throws {
        var map = loadMap()
        map.entries[target] = credential
        try saveMap(map)
    }

    public func remove(_ target: CredentialTarget) async throws {
        var map = loadMap()
        map.entries.removeValue(forKey: target)
        try saveMap(map)
    }

    public func clear() async throws {
        keychain.remove(account)
    }
}

public enum CredentialStoreError: Error {
    case encodingFailed
    case notFound(CredentialTarget)
}
```

### 3.4 MemoryCredentialStore（测试/预览）

```swift
/// 内存实现，用于单元测试和 SwiftUI Preview。
public actor MemoryCredentialStore: CredentialStore {
    private var entries: [CredentialTarget: Credential] = [:]

    public func resolve(_ target: CredentialTarget) -> Credential? {
        entries[target]
    }

    public func all() -> CredentialMap {
        CredentialMap(entries: entries)
    }

    public func set(_ credential: Credential, for target: CredentialTarget) {
        entries[target] = credential
    }

    public func remove(_ target: CredentialTarget) {
        entries.removeValue(forKey: target)
    }

    public func clear() {
        entries.removeAll()
    }
}
```

---

## 4. Account 体系

### 4.1 AccountState

```swift
/// 用户账号状态。
public enum AccountState: Sendable, Equatable {
    /// 未登录。Settings 显示 "登录" 入口；agent 使用 BYOK 或不可用。
    case anonymous
    /// 已登录。持有完整的用户信息 + Gateway JWT。
    case authenticated(AccountInfo)
    /// Token 已过期且刷新失败。提示重新登录。
    case expired(AccountInfo)
    /// 离线。有缓存的 credential 但无法连接 Gateway 验证。
    case offline(AccountInfo)

    public var accountInfo: AccountInfo? {
        switch self {
        case .anonymous:                    return nil
        case .authenticated(let info):      return info
        case .expired(let info):            return info
        case .offline(let info):            return info
        }
    }

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

/// 用户基本信息（从 Gateway JWT claims 解析）。
public struct AccountInfo: Codable, Sendable, Equatable {
    public let userId: String
    public let email: String?
    public let displayName: String?
    public let subscriptionTier: SubscriptionTier
}

public enum SubscriptionTier: String, Codable, Sendable, Equatable {
    case free
    case pro
    case team
    case enterprise
}
```

### 4.2 AccountManager

```swift
/// 用户身份管理器。
///
/// 职责：
/// - 登录/注册/登出
/// - Token 刷新
/// - 账号状态暴露（@Observable，UI 驱动）
/// - 不负责：Agent Loop、Tool、Provider
@MainActor
@Observable
public final class AccountManager {
    public private(set) var state: AccountState = .anonymous
    public private(set) var usage: UsageInfo?

    private let authClient: AuthClientProtocol
    private let credentialStore: any CredentialStore
    private var refreshTask: Task<Void, Never>?

    public init(
        authClient: AuthClientProtocol,
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        self.authClient = authClient
        self.credentialStore = credentialStore
    }

    // MARK: - 生命周期

    /// App 启动时调用。从 Keychain 恢复 session。
    public func restore() async {
        guard let cred = try? await credentialStore.resolve(.gateway),
              let jwt = try? decodeJWT(cred.secret) else {
            state = .anonymous
            return
        }

        let info = AccountInfo(from: jwt)
        if cred.isExpired {
            // 尝试刷新
            do {
                let newCred = try await refreshGatewayToken()
                let newJwt = try decodeJWT(newCred.secret)
                state = .authenticated(AccountInfo(from: newJwt))
            } catch {
                state = .expired(info)
            }
        } else {
            state = .authenticated(info)
        }
    }

    // MARK: - 登录

    public func login(email: String, password: String) async throws {
        let response = try await authClient.login(email: email, password: password)
        let cred = Credential(
            kind: .bearer,
            secret: response.accessToken,
            expiresAt: response.expiresAt,
            metadata: ["refresh_token": response.refreshToken]
        )
        try await credentialStore.set(cred, for: .gateway)

        let jwt = try decodeJWT(response.accessToken)
        state = .authenticated(AccountInfo(from: jwt))
        scheduleTimerRefresh(expiresAt: response.expiresAt)
    }

    public func loginWithApple() async throws {
        // SKSignIn → identityToken → Gateway auth → JWT
        // 实现细节略，流程同 email login
        fatalError("Phase B 实现")
    }

    // MARK: - 登出

    public func logout() async throws {
        refreshTask?.cancel()
        refreshTask = nil
        try? await authClient.logout()  // best-effort
        try? await credentialStore.remove(.gateway)
        state = .anonymous
    }

    // MARK: - Token 刷新

    /// 双层刷新策略（参考 AWS SDK credential cache）：
    ///   Layer 1 (Timer): 定时器在过期前 5 分钟主动刷新。
    ///   Layer 2 (Lazy):  每次 credential 使用前检查，如果 < 5 分钟过期则立即刷新。
    ///   macOS 睡眠 / iOS 后台冻结可能导致 timer 错过 → lazy refresh 兜底。

    /// 获取当前有效的 Gateway credential。
    /// 如果 token 即将过期（< 5 分钟），自动触发刷新。
    /// 调用方（注入路径）应始终通过此方法获取 credential，而非直接读 CredentialStore。
    public func gatewayCredential() async throws -> Credential? {
        guard var cred = try? await credentialStore.resolve(.gateway) else {
            return nil
        }
        // Layer 2: Lazy refresh — token 快过期时立即刷新
        if cred.expiresWithin(seconds: 300) {
            if let refreshed = try? await refreshGatewayToken() {
                cred = refreshed
            }
            // 刷新失败不阻塞——用即将过期的 token 继续（Gateway 可能拒绝，但不会 crash）
        }
        return cred
    }

    @discardableResult
    public func refreshGatewayToken() async throws -> Credential {
        guard let cred = try? await credentialStore.resolve(.gateway),
              let refreshToken = cred.metadata["refresh_token"] else {
            throw AccountError.noRefreshToken
        }

        let response = try await authClient.refresh(refreshToken: refreshToken)
        let newCred = Credential(
            kind: .bearer,
            secret: response.accessToken,
            expiresAt: response.expiresAt,
            metadata: ["refresh_token": response.refreshToken]
        )
        try await credentialStore.set(newCred, for: .gateway)

        // Layer 1: 主动定时刷新（timer）
        scheduleTimerRefresh(expiresAt: response.expiresAt)
        return newCred
    }

    private func scheduleTimerRefresh(expiresAt: Date) {
        refreshTask?.cancel()
        let delay = expiresAt.timeIntervalSinceNow - 300 // 提前 5 分钟刷新
        guard delay > 0 else {
            Task { try? await refreshGatewayToken() }
            return
        }
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try? await refreshGatewayToken()
        }
    }

    // MARK: - Usage

    public func fetchUsage() async throws {
        guard let token = try? await credentialStore.resolve(.gateway)?.secret else {
            throw AccountError.notAuthenticated
        }
        usage = try await authClient.getUsage(accessToken: token)
    }
}

public enum AccountError: Error {
    case notAuthenticated
    case noRefreshToken
    case refreshFailed
}
```

### 4.3 AuthClientProtocol

```swift
/// Gateway 认证 API 的抽象。
/// 生产用 URLSessionAuthClient，测试用 Mock。
public protocol AuthClientProtocol: Sendable {
    func login(email: String, password: String) async throws -> AuthResponse
    func register(email: String, password: String, displayName: String?) async throws -> AuthResponse
    func refresh(refreshToken: String) async throws -> AuthResponse
    func logout() async throws
    func getUsage(accessToken: String) async throws -> UsageInfo
}

public struct AuthResponse: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
}

public struct UsageInfo: Codable, Sendable {
    public let dailyUnits: Int
    public let weeklyUnits: Int
    public let monthlyUnits: Int
    public let monthlyLimit: Int?
    public let currentModel: String
    public let subscriptionTier: SubscriptionTier
}
```

---

## 5. Credential 注入路径

### 5.1 核心决策：不跨 gomobile 边界回调

```
┌─────────────────────────────────────────────────────────┐
│  AgentKit                                               │
│                                                         │
│  KeychainCredentialStore                                │
│       │                                                 │
│       │ .all() → CredentialMap                          │
│       │ .toSecretsJSON() → JSON string                  │
│       │                                                 │
│  ┌────▼──────────────────────────────────────────────┐  │
│  │         注入路径（分平台）                          │  │
│  │                                                   │  │
│  │  iOS    → AgentRuntime.launch(secretsJSON:)       │  │
│  │         → AgentRuntime.reconfigure(secretsJSON:)  │  │
│  │                                                   │  │
│  │  macOS  → RuntimeHTTPClient 增加 Authorization    │  │
│  │         → Header 注入 Gateway JWT                  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │                   │
         │  secretsJSON      │  Authorization: Bearer <jwt>
         ▼                   ▼
┌─────────────────────────────────────────────────────────┐
│  Code-Agent Runtime (Go)                                │
│  credential.InjectedProvider ← 解析 secretsJSON          │
│  credential.Resolver interface                          │
└─────────────────────────────────────────────────────────┘
```

**为什么不让 Runtime 通过 gomobile callback 问 AgentKit 要 credential？**

| 问题 | 后果 |
|------|------|
| Runtime 生命周期依赖 UI 线程 | iOS 后台时 UI 可能没在跑，credential callback 超时 |
| CLI 无法独立运行 | `codeagent run` 会 panic（没有 callback 注册） |
| 测试困难 | 每个涉及 credential 的测试都要 mock callback |
| 开源核心变客户端插件 | Runtime 离开 AgentKit 就是废的 |

### 5.2 iOS 注入路径

```swift
extension AgentRuntime {
    /// 使用 CredentialStore 启动 Runtime（替代直接传 secretsJSON）。
    /// 向后兼容：如果 credentialStore 为空，回退到旧的 AgentSettings.secretsJSON()。
    /// 注意：secretsJSON 中的数据已经 strippedForInjection()——不含 refresh_token。
    public func launch(with credentialStore: any CredentialStore) throws -> Int {
        let secretsJSON = Task { try? await credentialStore.all() }.value?.toSecretsJSON() ?? "{}"
        // 如果 CredentialStore 为空，回退旧路径
        let finalSecrets = secretsJSON == "{}"
            ? AgentSettings.secretsJSON()
            : secretsJSON
        return try launch(secretsJSON: finalSecrets) // 内部重构
    }

    /// 热更新 credential（用户登录/切换 BYOK key/Token 刷新后）。
    public func reconfigure(with credentialStore: any CredentialStore) throws {
        let secretsJSON = Task { try? await credentialStore.all() }.value?.toSecretsJSON() ?? "{}"
        try reconfigure(secretsJSON: secretsJSON, modelName: AgentSettings.model)
    }
}
```

> 注意：`toSecretsJSON()` 调用 `strippedForInjection()` 剥离 metadata。
> Runtime 永远收不到 `refresh_token`。
> Gateway JWT 的刷新生命周期完全由 `AccountManager.gatewayCredential()` 的双层刷新（timer + lazy）管理。
```

**iOS 路径特点：**
- `MobileStart` 接收 JSON string，Go 侧 `InjectedProvider` 解析
- `reconfigure` 支持热切 credential（用户切换 BYOK key 不用重启 Runtime）
- 旧 `AgentSettings.secretsJSON()` 作为 CredentialStore 为空时的 fallback

### 5.3 macOS 注入路径

macOS 没有 `AgentRuntime`（Go 进程不在 app 内嵌）。当前 `AppContainer` 硬编码 `127.0.0.1:8797`。需要区分两种运行模式：

#### 模式 A：AgentKit Mac App → 远端 Runtime

用户运行 AgentKit Mac App，Runtime 是独立进程（由 app 启动或用户手动 `codeagent serve`）：

```
AgentKit Mac App
    │
    │  HTTP/WS + Authorization: Bearer <JWT>
    ▼
codeagent serve (远端进程)
    │
    │  InjectedProvider ← 启动参数
    ▼
credential.Resolver
```

```swift
/// 扩展 RuntimeHTTPClient，支持 Authorization header。
/// 不改变现有 URLSession 结构，只在 buildRequest 时注入 credential。
extension RuntimeHTTPClient {
    /// 创建带 credential 注入的 HTTP 客户端。
    /// - Parameter credentialStore: 为 nil 时行为不变（向后兼容）。
    /// 每次请求前通过 gatewayCredential() 获取最新 token（含 lazy refresh）。
    public func withCredentialStore(_ store: CredentialStore?) -> RuntimeHTTPClient {
        // 内部在每个请求 build 时：
        //   1. 从 store 获取 gateway credential（AccountManager.gatewayCredential()）
        //   2. 注入 Authorization: Bearer <jwt>
        //   3. 如果 store 为 nil → 行为与当前完全相同（本地开发 / CLI 模式）
    }
}

/// 扩展 AgentWireSocket，支持 WebSocket 握手带 Authorization header。
extension AgentWireSocket {
    public func withCredentialStore(_ store: CredentialStore?) -> AgentWireSocket {
        // 内部在 connectionValidatorRequest 闭包中注入 Authorization header
    }
}
```

#### 模式 B：CLI 独立运行（无 AgentKit）

用户从 Terminal 直接运行 `codeagent`。这种模式下 AgentKit 不存在，credential 由 Go Runtime 自己的 `ChainResolver` 处理：

```
Terminal
    │
    │  codeagent run
    ▼
Code-Agent Runtime
    │
    │  ChainResolver:
    │    1. EnvProvider    (DEEPSEEK_API_KEY)
    │    2. FileProvider   (~/.codeagent/credentials)
    │    3. StaticProvider (config.yaml)
    ▼
credential.Resolver
```

**Go 侧已经覆盖此模式（`ChainResolver`），AgentKit 不需要为 CLI 场景做任何事情。** 这是单向注入架构的优势：Runtime 不依赖 AgentKit，CLI 自然可用。

**macOS 注入路径特点：**
- 模式 A：Gateway credential 作为 `Authorization: Bearer <jwt>` header 注入每个 HTTP/WS 请求
- 模式 B：AgentKit 完全不在场，Runtime 自己通过 Chain 解析 credential
- BYOK credential 通过 `secretsJSON` 或配置注入（远端 Runtime 由启动参数传入）
- 不需要 `AgentRuntime`——对 macOS 来说 Runtime 就是远端 Go 进程

### 5.4 注入时机对比

| 时机 | iOS | macOS (模式 A) |
|------|-----|----------------|
| Runtime 启动 | `launch(with:)` → MobileStart | 远端 server 已有 credential（启动参数） |
| 用户登录 | `reconfigure(with:)` → 热切 | 创建新 transport（带新 credential） |
| Token 刷新 | `AccountManager.gatewayCredential()` lazy refresh + `reconfigure` | transport 内每次请求前 lazy refresh |
| 用户登出 | `reconfigure` + `clear()` → 清空 | `clear()` + 断开 + 提示重连 |
| CLI 模式 | N/A | AgentKit 不在场；Runtime 用 ChainResolver |

---

## 6. 配置数据模型

### 6.1 从单 key 到多 credential 的迁移

**旧（当前）：**
```swift
// AgentSettings.swift
public static let apiKeyAccount = "deepseek_api_key"       // Keychain account
public static let tavilyApiKeyAccount = "tavily_api_key"   // Keychain account

public static var apiKey: String { keychain.string(for: apiKeyAccount) ?? "" }
public static var tavilyApiKey: String { keychain.string(for: tavilyApiKeyAccount) ?? "" }
```

**新：**
```swift
// 新增：CredentialSettings（共存于 Core/，与 AgentSettings 平行）
public enum CredentialSettings {
    /// 默认的 credential store（Keychain 实现）。
    public static let store: any CredentialStore = KeychainCredentialStore()

    /// 迁移入口：从旧 Keychain entries 迁移到 CredentialMap。
    /// 执行一次后设置 migrated 标记，不再执行。
    public static func migrateFromLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "credential.migrated") else { return }
        defer { UserDefaults.standard.set(true, forKey: "credential.migrated") }

        let legacyKey = AgentSettings.apiKey
        let legacyTavily = AgentSettings.tavilyApiKey

        if !legacyKey.isEmpty {
            let cred = Credential(
                kind: .apiKey,
                secret: legacyKey,
                expiresAt: nil,
                metadata: [:]
            )
            Task { try? await store.set(cred, for: .llm("deepseek")) }
        }
        // 注意：Tavily key 不再独立迁移。
        // web search 是 Gateway 的实现细节，走 gateway/default 路径。
        // 旧 Tavily key 保留在旧 Keychain entry 中，用户可在旧设置页查看。
    }
}
```

### 6.2 config.yaml 对应关系

Go 侧 `config.yaml` 的 `credential` 块：

```yaml
models:
  deepseek:
    provider: openai
    credential:
      namespace: llm
      name: deepseek
  gateway-model:
    provider: openai
    credential:
      namespace: gateway
      name: default
```

AgentKit 侧不需要理解 config.yaml，只需要保证 `CredentialTarget` 的 `namespace/name` 与 config 中的声明一致。这个一致性由两端的 `CredentialTarget` 定义保证。

### 6.3 secretsJSON 格式演进

**旧格式（环境变量 map）：**
```json
{"DEEPSEEK_API_KEY": "sk-xxx", "TAVILY_API_KEY": "tvly-xxx"}
```

**新格式（CredentialMap → Runtime）：**
```json
{
  "gateway%2Fdefault": {
    "kind": "bearer",
    "secret": "eyJhbGci...",
    "expires_at": "2026-07-10T12:00:00Z"
  },
  "llm%2Fdeepseek": {
    "kind": "api_key",
    "secret": "sk-xxx"
  },
  "llm%2Fopenai": {
    "kind": "api_key",
    "secret": "sk-yyy"
  },
  "mcp%2Fgithub": {
    "kind": "oauth2",
    "secret": "gho_xxx"
  }
}
```
> 注意：`refresh_token` 不会出现在注入数据中（`strippedForInjection()` 剥离了 `metadata`）。
> Runtime 只知道 `kind` + `secret` + `expires_at`，绝不接触 `refresh_token`。

---

## 7. UI 设计

### 7.1 整体信息架构

```
Settings (Tab/Sheet)
  ├── Account
  │     ├── 未登录：Login 按钮 → LoginView
  │     ├── 已登录：显示 email + tier + 登出按钮
  │     └── 过期：提示重新登录
  │
  ├── Models & Credentials
  │     ├── Default Provider: [○ Agent Gateway | ○ BYOK]
  │     ├── BYOK Keys（当选择 BYOK 时展示）
  │     │     ├── DeepSeek API Key
  │     │     ├── OpenAI API Key
  │     │     ├── Anthropic API Key
  │     │     └── Ollama URL
  │     └── Model Selection (from available models)
  │
  ├── Usage（仅登录后可见）
  │     ├── Daily / Weekly / Monthly units
  │     ├── Current Model
  │     └── Subscription Tier
  │
  └── Subscription（仅登录后可见）
        ├── Current Plan
        ├── Upgrade CTA
        └── Billing Portal link
```

### 7.2 LoginView

```swift
public struct LoginView: View {
    @State private var viewModel: LoginViewModel

    public var body: some View {
        VStack(spacing: 24) {
            // Logo + Title
            VStack(spacing: 8) {
                Image("app_logo")
                Text("Sign in to CodeAgent")
                    .font(.title2)
                Text("Access Agent Gateway and sync across devices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Email/Password Form
            VStack(spacing: 12) {
                TextField("Email", text: $viewModel.email)
                SecureField("Password", text: $viewModel.password)
            }

            // Login Button
            Button("Sign In") {
                Task { await viewModel.login() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)

            // Sign in with Apple
            SignInWithAppleButton { result in
                Task { await viewModel.loginWithApple(result) }
            }

            // Register link
            Button("Create Account") {
                viewModel.showRegister = true
            }
        }
        .padding()
        .sheet(isPresented: $viewModel.showRegister) {
            RegisterView()
        }
    }
}
```

### 7.3 SettingsView 改造

当前 `SettingsView` 是一个简单的 Form。改造后：

```swift
public struct SettingsView: View {
    @Environment(AccountManager.self) private var accountManager
    @State private var credentialSettings = CredentialSettingsStore()
    @State private var showLogin = false

    public var body: some View {
        NavigationStack {
            Form {
                // Section 1: Account
                accountSection

                // Section 2: Provider & Credentials
                providerSection

                // Section 3: Usage (仅登录可见)
                if accountManager.state.isAuthenticated {
                    usageSection
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .task {
                try? await accountManager.fetchUsage()
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            switch accountManager.state {
            case .anonymous:
                Button("Sign In") { showLogin = true }

            case .authenticated(let info):
                HStack {
                    Text(info.email ?? info.userId)
                    Spacer()
                    Text(info.subscriptionTier.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
                Button("Sign Out", role: .destructive) {
                    Task { try? await accountManager.logout() }
                }

            case .expired(let info):
                Label("Session Expired", systemImage: "exclamationmark.triangle")
                Text(info.email ?? info.userId).foregroundStyle(.secondary)
                Button("Sign In Again") { showLogin = true }

            case .offline(let info):
                Label("Offline — \(info.email ?? info.userId)", systemImage: "wifi.slash")
            }
        }
    }

    // ... providerSection, usageSection 略
}
```

### 7.4 BYOK 管理 UI

```swift
struct BYOKSection: View {
    @Bindable var store: CredentialSettingsStore

    var body: some View {
        Section("Bring Your Own Keys") {
            ForEach(store.byokProviders) { provider in
                HStack {
                    Text(provider.displayName)
                    Spacer()
                    if provider.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Detail: selected provider's key field
            if let selected = store.selectedBYOKProvider {
                SecureField("\(selected.displayName) API Key", text: $store.byokKey)
                Button("Save to Keychain") {
                    store.saveBYOKKey()
                }
            }
        }
    }
}

/// UI 层 store（@MainActor @Observable）
@MainActor
@Observable
public final class CredentialSettingsStore {
    public var selectedProvider: ProviderMode = .gateway
    public var byokProviders: [BYOKProviderConfig] = [
        BYOKProviderConfig(namespace: "llm", name: "deepseek", displayName: "DeepSeek"),
        BYOKProviderConfig(namespace: "llm", name: "openai", displayName: "OpenAI"),
        BYOKProviderConfig(namespace: "llm", name: "anthropic", displayName: "Anthropic"),
        BYOKProviderConfig(namespace: "llm", name: "ollama", displayName: "Ollama (Local)"),
    ]

    private let store: any CredentialStore

    public func saveBYOKKey() {
        let cred = Credential(kind: .apiKey, secret: byokKey, expiresAt: nil, metadata: [:])
        Task {
            try? await store.set(cred, for: selectedTarget)
            // 触发热更新注入到 Runtime
        }
    }
}

public enum ProviderMode: String, CaseIterable {
    case gateway
    case byok
}

public struct BYOKProviderConfig: Identifiable {
    public let namespace: String
    public let name: String
    public let displayName: String
    public var isConfigured: Bool = false  // 由 store 查询后设置
    public var id: String { "\(namespace)/\(name)" }
}
```

### 7.5 Usage 展示

```swift
struct UsageSection: View {
    let usage: UsageInfo

    var body: some View {
        Section("Usage") {
            HStack {
                UsageMeter(label: "Today", used: usage.dailyUnits, limit: nil)
                UsageMeter(label: "Week", used: usage.weeklyUnits, limit: nil)
                UsageMeter(label: "Month", used: usage.monthlyUnits, limit: usage.monthlyLimit)
            }
            LabeledContent("Current Model", value: usage.currentModel)
            LabeledContent("Tier", value: usage.subscriptionTier.rawValue.capitalized)
        }
    }
}

struct UsageMeter: View {
    let label: String
    let used: Int
    let limit: Int?

    var body: some View {
        VStack {
            Text("\(used)").font(.title3).bold()
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let limit {
                ProgressView(value: Double(used), total: Double(limit))
            }
        }
    }
}
```

---

## 8. macOS/iOS 共用代码边界

### 8.1 协议层：完全共用

```
Sources/AgentKit/Core/
├── Credential/
│   ├── CredentialKind.swift        ← 共用
│   ├── CredentialTarget.swift      ← 共用
│   ├── Credential.swift            ← 共用
│   ├── CredentialMap.swift         ← 共用
│   ├── CredentialStore.swift       ← 共用（protocol）
│   ├── KeychainCredentialStore.swift ← 共用
│   ├── MemoryCredentialStore.swift  ← 共用
│   └── AccountState.swift          ← 共用
├── Account/
│   ├── AccountManager.swift        ← 共用（@MainActor @Observable）
│   ├── AccountInfo.swift           ← 共用
│   ├── AuthClientProtocol.swift    ← 共用
│   ├── URLSessionAuthClient.swift  ← 共用
│   └── UsageInfo.swift             ← 共用
```

### 8.2 注入路径：平台分叉

```
Sources/AgentKit/Core/
├── AgentRuntime.swift
│   // #if os(iOS) — 已有，新增 launch(with:) + reconfigure(with:)
│   // 平台差异：iOS 内嵌 Runtime，macOS 没有
│
├── RuntimeHTTPClient.swift
│   // 共用 — 新增 withCredentialStore()
│   // macOS 走 HTTP header 注入
│   // iOS 也可通过此路径在 Runtime 启动后注入额外 credential
│
├── AgentWireSocket.swift
│   // 共用 — 新增 WS 握手 Authorization header 支持
```

### 8.3 UI 层：条件编译

```
Sources/AgentKit/Features/Settings/
├── SettingsView.swift          ← 共用（使用 #if os 处理细节差异）
├── LoginView.swift             ← 共用
├── AccountSection.swift        ← 共用
├── BYOKSection.swift           ← 共用
├── UsageSection.swift          ← 共用
└── CredentialSettingsStore.swift ← 共用
```

**条件编译原则：**
- `CredentialStore` protocol：零条件编译
- `AccountManager`：`SignInWithAppleButton` 仅 Apple 平台，但 manager 本身条件编译极少量
- `SettingsView`：`#if os(iOS)` 用于 `navigationBarTitleDisplayMode`、`SignInWithApple` 等平台差异
- 注入路径：`RuntimeHTTPClient.withCredentialStore()` 在 iOS 上对 localhost 注入（可选），macOS 上对远端注入（必须）

---

## 9. 迁移路径

### Phase A：Core Types（不改任何 UI）

```
新增文件：
  Sources/AgentKit/Core/Credential/CredentialKind.swift
  Sources/AgentKit/Core/Credential/CredentialTarget.swift
  Sources/AgentKit/Core/Credential/Credential.swift
  Sources/AgentKit/Core/Credential/CredentialMap.swift
  Sources/AgentKit/Core/Credential/CredentialStore.swift
  Sources/AgentKit/Core/Credential/KeychainCredentialStore.swift
  Sources/AgentKit/Core/Credential/MemoryCredentialStore.swift
  Sources/AgentKit/Core/Account/AccountState.swift
  Sources/AgentKit/Core/Account/AccountInfo.swift
  Tests/AgentKitTests/CredentialStoreTests.swift
```

- 所有新类型是纯 Foundation，无 UI 依赖
- `KeychainCredentialStore` 复用现有 `KeychainStore`
- `AgentSettings` 保持不变，不破坏现有功能
- 单元测试覆盖 `CredentialMap` 序列化/反序列化、`KeychainCredentialStore` 读写

### Phase B：Account + Auth

```
新增文件：
  Sources/AgentKit/Core/Account/AccountManager.swift
  Sources/AgentKit/Core/Account/AuthClientProtocol.swift
  Sources/AgentKit/Core/Account/URLSessionAuthClient.swift
  Sources/AgentKit/Core/Account/UsageInfo.swift
  Sources/AgentKit/Features/Settings/LoginView.swift
  Tests/AgentKitTests/AccountManagerTests.swift
  Tests/AgentKitTests/MockAuthClient.swift
```

- `AccountManager` + `LoginView` 实现完整登录流程
- `URLSessionAuthClient` 实现 Gateway API 调用
- 旧 `SettingsView` 不变，新增 `LoginView` 通过 sheet 唤起
- `MockAuthClient` 支持 UI preview

### Phase C：Credential 注入 + 旧路径并存

```
修改文件：
  Sources/AgentKit/Core/AgentRuntime.swift (iOS: launch(with:), reconfigure(with:))
  Sources/AgentKit/Core/RuntimeHTTPClient.swift (新增 withCredentialStore())
  Sources/AgentKit/Core/AgentWireSocket.swift (WS 握手 Authorization)
  Sources/AgentKit/Core/AgentSettings.swift (新增 CredentialSettings 迁移)
```

- iOS：`AgentRuntime.launch(with:)` 接受 CredentialStore
- macOS：`RuntimeHTTPClient.withCredentialStore()` 注入 Authorization header
- 旧 `secretsJSON()` 路径保留作为 fallback
- `CredentialSettings.migrateFromLegacyIfNeeded()` 执行一次性迁移

### Phase D：完整 UI + 替换旧设置

```
修改/新增文件：
  Sources/AgentKit/Features/Settings/SettingsView.swift (全面改造)
  Sources/AgentKit/Features/Settings/BYOKSection.swift
  Sources/AgentKit/Features/Settings/UsageSection.swift
  Sources/AgentKit/Features/Settings/CredentialSettingsStore.swift
  Sources/AgentKit/Features/Conversation/Views/ConversationDetailView.swift
    (新增未登录/expired 状态提示)
```

- 旧 SettingsView 完全替换为新 Account/Provider/Usage 三段式
- 旧 `DEEPSEEK_API_KEY` 路径保留但标记 deprecated（不显示在新 UI 中，但旧数据可读）
- App 启动时 `AccountManager.restore()` 自动恢复登录态

---

## 10. 多端同步

### 10.1 iCloud Keychain 同步

macOS 和 iOS 的 Keychain 可通过 iCloud 同步（设置 `kSecAttrSynchronizable = true`）。

```swift
// KeychainCredentialStore 可选启用 iCloud sync
public init(service: String, syncsViaiCloud: Bool = false) {
    // syncsViaiCloud = false 默认：credential 不离开设备
    // syncsViaiCloud = true：用户在 Mac 登录后，iPhone 自动有 credential
}
```

**建议：**
- 默认 `false`（安全优先）
- 用户在 Mac 和 iPhone 上独立登录同一 Gateway 账号（不影响体验——JWT 各自颁发）
- 未来需要同步时，只需改 `KeychainCredentialStore` 的初始化参数

### 10.2 共享 Gateway Account

Mac 和 iPhone 使用**同一 Gateway 账号**登录。Gateway 服务端负责关联多个设备的 session。AgentKit 不需要做设备管理。

---

## 11. 安全考虑

| 层级 | 措施 |
|------|------|
| Keychain | `kSecAttrAccessibleAfterFirstUnlock` — 后台唤醒可读 |
| JWT | 不解析 claims 中的敏感字段（只读 userId/email/tier） |
| BYOK keys | 同 Gateway JWT 一样存 Keychain，不区分对待 |
| 内存 | `Credential.secret` 不在日志/console 输出；CustomStringConvertible 遮蔽 |
| 传输 | macOS 走 `http://localhost` 时 Authorization header 在同机内传输；未来远端需 HTTPS |
| Refresh Token | 与 access token 共存 Keychain 同一 entry；**永不注入 Runtime**（`strippedForInjection()` 剥离） |
| Runtime 污染 | Runtime 绝不知道 refresh_token；只收到 kind + secret + expires_at |

---

## 12. 依赖清单

| 依赖 | 用途 | 状态 |
|------|------|------|
| `KeychainStore`（已有） | Keychain 读写 | ✅ 直接复用 |
| `AgentSettings`（已有） | 向后兼容 + 迁移 | ✅ 保留，不删除 |
| `AgentRuntime`（已有，iOS only） | iOS 内嵌 Runtime 注入 | ✅ 扩展方法 |
| `RuntimeHTTPClient`（已有） | macOS HTTP 注入 | ✅ 扩展方法 |
| `AgentWireSocket`（已有） | WS 握手注入 | ✅ 扩展方法 |
| `SignInWithApple`（系统框架） | Apple ID 登录 | 🆕 AuthenticationServices |
| `URLSession`（系统框架） | Gateway API 调用 | ✅ 已有 |
| CryptoKit / JWT 解析 | JWT claims 解码 | 🆕 轻量依赖 |

---

## 13. 检查清单（供交叉评审用）

- [ ] `CredentialStore` protocol 是否可独立测试（不依赖 Keychain）？
- [ ] `AccountManager` 是否不导入任何 Runtime 类型（`AgentRuntime`/`RuntimeClient`）？
- [ ] `KeychainCredentialStore` 的 `CredentialMap` 序列化能否往返（encode → decode）？
- [ ] `CredentialTarget.id` 的 url.PathEscape 编码是否与 Go 侧 `Target.String()` 输出一致？
- [ ] `toSecretsJSON()` 是否剥离了 `metadata`（refresh_token 不出现在注入数据中）？
- [ ] iOS `launch(with:)` 在 CredentialStore 为空时是否回退到旧 `secretsJSON()`？
- [ ] macOS `RuntimeHTTPClient.withCredentialStore()` 在 store 为 nil 时是否行为不变（CLI/本地开发）？
- [ ] `AccountManager.gatewayCredential()` 是否在 token 快过期时自动触发 lazy refresh？
- [ ] macOS 睡眠 / iOS 后台冻结后，lazy refresh 是否能兜底 timer 错过？
- [ ] `SubscriptionTier` 是否只出现在 `AccountInfo` 和 `UsageInfo` 中（不进入 Credential/注入 Runtime）？
- [ ] 无 `search` namespace——web search 走 `gateway/default`？
- [ ] 旧的 `DEEPSEEK_API_KEY` 设置页保存的 key 能被 `migrateFromLegacyIfNeeded()` 正确迁移？
- [ ] BYOK key 保存后 `reconfigure` 热更新是否生效？
- [ ] Token 刷新失败后 `AccountState` 是否变为 `.expired`？
- [ ] 登出后 Keychain 中的 credential 是否被清除？
- [ ] `MockAuthClient` 是否覆盖 login/register/refresh/logout/getUsage 所有路径？
