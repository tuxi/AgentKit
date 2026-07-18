# Agent Wire Protocol v1.5 — User Assets

> 状态：**Frozen for implementation（2026-07-18）**。
>
> 本文是 Agent Wire v1 的向后兼容增量，建立在
> [Agent Wire v1](agent-wire-v1.md)、
> [v1.1 Client Tool Execution](agent-wire-v1.1-client-tool-execution.md)、
> [v1.2 Lifecycle](agent-wire-v1.2-lifecycle-suspend-resume.md) 和
> [v1.3 Tool Assets](agent-wire-v1.3-tool-assets.md) 之上。
>
> 本文中的 **MUST / MUST NOT / SHOULD / MAY** 为规范性要求。三方实现以本文和
> [`fixtures/user-assets`](fixtures/user-assets/) 中的 JSON 为共同契约。
>
> 版本说明：v1.4 标识已用于现有 `agent_input.model` 的 per-turn model selection；本文
> 不改变该字段，因此版本链从公开的 v1.3 专题文档直接链接到 v1.5。
>
> Runtime ↔ Gateway 的 HTTP shape、capability、SSE error 与引用释放由
> [Runtime–Gateway User Assets Contract v1](runtime-gateway-user-assets-v1.md) 冻结。

## 0. 目标与范围

v1.5 定义用户在一个文本 turn 中携带 Gateway 托管图片的端到端语义：

```text
Talkify/CoreKit        AgentKit             Go code-agent runtime       agent-gateway
select/prepare/upload  draft + wire encode  validate/persist/forward   authorize/resolve/vision
        │                     │                       │                         │
        └── asset_id ────────▶└── agent_input ──────▶└── asset refs ─────────▶│
```

首版只允许静态图片。PDF、视频、音频和任意文件附件需要新的 capability 或后续协议
增量，不能仅通过把 `kind` 改成其他字符串来提前上线。

以下内容不属于 Agent Wire：

- 本地 Photos/Files picker UI；
- 图片压缩、方向修正和缩略图生成；
- Gateway 的 STS/OSS 上传 HTTP API；
- OSS bucket、object key、签名 URL 或长期凭证；
- 上游视觉模型的供应商私有请求格式。

## 1. 核心原则

1. **引用优先**：Agent Wire 只传 Gateway 已接管的 `asset_id` 和最小描述信息。
2. **Gateway 是资产信任边界**：Runtime 和客户端都不能证明资产归属；Gateway 必须按
   当前认证主体重新校验。
3. **URL 不持久化**：签名 URL 只能在 Gateway 调用上游 Provider 时临时生成。
4. **Runtime 不下载用户图片**：Runtime 保存和转发引用，不读取 OSS，不持有 STS。
5. **同一引用贯穿历史**：用户消息中的 assets 必须在 live、SQLite/history 和 replay
   中保持同一顺序和字段。
6. **绝不静默丢图**：无法处理图片时必须产生规范错误，不能退化成只发送文本。

v1.3 的 `AgentAssetRef` 是 Runtime/UI 侧的工具产物索引，可以包含 workspace path、
preview 或 URI。v1.5 的 `UserAssetRef` 是 Gateway 托管资产引用。两者含义不同，禁止
因为都叫 asset 而互相直接序列化。

## 2. 能力协商

完整支持本文的 Runtime 在 `hello.capabilities` 中发布：

```json
{
  "type": "hello",
  "protocol_version": 1,
  "server": "codeagent/0.x",
  "capabilities": ["streaming", "session_resume", "image_input"]
}
```

`protocol_version` 仍为 major version `1`；v1.5 通过 capability 协商，不把握手字段改成
浮点数或字符串。

- `image_input` 表示从 Agent Wire 到 Gateway 视觉处理的**端到端能力可用**。
- Runtime 仅能解析 `assets`、但其 Gateway 不可用时，MUST NOT 发布该 capability。
- 客户端未看到该 capability 时，MUST NOT 发送带 assets 的输入；可以保留草稿并提示
  “当前服务不支持图片”，不得删除用户已经选择的本地图片。
- capability 是连接级快照；重连后客户端必须以新 `hello` 为准。

## 3. 上传前置条件

发送前，宿主 App 通过 Gateway HTTP API 完成：

```text
POST /api/v1/uploads/init
        → 短期 STS + asset_id + upload_id + object_key
客户端直传 OSS
POST /api/v1/uploads/complete
        → status=active 的资产
```

用户图片上传分类冻结为：

