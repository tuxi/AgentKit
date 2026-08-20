# Code-Agent Daemon Runtime Sharing v1 需求

## 1. 背景与目标

当前 Runtime Sharing 只支持 Embedded Runtime：宿主 App 通过进程内 API
启动 Shared TLS Listener、管理配对设备和发布 Bonjour。

macOS 已改为由独立 Code-Agent daemon 承载 Runtime，因此需要把 Runtime
Sharing 原生迁移到 daemon。macOS App 只通过 localhost 管理 API 控制
daemon；iPhone 继续通过局域网 HTTPS 直接连接 daemon。

目标架构：

```text
macOS App --localhost management API--> Code-Agent daemon
                                             |
                                             +-- Shared TLS Listener
                                             +-- Bonjour advertiser
                                             +-- TLS identity
                                             +-- pairing/bootstrap state
                                             +-- paired device registry
```

本需求只覆盖 daemon 端能力，不要求 daemon 依赖 AgentKit 或 Swift。

## 2. 功能范围

daemon 必须原生负责：

1. 启动和停止 Shared TLS Listener；
2. 生成并持久化稳定的 P-256 TLS identity；
3. 发布 `_talkify-agent._tcp.` Bonjour 服务；
4. 创建短时 bootstrap pairing invitation；
5. 接收 iPhone pairing 请求并生成 device credential；
6. 持久化 paired devices；
7. 使用 credential hash 验证设备访问；
8. 撤销设备并立即更新运行中的验证表；
9. daemon 重启后恢复 identity、设备和 Sharing 配置。

以下内容不属于本需求：

- macOS App UI；
- iOS QR 扫描 UI；
- Embedded Runtime 实现；
- Provider、Conversation、Job 等普通 Runtime API 的改造。

## 3. 两类 HTTP 接口

### 3.1 localhost 管理 API

管理 API 只允许 loopback 访问，不能暴露给局域网。建议复用 daemon 现有
loopback 管理端口和认证机制；如果现有机制没有覆盖，至少支持 Bearer
management token。

所有 JSON 响应使用现有 Runtime envelope：

```json
{"code": 0, "msg": "success", "data": {}}
```

需要实现以下接口：

#### 启动 Sharing

```text
POST /v1/runtime/sharing/start
```

请求：

```json
{
  "display_name": "My Mac",
  "listen_address": "0.0.0.0:0"
}
```

两个字段都可以为空。`listen_address` 为空时使用 daemon 默认配置。

响应 `data`：

```json
{
  "state": "running",
  "listen_address": "0.0.0.0:0",
  "listen_origin": "https://0.0.0.0:9443",
  "port": 9443,
  "started_at": "2026-08-20T01:02:03Z",
  "stopped_at": null,
  "last_transition_at": "2026-08-20T01:02:03Z",
  "last_error": null
}
```

`listen_origin` 仅供诊断，不能作为 Bonjour 地址或二维码地址。

#### 停止 Sharing

```text
POST /v1/runtime/sharing/stop
```

必须等 Shared TLS Listener 完成关闭后再返回成功。不能异步返回成功后
继续停止，否则 App 会观察到错误的状态。

#### 查询状态

```text
GET /v1/runtime/sharing/status
```

响应 `data` 为上面的 Listener Status。

#### 创建配对邀请

```text
POST /v1/runtime/sharing/invitations
```

请求：

```json
{"validity_seconds": 120}
```

有效期必须限制在 30–300 秒。响应 `data`：

```json
{
  "version": 1,
  "server_id": "srv_mac",
  "server_display_name": "My Mac",
  "service_type": "_talkify-agent._tcp.",
  "service_name": "My Mac abc123",
  "fallback_host": "my-mac.local",
  "port": 9443,
  "bootstrap_secret": "base64url-secret",
  "bootstrap_expires_at": "2026-08-20T01:04:03Z",
  "spki_sha256": "base64-spki-sha256"
}
```

要求：

- 每次创建都生成新的 32-byte 随机 bootstrap secret；
- daemon 只保存 secret 的 SHA-256，不保存明文；
- 新 secret 覆盖旧 secret；
- 过期后必须拒绝 pairing；
- `spki_sha256` 必须对应当前持久化 TLS identity；
- `fallback_host` 不能是 `0.0.0.0`、`::` 或其他 wildcard 地址。

#### 查询设备

```text
GET /v1/runtime/sharing/devices
```

响应：

```json
{
  "devices": [
    {
      "device_id": "dev_1",
      "credential_sha256": "64-hex-chars",
      "display_name": "iPhone",
      "platform": "iOS",
      "paired_at": "2026-08-20T01:02:03Z",
      "revoked_at": null
    }
  ]
}
```

响应中绝对不能出现明文 device credential。

#### 撤销设备

```text
DELETE /v1/runtime/sharing/devices/{device_id}
```

执行顺序必须是：

```text
持久化 revoked tombstone
  -> 更新运行中的 validation table
  -> 返回成功
```

如果 live update 失败，必须返回错误，并保持清晰的可恢复状态；不能返回
成功但继续允许该设备访问。

### 3.2 Shared TLS Listener API

Shared TLS Listener 对局域网设备提供现有 Runtime API，并必须保留已有
pairing 协议：

```text
POST /v1/runtime/pair
```

请求包含：

```json
{
  "bootstrap_secret": "base64url-secret",
  "device_name": "iPhone",
  "platform": "ios"
}
```

