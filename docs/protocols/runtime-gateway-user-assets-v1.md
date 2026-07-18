# Runtime–Gateway User Assets Contract v1

> 状态：**Frozen for implementation（2026-07-18）**。
>
> 本文是 [Agent Wire Protocol v1.5 — User Assets](agent-wire-v1.5-user-assets.md) 的
> Runtime ↔ agent-gateway HTTP companion contract。Agent Wire 负责 App/AgentKit ↔ Runtime；
> 本文负责 Runtime ↔ Gateway。两份协议必须使用同一 canonical commit 和 fixtures 版本。
>
> 本文中的 **MUST / MUST NOT / SHOULD / MAY** 为规范性要求。

## 0. 范围与基础约定

生产基础地址：

```text
https://api.objc.com/api/v1/agent
```

本文冻结三个受保护端点：

```http
GET    /api/v1/agent/capabilities
POST   /api/v1/agent/chat/completions
DELETE /api/v1/agent/conversations/{session_id}/asset-refs
```

所有请求 MUST 使用与当前 Runtime conversation credential 绑定的 Bearer token：

```http
Authorization: Bearer <access-token>
```

Gateway 中 JWT 的认证 session 与请求体里的 `session_id` 不是同一个概念：

- JWT session：登录/匿名账号的认证会话；
- `session_id`：Code-agent conversation ID，全局唯一；
- Gateway 以当前 JWT principal + conversation `session_id` 共同隔离资产引用。

Runtime 不解析 JWT owner。Gateway 是 owner/status/asset metadata 的最终信任边界。

## 1. 通用身份

带 user assets 的 chat 请求 MUST 携带四个非空 identity：

| 字段 | 稳定范围 | 用途 |
|---|---|---|
| `session_id` | conversation 生命周期 | conversation 资产引用与历史归属 |
| `turn_id` | 一个 Agent turn | turn 追踪、错误关联 |
| `request_id` | 一次客户端提交及其重试 | Agent Wire 幂等关联 |
| `execution_id` | 一次模型 invocation 及其传输重试 | quota、usage 和 Provider 调用幂等 |

约束：

- 一个 turn 内可能有多次模型 invocation；它们共享 `session_id/turn_id/request_id`，但使用
  不同 `execution_id`。
- 同一 invocation 的 streaming/non-stream retry MUST 复用 `execution_id`。
- 普通 Provider fallback 也属于同一 invocation，MUST 复用 `execution_id`；但已知
  user-asset 错误禁止 fallback。
- Gateway 资产引用只使用 `session_id`，不能用当前 `turn_id` 绑定完整历史中的图片。
- `request_id` 和 `execution_id` 不能代替对资产 owner 的每次校验。

## 2. Capability discovery

### 2.1 Request

```http
GET /api/v1/agent/capabilities
Accept: application/json
Authorization: Bearer <access-token>
```

### 2.2 Success response

Gateway 普通受保护端点使用统一 envelope：

```json
{
  "trace_id": "trace_cap_001",
  "code": 0,
  "msg": "success",
  "data": {
    "contract": "runtime-gateway-user-assets",
    "contract_version": 1,
    "capabilities": ["image_input"],
    "limits": {
      "image_input": {
        "mime_types": ["image/jpeg", "image/png"],
        "max_assets_per_message": 4,
        "max_asset_bytes": 10485760,
        "max_total_asset_bytes": 20971520,
        "min_dimension_px": 32,
        "max_dimension_px": 8192
      }
    },
    "vision": {
      "direct": false,
      "bridge": true
    }
  }
}
```

Canonical fixture：
[capabilities_image_input.json](fixtures/runtime-gateway-user-assets/capabilities_image_input.json)。

Gateway 只有在以下条件全部成立时才能返回 `image_input`：

1. user asset owner/status/metadata 校验已启用；
2. 短期签名 URL 可用；
3. conversation 引用登记/释放已启用；
4. observation cache 与 usage 幂等已启用；
5. 规范资产错误链路已启用；
6. 至少一个视觉直通 Provider 或视觉桥可用。

`vision.direct/bridge` 是诊断信息；Runtime 的能力判断只看 `capabilities`。未知 capability
和 limits 字段必须忽略。

### 2.3 Runtime caching and fail-closed

- Runtime 在建立 Agent Wire hello 前，按当前 Gateway base URL + credential scope 获取能力；
- 成功结果最多缓存 60 秒；同一缓存项不得跨 Gateway base URL 或 credential scope 使用；
- 60 秒内网络短暂失败 MAY 使用上一次成功结果；过期后失败 MUST fail closed，不发布
  Agent Wire `image_input`；
- credential reconfigure、Gateway base URL 改变或认证失败立即使缓存失效；
- Agent Wire capability 是 connection snapshot；连接存续期间不修改已发送的 hello，下一次
  reconnect 重新评估；