```json
{
  "asset_class": "user_upload",
  "asset_kind": "image",
  "business_type": "agent_user_attachment",
  "filename": "build-error.jpg",
  "content_type": "image/jpeg",
  "size_bytes": 245760
}
```

`asset_class = "agent_screenshot"` 只用于 Runtime 产生的截图工具资产，Talkify 用户选择的
图片不得使用该分类。`uploads/complete` SHOULD 携带本地计算的 `sha256`，Gateway 返回的
active asset metadata 是后续 `UserAssetRef` 的来源。

只有 `complete` 成功且状态为 `active` 的资产才能进入 Agent Wire。上传中的本地占位符、
`upload_id`、`object_key` 和 URL MUST NOT 出现在 `agent_input`。

客户端发送前 SHOULD：

- 修正 EXIF orientation；
- 去除不需要的定位等敏感 metadata；
- 将 HEIC/动态图片等不稳定格式转换为 JPEG 或 PNG；
- 在本地计算 SHA-256，并在上传 complete 时提交；
- 使用不含本地目录的安全文件名。

v1.5 互操作基线：

| 约束 | 值 |
|---|---|
| MIME | `image/jpeg`, `image/png` |
| 每个 turn 最大图片数 | 4 |
| 单图上传后最大字节数 | 10 MiB |
| 每个 turn 图片总字节数 | 20 MiB |
| 图片边长 | 32...8192 px |
| 动图 | 不支持；客户端转换为静态图 |

Gateway 是限制的最终执行方。客户端可采用更保守限制，但不能假定自己校验后 Gateway
一定接受。

## 4. Client → Runtime wire schema

### 4.1 `agent_input(kind = text)`

`agent_input` 新增可选 `assets`：

```json
{
  "type": "agent_input",
  "kind": "text",
  "request_id": "req_01J2Y8R3M6N9",
  "text": "解释这张截图里的错误",
  "model": "default",
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
```

`assets` 只允许出现在 `kind = "text"`。图片可单独发送，因此合法输入满足：

```text
trim(text) != "" OR len(assets) > 0
```

带 assets 的输入 MUST 携带非空 `request_id`。同一次重试必须复用完全相同的
`request_id`、文本、模型和有序资产列表。

### 4.2 `UserAssetRef`

| 字段 | 类型 | 必填 | 语义 |
|---|---:|---:|---|
| `asset_id` | int64 | 是 | Gateway 资产主键，必须大于 0；唯一权威身份。 |
| `sha256` | string | 否 | 64 位小写十六进制内容摘要；完整性提示。 |
| `kind` | string | 是 | v1.5 固定为 `image`。 |
| `mime_type` | string | 是 | v1.5 为 `image/jpeg` 或 `image/png`。 |
| `filename` | string | 是 | 仅展示用途的 basename，UTF-8，1...255 bytes。 |

规范要求：

- `asset_id` 是关联与鉴权键；其他字段不能覆盖 Gateway 数据库中的真实 metadata。
- `sha256` 存在时，Gateway MUST 与已完成上传的摘要比较。
- `filename` MUST NOT 包含 `/`、`\\`、NUL 或父目录语义。
- 数组顺序是用户选择/展示顺序，Runtime 和 Gateway MUST 保持顺序。
- 同一输入中重复 `asset_id` MUST 被拒绝，不能静默去重。
- 未定义字段必须被兼容实现忽略，但 `url`、`oss_key`、`object_key`、`upload_id`、
  `data`、`base64` 属于禁止字段；服务端 SHOULD 以 `invalid_assets` 拒绝，避免客户端
  误以为这些字段会生效。

完整 fixture：
[agent_input_text_with_image.json](fixtures/user-assets/agent_input_text_with_image.json)；
纯图片 fixture：
[agent_input_image_only.json](fixtures/user-assets/agent_input_image_only.json)。

## 5. Runtime 接收、幂等与持久化

Runtime 按以下顺序处理：

1. 解码 envelope 并做 wire-level 校验；
2. 以 `(session_id, request_id)` 查询 durable inbox；Runtime 不解析 Gateway JWT owner；
3. 新请求分配稳定 `turn_id`，原子保存 exact text、wire model、resolved model、有序 assets
   和持久化 `turn_accepted` event；
4. 排队时发布 `turn_queued`；
5. 真正执行时，以 `turn_id` 去重追加 user message，并发布带同一引用的
   `turn_started.user_assets`；
6. 将消息历史及 assets 原样发送给 agent-gateway。

幂等规则：

