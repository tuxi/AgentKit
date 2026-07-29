# Provider Connections v1 — Talkify / AgentKit / Code-Agent 三端需求

状态：已定稿  
范围：Talkify Apple App（iOS/macOS）、AgentKit、Code-Agent Embedded Runtime  
目标：App 默认无需登录即可进入工作区；用户可同时连接多个模型服务商，并在每个会话中选择任意已连接服务商的模型。

## 1. 产品原则

1. Talkify Gateway 是一个内置 Provider，不再是 App 的全局使用前提。
2. “连接 Talkify Gateway”等价于登录 Talkify 账户；“断开 Talkify Gateway”等价于退出登录。
3. 断开 Gateway 只移除 Gateway Token、Gateway 模型和 Gateway 专属能力，不删除其他 Provider、API Key、本地会话或工作区。
4. 用户可以同时连接多个 Provider，也可以为同一种 Provider 配置多个企业代理实例。
5. Provider 不是全局互斥模式。模型按会话选择，每一轮请求根据模型的 Runtime Alias 路由到对应 Provider。
6. Provider 被断开后，使用该 Provider 的历史会话仍可读取，但发送前必须由用户明确选择其他可用模型；不得静默切换，以避免改变费用和数据流向。
7. API Key 只保存在 Keychain，不进入 UserDefaults、Provider 配置文件、Runtime YAML/JSON 或日志。

## 2. 统一术语与标识

### 2.1 Provider Definition

内置服务商模板，例如 Talkify Gateway、DeepSeek、Alibaba Qwen、Zhipu GLM、OpenRouter、Ollama。模板只提供默认名称、传输协议、Base URL 和推荐模型，不代表已经连接。

### 2.2 Provider Connection

用户实际配置的一条连接。每条连接有稳定、唯一的 `connectionID`。允许多个连接使用相同的 `providerID`：

```text
providerID = openai-compatible
connectionID = company-production

providerID = openai-compatible
connectionID = company-staging
```

Talkify Gateway 使用保留的单例 ID `talkify-gateway`。

### 2.3 Model Stable ID

App 持久化的模型标识，由 `connectionID + wireModelID` 生成。同一个 wire model 在不同连接中必须得到不同 Stable ID。

### 2.4 Runtime Alias

发送给 Code-Agent、用于查找 Runtime `models` 配置的稳定别名。Runtime Alias 与 UI 展示名称、Provider ID、wire model ID 分离。

### 2.5 Wire Model ID

最终发送给服务商 API 的 `model` 字段，例如 `deepseek-chat`、`qwen3-coder-plus`。

## 3. 共同数据契约

### Provider Connection

```text
id                  stable connection ID
provider_id         provider template/category ID
display_name        user-visible connection name
transport           openai_chat_completions | ollama
authentication      gateway_account | api_key | none
base_url            endpoint; Gateway endpoint is managed and not user-editable
model_source        configured | gateway_remote
models[]            models exposed by this connection
is_enabled          whether the connection participates in the model catalog
```

### Provider Model

```text
id                  wire model ID
display_name        optional display name
context_window      optional context length
supports_tools      whether agent tool calling is supported
supports_reasoning  whether reasoning output is supported
input_modalities    text/image/audio flags for UI capability display
pricing             optional display-only direct-provider prices
```

### Credential Target

```text
Talkify Gateway: gateway/default
Direct Provider: llm/<connectionID>
Local Provider: no credential
```

Runtime 配置只引用 Credential Target。真实 secret 由宿主通过 `secretsJSON` 注入。

## 4. chater 端需求

### 4.1 首次启动

- 根页面不再由 `AuthManager.isLoggedIn` 决定是否可以进入 Workspace。
- 新安装且没有可用 Provider 时展示首次连接引导：
  - 连接 Talkify Gateway；
  - 使用 API Key；
  - 连接本地模型；
  - 允许稍后配置。
- 没有可用模型时可以浏览工作区和历史会话，但发送按钮不可用，模型入口显示“连接服务商”。
- 不得在 App 启动时无条件匿名注册或访问 Gateway；Gateway 身份在用户选择连接 Gateway 时按需创建。

### 4.2 Provider 管理