- 401/403 不得使用旧缓存，并按现有认证恢复流程处理。

## 3. Chat request

### 3.1 Endpoint and envelope

```http
POST /api/v1/agent/chat/completions
Content-Type: application/json
Accept: application/json | text/event-stream
Authorization: Bearer <access-token>
```

该端点保持 OpenAI-compatible 裸响应，不使用 Gateway `{code,msg,data}` envelope。

带 user assets 的完整请求：

```json
{
  "session_id": "sess_01J2Y8",
  "turn_id": "turn_01J2Y9",
  "request_id": "req_01J2YA",
  "execution_id": "exec_01J2YB",
  "model": "deepseek-v4-pro",
  "messages": [
    {
      "role": "user",
      "content": "解释这张截图里的错误",
      "assets": [
        {
          "asset_id": 10001,
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "kind": "image",
          "mime_type": "image/jpeg",
          "filename": "build-error.jpg"
        }
      ]
    }
  ],
  "tools": [],
  "stream": true
}
```

Canonical fixture：
[chat_request_with_user_asset.json](fixtures/runtime-gateway-user-assets/chat_request_with_user_asset.json)。

要求：

- 任何 user-role message 包含 assets 时，四个顶层 identity 都必须非空；
- Gateway 每次请求重新校验完整历史中的每个 asset；
- 每条 user message 单独应用 4 张/10 MiB 单图/20 MiB 合计限制；
- 历史 messages 的资产只登记为当前 `session_id` 的 conversation 引用；
- `messages[].assets` 使用 Agent Wire v1.5 五字段 schema；禁止 URL、OSS key、upload ID、
  object key、bytes 和 Base64；
- 无 assets 的旧请求继续兼容，`turn_id/request_id` 可选；
- Runtime 发送的是已冻结的 `resolved_model`；Gateway 不参与 Agent Wire payload hash。

### 3.2 Gateway preparation order

Gateway 在调用 Provider 前按顺序完成：

1. wire/identity 校验；
2. owner/status/class/kind/business type/MIME/大小/尺寸/SHA hint 校验；
3. conversation 引用幂等 upsert；
4. 视觉直通准备，或 observation cache lookup/CAS + 视觉桥；
5. quota reservation；
6. 最后时刻签发 60...120 秒只读 URL；
7. Provider request。

视觉桥本身会产生费用时，步骤 4 与 5 可以在内部调整，但 Gateway MUST 在调用任何计费
Provider 前完成统一额度预留，并保证同一 `vision_observation_id` 的用户 usage 至多一次。

Prepared Provider messages 是派生副本。Gateway MUST NOT 把 observation、签名 URL 或
Provider 私有 content 写回 Runtime 请求对象、Runtime history 或对外响应。

## 4. Error contract

### 4.1 Error envelope

Chat 错误使用 OpenAI-compatible shape：

```json
{
  "error": {
    "type": "user_asset_error",
    "code": "asset_unavailable",
    "message": "One or more image assets are unavailable"
  }
}
```

Canonical fixture：
[chat_error_asset_unavailable.json](fixtures/runtime-gateway-user-assets/chat_error_asset_unavailable.json)。

| code | HTTP | Runtime mapping |
|---|---:|---|
| `asset_unavailable` | 404 | `turn_failed.asset_unavailable` |
| `asset_not_ready` | 409 | `turn_failed.asset_not_ready` |
| `invalid_assets` | 422 | `turn_failed.invalid_assets` |
| `asset_integrity_mismatch` | 422 | `turn_failed.asset_integrity_mismatch` |
| `image_input_unsupported` | 422 | `turn_failed.image_input_unsupported` |
| `image_processing_failed` | 502 | `turn_failed.image_processing_failed` |

Runtime MUST use `error.code`, not HTTP message text, as the stable mapping key。以上错误全部为
non-fallback：ResilientProvider/普通 Provider retry 不得把图片请求降级成纯文本。

安全规则：

- 不存在、无权、已删除、隔离状态返回完全相同的 `asset_unavailable` status/type/code/message；
- 只有已经确认属于当前 principal 的 pending asset 才能返回 `asset_not_ready`；
- response/log 不得包含 owner、bucket、OSS key、签名 URL、数据库状态或上游 body；
- 未知 `user_asset_error` code 映射为安全的 `request_failed`；
- Runtime 日志只记录 code、HTTP status、trace/correlation identity，不记录 error body。

### 4.2 SSE error

用户资产校验和视觉桥 MUST 在写 SSE header 前完成，因此对应错误使用真实非 2xx HTTP。
视觉直通在 HTTP 200/SSE 已开始后失败时，Gateway 发送：

```text
data: {"error":{"type":"user_asset_error","code":"image_processing_failed","message":"Image processing failed"}}

```