- 相同 request ID + 相同规范化 payload 返回原 `turn_id`，不得重复执行、上传或增加引用；
- 相同 request ID + 不同 text/model/assets 返回 `request_conflict`；
- 规范化 payload 必须包含**有序** asset refs；改变顺序也属于不同 payload；
- payload identity 使用 exact text、客户端原始 `agent_input.model`（空值保持空值）和有序
  assets；`resolved_model` 单独冻结保存，不参与冲突判断；
- Runtime 不根据文件名、SHA 或 asset ID 猜测并合并两次不同请求。

Runtime 持久化的 user message 结构与 §4 一致。SQLite/history/replay MUST 保存 assets；
不能只把 assets 放在当前进程内存中。

Durable inbox 的外部状态为：

```text
accepted → queued → running → completed | failed | cancelled
```

`reserved` 只能是数据库事务内的瞬时步骤。`turn_inputs` 与 `turn_accepted` event 必须在
同一事务提交，event log 同时作为可靠 outbox。user message 以
`(session_id, origin_turn_id)` 唯一，并与 inbox 进入 `running` 同事务完成。

Runtime 启动恢复 MUST 幂等处理：`accepted/queued` 重新调度；`running` 有终态事件时修正
为相应终态；`running` 已追加 user message 且无终态时进入既有 pause/resume 路径；
`running` 尚未追加 message 时回到 accepted。连续重启不得增加 user message、accepted
event 或新的 turn identity。

### 5.1 `turn_started.user_assets`

`turn_started` 新增同形可选字段 `user_assets`，便于 live/replay 客户端展示用户附件：

```json
{
  "kind": "turn_started",
  "event_id": "evt_100",
  "session_id": "sess_1",
  "turn_id": "turn_8",
  "at": "2026-07-18T08:00:00Z",
  "text": "解释这张截图里的错误",
  "user_assets": [
    {
      "asset_id": 10001,
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "kind": "image",
      "mime_type": "image/jpeg",
      "filename": "build-error.jpg"
    }
  ]
}
```

事件侧特意不复用 `assets`：v1.3 的 `tool_finished.assets` 是另一种
`AgentAssetRef` schema。使用 `user_assets` 可以避免统一 `wireEvent`/Swift decoder 把两种
资产错误解成同一类型。老客户端忽略新增字段；新客户端不能用 `event_id` 代替
`asset_id`。

fixture：
[turn_started_with_image.json](fixtures/user-assets/turn_started_with_image.json)。

## 6. 拒绝与失败语义

### 6.1 `agent_input_rejected`：尚未创建 turn

Wire shape、数量或本地幂等校验失败时，Runtime 返回非持久化 control frame：

```json
{
  "type": "agent_input_rejected",
  "request_id": "req_01J2Y8R3M6N9",
  "error": {
    "code": "invalid_assets",
    "message": "asset 10001 has an unsupported mime_type"
  }
}
```

该帧不带 `turn_id`，不得发布 `turn_accepted`。`error.code` 是开放集合，v1.5 定义：

能成功解码 `request_id` 时必须原样回显；若 envelope 在取得 request ID 前就无法解码，
`request_id` MAY 省略，连接必须保持可用。

| code | 条件 | 客户端动作 |
|---|---|---|
| `invalid_input` | text 和 assets 都为空，或 envelope 非法 | 保留草稿并提示修正 |
| `invalid_assets` | 字段、MIME、重复 ID 或禁止字段非法 | 标记对应附件失败 |
| `too_many_assets` | 数量超过 4 | 要求用户减少图片 |
| `image_input_unsupported` | 当前连接未提供能力 | 保留草稿，禁止重试直到 capability 改变 |
| `request_conflict` | request ID 被不同 payload 使用 | 生成新的 request ID 后由用户再次发送 |

fixture：
[agent_input_rejected_invalid_assets.json](fixtures/user-assets/agent_input_rejected_invalid_assets.json)。

### 6.2 `turn_failed`：turn 已被接受

Gateway 鉴权、资产状态或视觉处理发生错误时，Runtime 发布持久化 `turn_failed`：

