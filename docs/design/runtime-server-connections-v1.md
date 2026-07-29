# Runtime Server Connections v1 — Talkify / AgentKit / Code-Agent 三端需求

状态：已定稿；AgentKit Phase A 已实现，Phase B/C 待三端联调
范围：Talkify Apple App（iOS/macOS）、AgentKit、Code-Agent Runtime
依赖：[Provider Connections v1](provider-connections-v1.md)
目标：Talkify 除了使用 App 内嵌 CodeAgent Runtime，还可以注册并连接本机或远程 CodeAgent Server；所有 Server 必须通过受支持的 Agent Wire 协议提供能力。

## 1. 产品定义

### 1.1 Server 是什么

本文中的 Server 指运行 CodeAgent Runtime、持有工作区与会话数据，并通过 HTTP + Agent Wire WebSocket 对外提供 Agent 执行能力的节点。

Server 不是：

- Talkify Gateway；
- LLM Provider；
- 单独的模型 API Endpoint。

三者关系如下：

```text
Talkify App
  └─ Active Runtime Server
       ├─ Conversations / Workspaces / Tools
       └─ Provider Connections
            └─ Models
```

Talkify Gateway 仍是 Provider Connection 和账户连接，不承担 Runtime Server 的身份。

### 1.2 Server 类型

v1 支持三种类型：

1. `embedded`
   - Talkify App 内嵌的 CodeAgent Runtime；
   - iOS 使用 `sandboxed` Profile；
   - macOS Direct Distribution 使用 `full_desktop` Profile；
   - 由 App 管理启动、停止、重启和动态 loopback 端口；
   - 是保留连接，不允许删除。
2. `local`
   - 与 Talkify 位于同一设备，但作为独立进程运行的 CodeAgent Server；
   - 示例：`http://127.0.0.1:8797`；
   - 生命周期由用户或其他进程管理，Talkify 不负责启动和停止。
3. `remote`
   - 运行在另一台 Mac、工作站或企业服务器上的 CodeAgent Server；
   - 示例：iPhone 连接 Mac 上的 CodeAgent，操作 Mac 的工作区；
   - 服务端工具在远程 Server 所在设备执行，Agent Wire Client Tools 在 Talkify 所在设备执行。

### 1.3 多 Server 原则

- 用户可以注册多台 Server。
- v1 同一时间只允许一台 Active Server。
- 会话列表、工作区、模型目录、运行状态均以 Active Server 为作用域。
- v1 不合并展示多台 Server 的会话列表。
- 切换 Server 不迁移、复制或删除任何会话。
- Active Server 离线时不得自动回退到 Embedded Server，避免任务在错误文件系统、错误 Provider 或错误计费来源上执行。
- Embedded Server 使用保留 ID `talkify-embedded-runtime`。

## 2. 统一术语与稳定标识

### 2.1 Runtime Server Connection

App 本地保存的一条 Server 注册记录：

```text
id                    App 生成的稳定 Connection ID
display_name          用户可见名称
kind                  embedded | local | remote
endpoint              外部 Server 的 HTTP(S) Origin；embedded 为动态地址，不持久化
authentication        none | bearer
credential_target     External 认证时为 runtime_access/<connectionID>；Embedded 为内存临时凭证
is_active             是否为当前 Server；Registry 中最多一条为 true
created_at
updated_at
```

要求：

- `id` 创建后不可修改。
- Endpoint、显示名称和认证方式可以编辑。
- Registry 不保存 Access Token。
- Embedded Connection 不允许删除或编辑 Endpoint。

### 2.2 Server ID

`server_id` 由 CodeAgent 生成并持久化在其 data directory 中，用于识别“同一台 Runtime 数据源”。重启、端口变化和版本升级不得改变。

Server Connection ID 是 App 本地标识；Server ID 是远端返回的 Runtime 标识。两者不能互相替代。