成功响应包含：

```json
{
  "enrollment_id": "enr_1",
  "device_id": "dev_1",
  "credential": "opaque-device-credential"
}
```

Pairing 响应返回前必须完成：

1. 校验 bootstrap secret 和过期时间；
2. 生成 device ID 和随机 device credential；
3. 持久化 credential hash 与设备 metadata；
4. 更新运行中的验证表；
5. 确认上述持久化和更新成功。

如果 daemon 需要人工确认，可以保留 pending enrollment，但必须在 durable
ack 完成后才向 iPhone 返回 credential。不能让 iPhone 获得一个 daemon
重启后失效的 credential。

除 pairing 外，Shared TLS Listener 的 Runtime API 必须要求有效的 device
Bearer credential。bootstrap secret 不能作为普通 Runtime API 的长期认证。

## 4. 持久化要求

至少持久化以下数据：

### TLS identity

- P-256 private key；
- certificate PEM；
- SPKI SHA-256；
- created timestamp。

identity 必须稳定：daemon 重启、端口变化、升级后不能改变。优先使用
macOS Keychain；如果 daemon 架构使用 data directory，则文件必须限制为
当前用户可读写，并且不能写入日志。

### Sharing configuration

- 是否启用 Sharing；
- listen address；
- display name；
- 最近一次错误和状态可选持久化。

### Paired devices

每个设备保存：

- device ID；
- credential SHA-256；
- display name；
- platform；
- paired at；
- revoked at。

保存过程必须采用临时文件写入、fsync/rename 或等价的原子替换策略，避免
daemon 崩溃产生半份 registry。

## 5. Bonjour 要求

Sharing running 后发布：

```text
_talkify-agent._tcp.
```

TXT record 至少包含：

```text
schema=talkify-runtime-share/v1
server_id=<stable server id>
display_name=<runtime display name>
wire_major=1
```

Bonjour 广播的端口必须是 Shared TLS Listener 的真实端口。停止 Sharing、
daemon 退出或 listener 启动失败时必须撤销广播。

如果 service name 冲突，daemon 必须报告错误并重新发布可发现名称；不能让
App 显示 running 但 Bonjour 实际发布失败。

## 6. 生命周期和并发要求

- `start` 必须幂等；已运行时应返回当前状态，或先完成旧 listener 的安全替换；
- `stop` 必须等待真实停止完成；
- start/stop/revoke/update 必须串行化；
- listener 状态、Bonjour 状态和 validation table 更新不能出现明显中间不一致；
- daemon 重启后如果 Sharing 配置为启用，应按产品配置自动恢复，或者明确返回 stopped，不能静默假运行；
- 设备撤销后已有 HTTP/WebSocket/Agent Wire 连接应尽快断开，不能只阻止新连接；
- daemon 退出时必须停止 Bonjour 和 Shared TLS Listener。

## 7. 安全要求

- TLS 私钥、bootstrap secret、device credential 不能写日志；
- bootstrap secret 只允许短期、一次性配对使用；
- 设备 registry 只保存 credential hash；
- Shared TLS Listener 必须使用 HTTPS；
- 客户端通过邀请中的 SPKI pin 验证 daemon identity；
- 不得使用系统 CA 信任替代 SPKI pin；
- 管理 API 只允许 localhost 和管理凭证；
- 不得把 management token 放进二维码或 Bonjour TXT record；
- redirect 必须拒绝，避免 Authorization header 被转发到其他 authority。

## 8. 兼容性要求

daemon 端实现必须兼容 AgentKit 当前的：

- `RuntimePairingInvitation` v1；
- `RuntimeSharedListenerStatus`；
- `RuntimeSharedDevice`；
- Runtime envelope `{code,msg,data}`；
- `RuntimePairingClient` 的 `/v1/runtime/pair` 请求和响应；
- `_talkify-agent._tcp.` Bonjour service type。

## 9. 验收标准

### Listener

- 启动后返回真实非零端口；
- 关闭后端口不可连接；
- daemon 重启后 identity 的 SPKI hash 不变；
- Bonjour 能发现 service、server ID、display name 和真实端口。

### Pairing

- 有效 invitation 可以完成 iPhone pairing；
- 过期 invitation 被拒绝；
- 错误 bootstrap secret 被拒绝；
- pairing 成功后 daemon 重启，返回的 device credential 仍然有效；
- credential 明文不出现在 daemon 日志和持久化文件中。

### Revocation

- revoke 后新请求认证失败；
- 已建立的 Agent Wire/WebSocket 连接被关闭；
- daemon 重启后 revoked device 仍然不能访问；
- live update 失败时 API 返回错误，不得伪报成功。

### Lifecycle

- start/stop/start 不会出现旧 stop 误停新 listener；
- daemon 退出不会残留 Bonjour 广播；
- App 与 daemon 断开后，daemon 仍可独立继续提供 Sharing 服务。

## 10. 交付物

Code-Agent 侧应交付：

1. daemon Sharing service/module；
2. localhost management API handler；
3. Shared TLS Listener pairing/auth middleware；
4. identity 和 device registry 持久化实现；
5. Bonjour advertiser；
6. 单元测试和 daemon 重启/配对/撤销集成测试；
7. 实际 API 示例或 OpenAPI/fixture；
8. daemon 配置项和默认端口说明。