| code | 语义 | 是否建议原 request ID 重试 |
|---|---|---:|
| `asset_unavailable` | 不存在、无权访问或已删除；不得向客户端区分这些情况 | 否 |
| `asset_not_ready` | 上传未 complete/尚未 active | 可在确认上传完成后重试新 turn |
| `invalid_assets` | Gateway 对真实 MIME、大小、尺寸或业务分类的权威校验失败 | 修正或重新上传后发起新 turn |
| `asset_integrity_mismatch` | SHA 与 Gateway 记录不一致 | 否；重新上传 |
| `image_input_unsupported` | 所选模型和视觉桥都不可用 | 更换模型后发起新 turn |
| `image_processing_failed` | 签名、下载、解码或视觉模型失败 | 可发起新 turn |
| `request_failed` | 其他不可恢复错误 | 视错误提示决定 |

为了防止枚举资产 ID，`asset_unavailable` 的外部 message MUST NOT 暴露资产属于其他用户、
真实 OSS key、bucket 或内部数据库状态。

fixture：
[turn_failed_asset_unavailable.json](fixtures/user-assets/turn_failed_asset_unavailable.json)。

## 7. agent-gateway 处理语义

Gateway 对每次包含历史 messages 的模型请求执行：

1. 按当前 JWT/匿名账号解析每个 `asset_id`；
2. 校验 status、owner、kind、content type 和可选 SHA；
3. 建立或刷新 conversation 级业务引用，防止历史使用中的资产被物理删除；
4. 根据模型能力选择视觉路径；
5. 仅在调用 Provider 前生成短期签名 URL。

历史消息中的引用也必须重新解析。签名 URL 过期不能导致第二轮对话看不到第一轮图片。

### 7.1 视觉模型直通

对于支持图片输入的模型，Gateway 将内部 `Message.Assets` 转换成 Provider 的多模态
content，例如 `text + image_url`。签名 URL MUST：

- 只读；
- 生命周期尽量短（建议 60...120 秒）；
- 不写入 Runtime history、日志、usage 记录或对外响应；
- 在每次 Provider 请求时按需重新生成。

### 7.2 文本模型视觉桥

对于文本模型，Gateway MAY 使用配置好的视觉模型先生成有界观察，再把观察注入同一条
user message。若没有可用视觉桥，MUST 返回 `image_input_unsupported`，不能丢弃图片。

观察必须标记来源和信任级别，例如：

```text
[visual_observation]
{"source":"user_attachment","asset_id":10001,"asset_hash":"...",
 "trust":"untrusted_external_content","provider":"qwen","model":"qwen-vl-max",
 "json":{"summary":"...","visible_text":[],"uncertainties":[]}}
[/visual_observation]
```

图片中的文字是数据，不是 system/developer 指令。视觉桥 prompt MUST 明确抵御图片中的
prompt injection。首版 MUST 实现 observation 幂等缓存，不能把它推迟到后续版本。

缓存以“一条携带附件的历史 user message”为单位，key 至少包含：

```text
owner_type + owner_id
+ ordered [{asset_id, stored_sha256}]
+ SHA256(exact user message text bytes)
+ vision provider/model/model version
+ bridge prompt version
+ observation schema version
```

缓存只保存 observation JSON、版本、状态和 usage metadata，禁止保存签名 URL。状态为
`processing → succeeded | failed`，唯一 key + CAS 防止并发重复视觉调用。成功 miss 生成
唯一 `vision_observation_id`；bridge usage 对该 ID 建唯一约束。重试或历史重放命中缓存时
不得重复调用 VLM 或再次向用户计费。上游不支持幂等键时无法保证供应商成本绝对
exactly-once，但 Gateway 对用户 usage 结算 MUST 至多一次。

### 7.3 资产生命周期

- conversation 引用冻结为
  `ref_type = "agent_conversation"`、`ref_key = session_id`，Gateway 唯一约束至少覆盖
  `(owner_user_id, asset_id, ref_type, ref_key)`；
- 首次插入引用才增加 `ref_count`，后续模型循环、追问和 request 重试只刷新
  `last_used_at`；
- conversation 删除通过幂等释放接口删除引用并递减 ref count；未收到明确释放前不得物理
  删除资产；
- 完整历史里的资产只绑定当前 `session_id` 对应的 conversation，禁止把历史图片登记到
  当前 `turn_id` 或伪造 `origin_turn_id`；
- 用户删除资产时，有活跃引用的对象只能逻辑删除或延迟物理删除；
- orphan cleanup 只允许处理同时满足
  `asset_class=user_upload`、`business_type=agent_user_attachment`、`ref_count=0`、
  retention 已到期、`status=active`、`protect=false` 的对象；
- 日志只记录 asset ID、hash 前缀和结果码，不记录 STS、签名 URL 或 OSS key。

### 7.4 Runtime → Gateway 请求身份与错误