当用户编辑 Endpoint 后连接到不同 `server_id`，App 必须提醒“该地址对应另一台服务器”，由用户确认后才能更新绑定，防止静默切换到错误工作区。

### 2.3 Runtime Conversation Identity

CodeAgent 的 `conversation_id` 只在单台 Server 内唯一。AgentKit 和宿主持久化引用时必须使用：

```text
RuntimeConversationIdentity {
    server_connection_id
    conversation_id
}
```

不得只用裸 `conversation_id` 跨 Server 查找会话。

### 2.4 Runtime Model Identity

外部 Server 模型由 Server 返回 `runtime_alias`。App 持久化的模型 Stable ID 必须包含 Server 维度：

```text
serverConnectionID + runtimeAlias -> Model Stable ID
```

同一模型 Alias 出现在不同 Server 时必须生成不同 Stable ID。

## 3. Endpoint 与安全规则

### 3.1 URL 规则

v1 Server URL 是 Origin，不支持自定义 path prefix、query、fragment 或 URL 内嵌用户名密码。

合法示例：

```text
http://127.0.0.1:8797
http://localhost:8797
https://agent.example.com
https://agent.example.com:9443
```

连接层根据 scheme 派生 Agent Wire URL：

```text
http  -> ws
https -> wss
```

Release 安全策略：

- HTTP/WS 只允许 loopback 地址；
- 非 loopback 地址必须使用 HTTPS/WSS；
- 不提供“忽略 TLS 证书错误”选项；
- HTTP Redirect 不得把认证头转发到其他 Origin；
- Access Token 不得出现在 URL、日志、错误正文或 Analytics 中。

开发构建可以提供显式的“不安全局域网连接”开关，但默认关闭，不进入 v1 Release 产品入口。

### 3.2 Server Access Token

远程访问鉴权与 Provider credential 必须完全分离。

```text
Server Access Token target: runtime_access/<serverConnectionID>
Provider credential target: gateway/default | llm/<providerConnectionID>
```

- Server Access Token 使用 `Authorization: Bearer <token>` 保护 HTTP 和 WebSocket Upgrade。
- External Token 只存储在 AgentKit Keychain Credential Store。
- 外部 Runtime 的 Provider credential 由 Server 自己管理，Talkify 不通过 Agent Wire 上传本地 Provider API Key。
- CodeAgent 不得再把 Server Access Token 解释成 Gateway Provider credential。
- Embedded Runtime 同样要求 Server Auth。AgentKit 在每次 Runtime 启动时生成
  256-bit 随机临时 Token，通过嵌入接口只在内存中交给 CodeAgent，并自动注入
  Embedded HTTP 与 WebSocket 请求。
- Embedded 临时 Token 不进入 Keychain、YAML、UserDefaults、日志或 Analytics；
  每次 Runtime 重启必须轮换。动态 loopback 端口不是安全边界，尤其不能让
  macOS Full Desktop Runtime 暴露为无认证本地服务。

### 3.3 当前部署限制

在 CodeAgent 完成 Server Auth 与 TLS 部署能力前：

- 外部连接仅建议使用 loopback、SSH Tunnel、Tailscale 或受信任私网；
- 不允许把当前无 Server Auth 的 `codeagent serve` 直接暴露到公网；
- chater 不得把“远程服务器”标记为生产安全能力。

Agent Wire 是传输协议，不是认证协议。

## 4. Code-Agent HTTP 契约

所有 JSON Endpoint 延续现有统一响应信封：

```json
{
  "trace_id": "trace_xxx",
  "code": 0,
  "msg": "success",
  "data": {}
}
```

### 4.1 健康检查

沿用：

```http
GET /healthz
```

成功响应：

```text
HTTP 200
ok
```

`/healthz` 只表示进程和 listener 存活，不单独证明 Agent Wire 兼容、认证有效或模型可用。

部署策略可以允许未认证的 `/healthz` 只返回 `ok`；其他 Runtime API 必须遵守 Server Auth。