- 设置中心增加“提供商”和“模型”。
- 支持同时连接多个 Provider。
- 支持同一 Provider 的多个 Connection。
- 自定义 OpenAI-compatible Connection 至少支持：
  - Connection ID（创建后稳定）；
  - 显示名称；
  - Base URL；
  - API Key；
  - 多个 Model ID；
  - 每个模型可选 display name、context window、tool calling 能力。
- Provider 列表展示凭证来源：Gateway Account、API Key、环境变量（若宿主支持）、Local。
- 删除连接时需要明确说明影响；删除非 Gateway Connection 只删除对应 Keychain credential。

### 4.3 Gateway 账户

- “连接 Talkify Gateway”调用现有登录流程。
- 登录成功后：
  - 注册/更新 `talkify-gateway` Connection；
  - 拉取 Gateway 模型并更新该 Connection；
  - 显示用户、订阅、余额、用量和云端资产能力。
- “断开 Talkify Gateway”调用现有登出流程并：
  - 清除 Gateway Token；
  - 移除/禁用 Gateway Connection；
  - 清除 Gateway 模型缓存、用户信息、订阅和资产缓存；
  - 保留全部 Direct/Local Connections。
- 未连接 Gateway 时，账户和订阅入口仍可见，但只展示“连接 Talkify Gateway 后查看”，不得发起受保护接口。

### 4.4 模型选择

- 聚合所有已启用 Connection 的模型，按 Connection 分组并支持搜索。
- 展示模型名称、Connection/Provider、计费来源、上下文、tool calling、reasoning 等能力。
- 每个会话持久化 Model Stable ID。
- 发送时将 Stable ID 解析为 Runtime Alias。
- Provider 不可用时不得自动选择其他 Provider。

### 4.5 chater 验收

- 未登录 Gateway、仅配置 Direct Provider，可以创建和继续会话。
- 同时配置 DeepSeek、Qwen 和两个自定义企业代理，模型选择器可同时看到全部模型。
- Gateway 登录/退出不影响 Direct Provider 和本地会话。
- 未登录时不请求 profile、billing、usage、Gateway models。
- API Key 不出现在 UserDefaults、日志或 Runtime 配置。

## 5. AgentKit 端需求

### 5.1 Provider Registry

- 提供通用的 Provider Connection / Provider Model 类型。
- 提供持久化、多连接、唯一 Connection ID 的 Registry。
- Registry 不保存 secret。
- Talkify Gateway 只是保留 ID 和认证类型的普通 Connection。

### 5.2 Unified Model Catalog

- 从所有启用 Connection 生成统一 Model Descriptor 列表。
- 生成确定性的 Model Stable ID 和 Runtime Alias。
- Stable ID 必须包含 Connection 维度，避免相同 wire model 冲突。
- 提供按 Stable ID、Runtime Alias 查询以及默认模型持久化。
- 保留现有 Gateway-only `ModelSettingsStore` 兼容路径，供 chater 迁移期间使用。
- `ModelSettingsStore.applyUnifiedCatalog` 是现有 Composer 的迁移注入点；Composer
  持久化 Stable ID，发送和 Runtime reconfigure 前通过
  `runtimeAlias(for:)` 显式解析。
- 找不到的历史模型 ID 保持原值并标记不可用；Gateway wire model 在会话加载时
  通过 `migrateModelSelectionIfNeeded` 懒迁移并回写 local state。

### 5.3 Credential

- 提供生产可用的 `KeychainCredentialStore`。
- 提供按 namespace 路由的 `CompositeCredentialStore`，支持：
  - `gateway/*` → chater `AuthManager` adapter；
  - `llm/*` → Keychain。
- Runtime 注入继续使用既有 `CredentialMap.toSecretsJSON()`。

### 5.4 Runtime Configuration

- 从 Provider Registry Snapshot 生成 Code-Agent 可读取的配置文档。
- 配置包含全部已启用 Provider 模型，而不是只生成当前模型。
- 配置只包含 Credential Target，不包含 secret。
- Direct API Key credential source 使用 `injected`。
- Gateway 已连接时可生成 Gateway Search 配置；未连接时只保留 web fetch，禁用 Gateway Search。
- `AgentRuntime` 允许宿主在启动前提供生成的配置文档。
- 已存在配置中的模型切换不要求重启；新增、删除、修改 Connection 时，v1 允许在安全时机重启 Runtime。
- `buildEmpty()` 生成无 Gateway、无凭证、无 callable model 的历史/工作区配置。
  Code-Agent 必须支持 `default_model: ""` + 空 `models` 启动；在包含该支持的
  Runtime binary 发布前，宿主不得把空配置交给旧 binary。