Gateway chat 请求在存在 user assets 时 MUST 携带：

- `session_id`：conversation/reference identity；
- `turn_id`：当前 turn；
- `request_id`：客户端提交幂等 identity；
- `execution_id`：本次 Provider/工具执行及 usage identity。

这些字段不能互相替代。资产引用使用 `session_id`；usage/追踪使用其余 identity。

Gateway 在写 SSE header 前完成用户资产校验和视觉桥准备。非流式及 SSE 尚未开始时使用：

| code | HTTP |
|---|---:|
| `asset_unavailable` | 404 |
| `asset_not_ready` | 409 |
| `invalid_assets` | 422 |
| `asset_integrity_mismatch` | 422 |
| `image_input_unsupported` | 422 |
| `image_processing_failed` | 502 |

Runtime 以结构化 `error.code` 为权威，已知资产错误不得进入普通 Provider fallback。视觉
直通在 SSE 已开始后失败时，Gateway 发送包含同一 error shape/code 的 SSE error frame；
Runtime 不能只依赖 HTTP status。

### 7.5 SHA 语义

v1.5 的 SHA 是客户端声明的 integrity/correlation hint，不代表 Gateway 已计算并验证 OSS
对象的真实 SHA-256。Gateway 校验格式并与 upload complete 时保存的声明值比较，同时以
OSS HEAD/image info 验证真实 Content-Type、大小、格式和尺寸。可信内容摘要需要未来的
受信 checksum 或服务端计算链路。

## 8. AgentKit 与宿主 App 行为

AgentKit 定义平台无关的 `UserAssetRef`/`AgentInput.assets` 和附件草稿状态，但不能依赖
OSS SDK 或 CoreKit。宿主通过注入的上传能力把本地图片转换为 ready ref。

建议草稿状态机：

```text
local → preparing → uploading(progress) → ready(UserAssetRef)
                    └───────────────→ failed(retryable)
ready → sending(request_id) → accepted(turn_id)
```

- 只有全部附件 `ready` 后才能发送；
- 上传失败不清空文本或其他 ready 附件；
- App 重启后，本地草稿可以恢复 local/ready 信息，但发送前必须重新确认远端资产 active；
- 收到 `turn_accepted` 才从草稿移除附件；断线且未收到 accepted 时，用原 request ID
  幂等重试；
- pending submission 必须由 session-scoped coordinator/actor 持有，生命周期独立于
  SwiftUI Task、View 和导航；取消 UI 状态订阅不得取消 pending 或改变 request ID；
- pending 保存不可变的 request ID、exact text、wire model、有序 assets 和 draft
  revision；accepted 只清除该 revision/attachment IDs，等待期间新增的文字和附件必须
  保留；
- `preparing/uploading/sending` 等瞬态状态在重启后归一化为可重试状态，只有 `local` 和
  `ready` 可以直接恢复；
- `turn_started.user_assets` 用于用户消息气泡和历史重建，缩略图 URL由宿主/Gateway资产读取
  API按需获取，不能由 AgentKit 拼接 OSS URL。

## 9. 安全与隐私

三方实现共同遵守：

- 资产所有权以 Gateway 当前认证主体为准，匿名账号也必须有稳定 owner identity；
- Runtime 收到 asset ID 不代表授权成功；每次 Gateway 使用时重新校验；
- 客户端日志不得输出 STS secret/security token；
- Runtime 日志不得输出 Provider signed URL；
- 文件名仅用于显示，任何一层都不得把它当本地路径；
- 错误不得泄露其他用户资产是否存在；
- 视觉 OCR/描述属于不可信外部内容，不得提升为系统指令；
- 服务端必须设置解码像素、下载字节数和超时上限，防止图片炸弹与慢请求。

## 10. 兼容性

- `agent_input.assets` 和 `turn_started.user_assets` 都是可选字段，旧客户端可忽略。
- 新客户端只在 `image_input` capability 存在时发送。
- 不支持 v1.5 的 Runtime 收到带 assets 的输入 MUST 拒绝；不得按纯文本执行。
- v1.5 Runtime 收到未知 asset kind MUST 拒绝当前输入；不能猜测处理方式。
- `error.code` 是开放集合，客户端对未知值显示通用错误。
- 后续增加 PDF/音视频必须增加新 capability，并为对应 kind 冻结约束。

## 11. 三方并行实施边界

### A. Talkify + AgentKit