### 4.2 Runtime Info

新增：

```http
GET /v1/runtime/info
```

响应 `data`：

```json
{
  "schema": "runtime-info/v1",
  "server_id": "srv_01JXYZ...",
  "display_name": "Xiaoyuan Mac",
  "product": "codeagent",
  "runtime_version": "1.3.0",
  "agent_wire_protocol": {
    "major": 1,
    "revision": "1.2"
  },
  "runtime_profile": "full_desktop"
}
```

字段要求：

- `server_id`：稳定、非 secret；
- `runtime_version`：CodeAgent 语义版本；
- `agent_wire_protocol.major`：兼容性硬门槛；
- `revision`：同一 major 内的增量能力版本，仅用于诊断，功能仍以 capabilities 为准；
- `runtime_profile`：`sandboxed | full_desktop | headless`。

AgentKit v1 只接受 `schema == runtime-info/v1`、`product == codeagent`、`agent_wire_protocol.major == 1`。

### 4.3 Runtime Capabilities

沿用：

```http
GET /v1/runtime/capabilities
```

该接口继续作为执行保证和限制的来源。`runtime/info` 不复制 capability flags。

### 4.4 Runtime Model Catalog

新增：

```http
GET /v1/runtime/models
```

响应 `data`：

```json
{
  "schema": "runtime-model-catalog/v1",
  "revision": 7,
  "default_runtime_alias": "provider.deepseek.model.deepseek-chat",
  "connections": [
    {
      "id": "deepseek-production",
      "provider_id": "deepseek",
      "display_name": "DeepSeek Production",
      "billing_source": "server_managed",
      "models": [
        {
          "runtime_alias": "provider.deepseek.model.deepseek-chat",
          "wire_model_id": "deepseek-chat",
          "display_name": "DeepSeek Chat",
          "context_window": 128000,
          "supports_tools": true,
          "supports_reasoning": false,
          "input_modalities": ["text"],
          "available": true
        }
      ]
    }
  ]
}
```

要求：

- 只返回已配置且允许客户端选择的模型；
- `runtime_alias` 在同一 Server 内稳定且唯一；
- `revision` 在目录结构或可用性发生变化时递增；
- 不返回 Base URL、Credential Target、API Key、自定义认证头或其他 secret；
- 相同 wire model 位于不同 Connection 时必须有不同 `runtime_alias`；
- 零模型 Runtime 返回空 `connections`，不是错误。

### 4.5 Server Auth

CodeAgent 需要增加统一认证中间件：

- HTTP Runtime API 与 Agent Wire WebSocket Upgrade 使用同一 Server Access Token；
- Embedded Server 从 CodeAgentRuntime 嵌入启动参数接收宿主生成的临时 Token，
  不从普通配置文件或环境变量读取；
- 未提供 Token：HTTP 401，业务错误 `runtime_auth_required`；
- Token 错误：HTTP 401，业务错误 `runtime_auth_invalid`；
- Token 正确后才允许列会话、读取工作区资产、创建会话或建立 Agent Wire；
- `/healthz` 是否公开由部署配置决定；
- 错误不得回显 Token。

v1 不采用截图中的 Basic Auth 用户名/密码表单。

### 4.6 Agent Wire 握手

每条会话 WebSocket 建立后，第一帧继续为：

```json
{
  "type": "hello",
  "protocol_version": 1,
  "server": "codeagent/1.3.0",
  "capabilities": []
}
```

- AgentKit 必须继续在真实会话 attach 时验证 `protocol_version`；
- `runtime/info` 用于添加 Server 时的无副作用预检；
- HTTP 预检通过不替代 WebSocket hello 验证；
- 协议不兼容时关闭连接，不进入自动重连循环。

## 5. Provider 与模型归属

### 5.1 Embedded Server