发送该 error frame 后立即结束 stream，不再发送 `[DONE]`。Runtime 必须解析
`data.error.code`，映射同一 `turn_failed`，且不得进行 non-stream fallback。

Canonical fixture：
[chat_sse_error_image_processing_failed.json](fixtures/runtime-gateway-user-assets/chat_sse_error_image_processing_failed.json)。
契约测试必须把该 JSON 紧凑编码为 `<payload>`，并断言线上帧恰为
`data: <payload>\n\n`。

## 5. Conversation asset-reference release

### 5.1 Request

Runtime 在 conversation 永久删除后调用：

```http
DELETE /api/v1/agent/conversations/sess_01J2Y8/asset-refs
Accept: application/json
Authorization: Bearer <access-token>
```

`session_id` 路径段必须 percent-encode。Gateway 只删除当前 principal 下满足：

```text
ref_type = agent_conversation
ref_key = session_id
```

的引用。不得影响其他 owner 或其他 ref type。

### 5.2 Idempotent response

普通 Gateway envelope：

```json
{
  "trace_id": "trace_release_001",
  "code": 0,
  "msg": "success",
  "data": {
    "session_id": "sess_01J2Y8",
    "released_refs": 2
  }
}
```

重复调用、未知 session 或已经释放时仍返回 HTTP 200/code 0，`released_refs = 0`，避免泄露
其他 principal 是否存在同名 conversation。

Canonical fixtures：
[release_asset_refs.json](fixtures/runtime-gateway-user-assets/release_asset_refs.json) 和
[release_asset_refs_replayed.json](fixtures/runtime-gateway-user-assets/release_asset_refs_replayed.json)。

Gateway 在一个数据库事务中：删除引用、按实际删除数递减对应 storage object ref count、
保证 ref count 不小于 0。释放不直接物理删除对象，后续 orphan/retention cleanup 决定。

### 5.3 Runtime durable release outbox

Gateway 暂时不可用不能阻止 Runtime 完成本地 conversation 删除。Runtime MUST 持久化
release outbox，并以同一 principal credential scope 重试，直到收到 HTTP 200/code 0。

- 401/403：暂停并等待 credential 恢复，不能改用其他用户 token；
- 404：视为 endpoint/configuration error，不能当成已释放；
- 5xx/network：指数退避；
- 重复投递安全，因为 release endpoint 幂等；
- Runtime 不复用已删除 conversation 的模型执行 credential 做其他操作。

## 6. Capability and lifecycle ordering

端到端发布顺序：

1. Gateway 部署 capability/chat error/reference release/vision preparation；
2. Runtime capability probe 成功后，才在新的 Agent Wire hello 发布 `image_input`；
3. AgentKit 看到 capability 后启用附件发送；
4. 任一后端能力失效时，新的连接 fail closed，现有草稿保留。

Gateway 部署完成不代表旧 Runtime 自动支持；Runtime 能解析 Gateway capability 但没有
durable inbox/user-assets event/error mapping 时，也不得向 AgentKit 发布 `image_input`。

## 7. Canonical fixtures and vendoring

Canonical 目录：

```text
docs/protocols/fixtures/runtime-gateway-user-assets/
```

Code-agent 和 agent-gateway 各自 vendor 全部文件、`manifest.sha256` 和 `SOURCE`。`SOURCE`
记录 AgentKit canonical commit 与路径。CI 必须：

1. 校验本地 manifest；
2. 校验记录的 canonical commit；
3. 禁止 fixture 缺失时跳过；
4. 禁止手工修改 vendor 文件。

## 8. Acceptance gates

合并前至少验证：

- capability success、认证失败、缓存过期 fail-closed；
- chat 四 identity 的缺失/长度/重试语义；
- 非流式六类资产错误与 SSE late error；
- 已知资产错误绝不触发 Provider fallback；
- 同 execution retry 不重复 quota/usage；
- 同 observation 并发/重放不重复 VLM 或用户计费；
- 完整历史的图片只产生 conversation 级引用；
- release 首次/重复/跨 owner/网络恢复；
- response、SSE、日志中不存在 STS、OSS key、签名 URL 或上游 body；
- 两仓 vendored fixtures 与 canonical manifest 完全一致。

## 9. Frozen fields

以下内容锁定：

- 三个 endpoint 路径和 Bearer auth；
- 四个 chat identity 字段名与稳定范围；
- capability response 的 contract/version/capabilities/limits shape；
- OpenAI-compatible user asset error shape、code 和 HTTP status；
- SSE error frame 与“不发送 `[DONE]`”语义；
- conversation release endpoint 与幂等 200 response；
- Runtime capability cache fail-closed 和 durable release outbox；
- canonical fixture vendoring/checksum 规则。

修改冻结项必须同时更新本文、fixtures 和 manifest，并由 AgentKit、Code-agent、
agent-gateway 三方确认。