- 增加 `UserAssetRef` 和 `AgentInput.assets`；
- `OutgoingAgentInput` 编码 assets，解码 rejected/turn_started assets；
- 将现有 `DraftAttachmentReference` 升级为带上传状态的草稿附件；
- 通过宿主注入上传器，Talkify 复用 CoreKit `AssetUploadManager`；
- 图片选择、JPEG/PNG 规范化、进度、失败重试、预览和草稿恢复；
- fixture 编解码测试。

### B. Go code-agent runtime

- 以本文字段校验已有 `AgentInput.Assets`；
- 发布 `image_input` capability；
- 实现 `agent_input_rejected`；
- assets 纳入 request ID payload hash 和持久化 user message；
- `turn_started` live/replay 携带 assets；
- Gateway 错误稳定映射到 §6.2；
- golden、SQLite reload、idempotent retry 测试。

### C. agent-gateway

- 校验 owner/status/hash/MIME/大小/尺寸；
- 为 user-role assets 实现 VLM 直通或 vision bridge，不再只处理 screenshot tool result；
- 每次模型调用重新签发短 URL，支持历史图片；
- 实现引用登记、重复 request 幂等与 orphan retention；
- 错误码映射及不泄露存在性的安全测试；
- Provider payload、文本模型 fallback、多图片顺序测试。

三段可以同步开发，但合并前必须共同通过 §12 的 fixture 和端到端验收。

## 12. 验收门槛

### 12.1 契约测试

三方必须读取同一 fixture，至少覆盖：

1. 文本 + 单图编码；
2. 纯图片输入；
3. 非法 MIME 的 rejected；
4. `turn_started` live/replay 同形；
5. 无权资产统一映射为 `asset_unavailable`；
6. 相同 request ID + 相同资产不重复执行；
7. 相同 request ID + 不同资产返回 `request_conflict`；
8. 多图片顺序在 App → Runtime → Gateway → Provider 全程不变。

Fixture 目录还提供
[`hello_image_input.json`](fixtures/user-assets/hello_image_input.json)、
[`agent_input_two_images.json`](fixtures/user-assets/agent_input_two_images.json) 和
[`agent_input_rejected_request_conflict.json`](fixtures/user-assets/agent_input_rejected_request_conflict.json)，
用于锁定 capability、多图顺序和幂等冲突响应。

跨仓实施采用受控 vendoring，而不是依赖开发机绝对路径或缺失时跳过。Code-agent 和
agent-gateway 的 vendor 包必须包含全部 canonical fixtures、`manifest.sha256` 和
`SOURCE`；`SOURCE` 记录 AgentKit canonical 路径与来源 commit。CI 对缺失、checksum
不一致或来源 commit 不一致直接失败，vendor 文件不得手工编辑。

### 12.2 端到端测试

发布前必须验证：

- Talkify 匿名用户上传一张图片并成功询问；
- App 杀进程/重开后历史仍显示图片且可继续追问；
- WS 在发送后、`turn_accepted` 前断线，原 request ID 重试只产生一个 turn；
- Runtime 在 accepted、queued 和 running 窗口分别崩溃重启后，不重复 accepted event、
  user message 或 turn identity；
- 资产属于另一匿名用户时得到通用失败，不泄露存在性；
- 上传未 complete、资产被删除、SHA 不匹配都有稳定错误；
- 视觉模型直通与文本模型视觉桥各至少一条成功路径；
- 同一视觉桥输入并发、重试和历史重放只产生一个 observation 与一笔用户 usage；
- 同一 conversation 的多轮历史解析只建立一个资产引用，删除 conversation 后幂等释放；
- Gateway/Runtime 日志扫描不包含 STS secret、OSS key 和签名 URL；
- Release App 不依赖局域网服务。

## 13. 冻结项与变更规则

以下项目自本文状态变为 Frozen 起锁定：

- capability 名：`image_input`；
- 入站字段名：`assets`；
- `UserAssetRef` 五个字段及 `asset_id` 权威语义；
- `agent_input_rejected` envelope；
- `turn_started.user_assets` 的 live/replay 对等；
- 禁止传 bytes、OSS key 和 URL；
- §6 的错误码及安全折叠规则；
- Runtime `(session_id, request_id)` 幂等边界、raw wire model payload identity 和 durable
  inbox crash recovery；
- Gateway conversation 级引用、observation cache/usage 幂等与专用 orphan cleanup 条件；
- fixtures 的 canonical checksum 与受控 vendoring 规则。

实现过程中若要改动冻结项，必须先修改本文及 fixtures，再由三个实现方确认；只改单个
仓库视为协议不兼容。