- Provider Connections、模型目录和 Keychain credential 继续由 Talkify + AgentKit 管理；
- AgentKit 生成 Runtime 配置并注入 Embedded Runtime；
- Provider 页面可编辑。

### 5.2 Local/Remote External Server

- Provider Connections、Runtime Alias 和 Provider credential 由外部 CodeAgent Server 管理；
- Talkify 通过 `/v1/runtime/models` 获取只读模型目录；
- Talkify 本地 Provider API Key 不得自动上传到外部 Server；
- Provider 页面显示“由当前服务器管理”，v1 只读；
- 模型选择器只展示 Active Server 返回的模型。

v1 不提供远程 Provider Admin API。未来如需从 Talkify 修改远程 Provider，必须单独设计管理员权限、审计、secret 写入和多用户隔离，不能复用 Agent Wire 会话权限。

### 5.3 切换 Server

切换后：

- 停止旧 Active Server 的 UI 状态监控和会话 WebSocket；
- 不取消或删除旧 Server 已经接受的远程任务；
- 创建新 Server 作用域的 `RuntimeClient`、Workspace Store 和模型目录；
- 会话列表从新 Server 重新加载；
- 默认模型从该 Server 作用域的偏好读取；
- 不沿用旧 Server 的 Model Stable ID；
- 不做自动 Provider 或模型映射。

## 6. 状态模型与监控

AgentKit 对外提供统一状态：

```text
starting                 Embedded Runtime 正在启动
checking                 正在执行 HTTP 预检
connected                健康检查、info 和协议验证通过
reconnecting             已连接 Server 暂时失联，正在有限退避
offline                  无法访问
authentication_required  需要 Access Token
authentication_failed    Access Token 无效
protocol_incompatible    Agent Wire major 或 Runtime schema 不兼容
tls_required             非 loopback Endpoint 使用了不安全 scheme
configuration_error      Endpoint 或本地 Runtime 配置错误
```

状态来源：

1. Embedded 生命周期；
2. `/healthz`；
3. `/v1/runtime/info`；
4. `/v1/runtime/capabilities`；
5. 活跃会话的 WebSocket 状态；
6. 最近一次错误的安全分类。

监控规则：

- App 启动、切换 Active Server、App 回到前台时立即检查；
- Server 设置页可见时定期刷新；
- Active Server 的正常 HTTP/WS 成功可直接更新为 connected；
- 非 Active Server 不建立会话 WebSocket；
- 非 Active Server 仅在 Server 设置页可见时执行低频 HTTP 检查；
- `protocol_incompatible`、`tls_required` 和认证失败不进入无限重连；
- 网络错误使用有上限的指数退避；
- UI 提供手动“重新检查”；
- 状态变化不触发自动 Server 切换。

v1 不要求通过专用 WebSocket 实时订阅 Server 状态。HTTP 探针与已有会话 WebSocket 已足够，避免为每台已注册 Server 长期保持额外连接。

## 7. chater UI/交互

### 7.1 设置导航

“集成”组按以下顺序展示：

1. 服务器
2. 提供商
3. 模型

### 7.2 Server 列表

每条记录展示：

- 状态点和状态文案；
- Server 显示名称；
- `Embedded`、`Local` 或 `Remote` 类型；
- 当前 Server 标记；
- Runtime 版本；
- Agent Wire 版本；
- Runtime Profile；
- Endpoint（Embedded 可显示当前动态 loopback 地址）；
- 可选的运行中会话数和待处理事项数。

操作：

- 设为当前服务器；
- 重新检查；
- 编辑；
- 断开/删除外部 Server；
- Embedded Server 可重启、查看诊断，但不能删除。

删除外部 Server：

- 只删除本地 Connection 记录和对应 Keychain Access Token；
- 不删除远程会话、工作区或服务端 Provider；
- 本地保存的历史引用保留 Server 名称 tombstone，显示“服务器已断开”；
- 删除 Active Server 前必须先选择其他 Server。