### 5.5 AgentKit 验收

- 两个相同 wire model、不同 Connection 生成不同 Stable ID/Alias。
- 生成配置含全部 Connection 和正确 Credential Target，且不含 API Key。
- Keychain store 支持 resolve/all/set/remove/clear。
- Composite store 可同时输出 Gateway 与多个 LLM credentials。
- 没有 Gateway Connection 时，生成配置不包含 Gateway search。
- 现有 Gateway-only 调用在 chater 迁移期间仍可编译。

## 6. Code-Agent 端需求

### 6.1 每轮路由

每轮收到 Runtime Alias 后必须按配置解析：

```text
Runtime Alias
  → ModelConfig
  → Provider transport
  → Base URL
  → Credential Target
  → Wire Model ID
```

不同会话可以并发使用不同 Provider，不能依赖一个进程级“当前 Provider”。

### 6.2 Credential Resolver

- 每轮切换到其他模型配置时必须复用 Embedded Runtime 注入的 resolver chain。
- 修复 `ServeRunBuilder.Build` 为替代模型构造 Provider 时丢失 injected resolver 的问题；不得以 `nil` resolver 重建 Direct Provider。
- Credential 按 ModelConfig 的 Credential Target 解析。
- 401/403 错误需要携带可识别的 Connection/Target 信息，但不得输出 secret。

### 6.3 v1 协议范围

首期支持：

- `openai`：OpenAI-compatible `/chat/completions`；
- `ollama`：Ollama native；
- Bearer API Key；
- 无认证 localhost Provider。

后续独立增加：

- Anthropic native；
- Gemini native；
- OpenAI Responses API；
- 自定义 headers / Azure deployments；
- OAuth Provider。

### 6.4 Code-Agent 验收

- 一个 Runtime 同时配置 Gateway、DeepSeek、Qwen、两个企业代理。
- 两个会话交替/并发选择不同 Runtime Alias，分别命中正确 URL、Credential Target 和 wire model。
- Provider 切换不会复用上一 Provider 的 Authorization。
- Direct Provider 不要求 Gateway credential。
- Gateway Search 只在配置存在时注册/可用。
- 日志、错误和 telemetry 不包含 API Key。

## 7. 迁移

- 已登录用户首次升级时迁移为 `talkify-gateway` Connection。
- 旧 Gateway 模型字符串在读取时视为 Gateway wire model，并迁移为新的 Stable ID。
- 旧 DeepSeek API Key 若存在，迁移为 Direct Provider Connection + `llm/<connectionID>` credential。
- 不自动改变历史会话的计费 Provider。

## 8. 非目标

- v1 不同步 Direct Provider 配置或 API Key 到 Talkify 服务器。
- v1 不提供 Provider 自动故障转移。
- v1 不在 Provider 断开后静默替换模型。
- v1 不承诺任意 OpenAI-compatible 模型都支持 Agent tool calling。

## 9. 已确认的宿主口径

1. AgentKit 接入缺口由 AgentKit 仓先补，chater 不跨仓修改未提交实现。
2. Connection 结构变化遇到运行中 turn 时标记“配置待应用”，所有 turn 空闲后
   自动重启；不得强杀任务。Runtime 生命周期编排由 chater Coordinator 负责，
   空闲判断使用 `RuntimeClient.activitySnapshot()`；AgentKit 的
   `RuntimeProviderConfigurationApplyQueue` 负责合并等待中的配置并只在空闲时放行。
3. iOS/macOS 可连接局域网 Ollama，但 HTTP 只允许 loopback，或用户明确确认后的
   RFC1918/link-local/private IPv6 地址。公网 HTTP 始终拒绝。
4. Talkify Gateway “已连接”使用 `AuthManager.isRegistered`，只认正式注册账户。
   `isLoggedIn` 只表示存在任意 token，不能作为 Gateway Connection 判断。匿名 token/匿名注册不创建
   `talkify-gateway` Connection，也不开放账户、订阅或 Gateway 模型。