### 7.3 添加 Server

表单字段：

- Server URL；
- Server 名称（可选，默认采用 `runtime/info.display_name`）；
- 认证方式：无认证 / Access Token；
- Access Token；
- “测试连接”；
- “添加并设为当前服务器”。

交互顺序：

```text
本地校验 URL
  -> /healthz
  -> /v1/runtime/info
  -> 验证 product/schema/Agent Wire major
  -> /v1/runtime/capabilities
  -> /v1/runtime/models
  -> 用户确认 Server identity
  -> 保存 Connection + Keychain Token
```

API Key 留空编辑语义不适用于 Server Token。编辑已有 Server 时，Token 留空表示保留原 Token，并在 UI 中明确提示。

### 7.4 Active Server 体验

- 左侧项目和会话属于 Active Server；
- 新建会话使用 Active Server；
- 模型选择器只显示 Active Server 模型；
- 页面显著但不过度打扰地显示当前 Server 名称；
- Remote Server 离线时允许浏览已缓存的本地 UI 状态，但禁止发送；
- 不显示裸 Server ID、Runtime Alias 或无法解析的内部标识作为用户文案。

## 8. AgentKit 端需求

AgentKit 是该功能的主要实现层。

### 8.1 Server Registry

新增通用类型：

- `RuntimeServerConnection`
- `RuntimeServerKind`
- `RuntimeServerAuthentication`
- `RuntimeServerRegistry`
- `RuntimeServerIdentity`
- `RuntimeConnectionStatus`

Registry 负责：

- 多连接持久化；
- 唯一 Connection ID；
- Active Server；
- Embedded 保留记录；
- Server ID 绑定；
- 不保存 secret。

### 8.2 Endpoint 与 Credential

- 将当前仅支持 `host + port` 的 `RuntimeEnvironment` 扩展为完整 HTTP(S) Origin；
- 正确派生 WS/WSS URL；
- External Server Access Token 使用 `runtime_access/*` Keychain namespace；
- Embedded Runtime Token 由 `AgentRuntime` 每次启动随机生成、仅保存在内存，
  并由 `.fromRuntime()` Client 自动读取；
- Server Auth 与 Provider credential 使用不同类型和注入路径；
- 提供 URL 安全校验和认证错误分类。

### 8.3 Client 与作用域

新增 `RuntimeConnectionCoordinator`（名称可按实现调整）：

- 根据 Active Server 构造 `RuntimeClient`；
- Embedded 使用 `.fromRuntime()`；
- External 使用 URL Environment + Server Access Credential；
- 切换时通知宿主重建 Server 作用域的依赖和 Store；
- 对外提供 `RuntimeConversationIdentity`；
- 不允许旧 Server Client 在切换后继续驱动当前 UI。

v1 可以通过重建 Workspace 根视图完成切换，不要求一个 `RuntimeClient` 在内部热切 Endpoint。

### 8.4 Status Monitor

- 将现有仅面向 iOS Embedded Runtime 的 Monitor 泛化；
- Embedded Monitor 保留 listener 回收后的 restart 行为；
- External Monitor 永远不尝试启动或重启远程进程；
- 暴露可观察状态、最近成功时间、最近安全错误和 Runtime Info；
- 状态检查并发去重；
- 页面消失或 Server 非 Active 时停止高频监控。

### 8.5 External Model Catalog

- 解码 `/v1/runtime/models`；
- 生成包含 Server Connection 维度的 Stable ID；
- 按 Server 返回的 Connection 分组；
- Stable ID 显式解析为 `runtime_alias` 后发送；
- Catalog revision 变化时原子替换；
- 已删除模型以 tombstone 形式保留在历史会话；
- 不可用模型不得自动替换。

### 8.6 AgentKit 非目标

- 不负责绘制 Talkify 设置页面；
- 不远程启动 CodeAgent 进程；
- 不通过 Agent Wire 修改远程 Provider；
- 不把本地 Provider Keychain 导出到外部 Server；
- 不聚合多 Server 会话列表。

## 9. chater 端需求

- 设置中心增加“服务器”入口及完整 UI；
- AppContainer 从 AgentKit Coordinator 获取 Active `RuntimeClient`；
- Server 切换时重建 Workspace/Conversation 作用域；
- Embedded Server 状态与重启入口；
- External Server 添加、编辑、删除、测试连接；
- 当前 Server 名称展示；
- iOS 首次访问局域网 Server 时提供 Local Network 权限说明；
- External Server 下 Provider 设置改为只读说明；
- External 模型目录接入现有 Composer 分组选择器；
- Gateway 登录状态不得影响 Server Connection；
- 未登录 Gateway 仍可连接 Local/Remote CodeAgent Server。

## 10. code-agent 端需求

- 持久化稳定 `server_id`；
- 新增 `/v1/runtime/info`；
- 新增 `/v1/runtime/models`；
- Agent Wire hello 中报告正确 Runtime 版本；
- 增加 Server Access Token 认证中间件；
- CodeAgentRuntime 嵌入启动接口支持接收宿主生成的临时 Server Access Token；
- 将 Server Auth 与 Gateway/Provider credential resolver 分离；
- HTTP 与 WebSocket 使用一致的认证策略；
- 提供安全的 401 错误码；
- 提供远程部署的 TLS、监听地址和反向代理文档；
- 模型目录不泄露 secret；
- 保持 Embedded Runtime 与 CLI Server 的协议行为一致。

## 11. 错误契约

AgentKit 面向宿主归一化以下错误：

```text
runtime_server_invalid_url
runtime_server_unreachable
runtime_server_tls_required
runtime_auth_required
runtime_auth_invalid
runtime_protocol_incompatible
runtime_identity_changed
runtime_capabilities_unavailable
runtime_model_catalog_unavailable
runtime_model_unavailable
```

要求：

- 用户文案不展示上游原始正文；
- 日志可包含 trace ID、Server Connection ID、HTTP 状态和安全错误码；
- 日志不得包含 Access Token、Provider API Key 或完整认证头；
- `runtime_model_catalog_unavailable` 不得回退到其他 Server 的模型；
- 协议不兼容和身份变化必须阻止保存或激活。

## 12. 迁移

- 现有 Talkify 安装自动创建 `talkify-embedded-runtime`；
- 现有会话引用懒迁移为：

```text
server_connection_id = talkify-embedded-runtime
conversation_id = existing conversation id
```

- 现有 Provider Stable ID 继续用于 Embedded Server；
- 外部模型使用新的 Server-scoped Stable ID；
- 现有 Dynamic Port 不写入 Registry；
- Gateway 登录、退出和 Provider 迁移不改变 Active Server。

## 13. 实施顺序

### Phase A — Embedded 状态

AgentKit：

- Server Registry 基础类型；
- Embedded Connection；
- 跨平台状态 Monitor。

已交付的公共接口：

```swift
let registry = RuntimeServerRegistry()
let coordinator = RuntimeServerCoordinator(registry: registry)

// 设置页只读探测：不会抢先启动尚未由宿主配置的 Runtime。
let healthy = await coordinator.checkEmbedded()

// 用户明确点击“重启”。
let restarted = await coordinator.restartEmbedded()

// SwiftUI 状态和诊断。
let status = coordinator.embeddedStatusMonitor.status
let diagnostics = coordinator.embeddedDiagnostics

// Phase C 切换 Server 后用作 Workspace 根视图 identity。
let identity = coordinator.activeIdentityRevision
```

宿主集成约束：

- `RuntimeServerCoordinator` 由 AppContainer 持有，不在 View 内重复创建；
- Server 设置页观察 `embeddedStatusMonitor`；
- 普通状态刷新调用默认只读的 `checkEmbedded()`；
- 只有 iOS 前台 listener 修复或用户明确操作才传
  `repairIfNeeded: true`/调用 `restartEmbedded()`；
- Phase A UI 不展示添加、删除或切换 External Server；
- Embedded Runtime 配置与 Provider 注入仍由宿主现有启动流程完成。

chater：

- 设置中心“服务器”页面；
- 显示 Embedded Runtime 状态、Profile、动态 Endpoint；
- 重启和诊断入口。

该阶段不开放“添加服务器”。

### Phase B — CodeAgent 外部契约

code-agent：

- Runtime Info；
- Runtime Model Catalog；
- Server Access Token；
- Embedded 临时 Token 启动接口；
- 版本与部署文档。

AgentKit 同步完成 DTO 和协议测试。

### Phase C — External Server

AgentKit：

- URL Environment；
- External Client；
- Active Server Coordinator；
- Server-scoped Conversation/Model identity。

chater：

- 添加、编辑、删除和切换 Server；
- External Provider 只读状态；
- 外部模型和会话接入。

只有 Phase B 安全与模型目录契约完成后，Release 才能开放 Remote Server。

## 14. 联调验收

### 14.1 Embedded

- macOS Embedded 显示 `full_desktop`、真实动态端口和 connected；
- iOS Embedded 显示 `sandboxed`；
- iOS listener 被系统回收后状态进入 reconnecting，Runtime 重启后恢复 connected；
- Embedded 重启不改变 Connection ID；
- Embedded HTTP、Runtime API 和 Agent Wire 除可选公开 `/healthz` 外均要求
  当前进程内临时 Token，重启后旧 Token 失效；
- Embedded 无模型时仍可浏览历史，发送返回明确不可用状态。

### 14.2 Local Server

- macOS 添加 `http://127.0.0.1:<port>` 成功；
- Server Info、Capabilities 和模型目录正确展示；
- 切换后会话列表来自独立 CodeAgent 进程；
- 停止进程后状态变为 offline，不自动切回 Embedded；
- 重启同一 data directory 后 `server_id` 不变。

### 14.3 Remote Server

- iPhone 通过 HTTPS/WSS 连接 Mac Server；
- iPhone 创建会话后，Shell、Git、文件工具操作 Mac 工作区；
- Camera 等 Client Tool 仍在 iPhone 执行；
- 无 Token返回 authentication_required；
- 错误 Token 返回 authentication_failed；
- Token 不出现在日志和 URL；
- HTTP 正常但 Agent Wire major 不兼容时禁止激活；
- Remote Server 不获得 Talkify 本地 Direct Provider API Key。

### 14.4 多 Server

- 注册 Embedded、Local 和 Remote 三台 Server；
- 一次只有一台 Active；
- 相同 `conversation_id` 不冲突；
- 相同 `runtime_alias` 生成不同 Model Stable ID；
- 切换 Server 不删除旧会话、不迁移模型、不自动取消旧任务；
- 删除外部 Connection 只删除本地记录和 Server Access Token。

### 14.5 安全

- 非 loopback HTTP 在 Release 被拒绝；
- TLS 错误不可忽略；
- Redirect 不泄露 Authorization；
- Runtime API 与 WebSocket 使用相同 Server Auth；
- Provider credential 与 Server Access Token 无法互相解析；
- Runtime Info 和 Model Catalog 不包含 Base URL、Credential Target 或 secret。

## 15. 非目标

- v1 不做多 Server 会话聚合；
- v1 不做 Server 自动故障转移；
- v1 不远程启动、升级或关闭外部 CodeAgent；
- v1 不提供远程 Provider Admin API；
- v1 不同步本地 Provider API Key 到外部 Server；
- v1 不提供公网穿透、证书签发或设备发现；
- v1 不支持 Basic Auth；
- v1 不支持一个会话跨 Server 迁移；
- v1 不允许以协议兼容为由跳过 TLS 或 Server Auth。
