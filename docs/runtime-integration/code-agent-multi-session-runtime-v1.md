# Code-Agent Runtime 多会话执行要求 v1

> 状态：Draft
>
> 目标仓库：Code-Agent Runtime
>
> 客户端配套设计：[AgentKit 多会话执行架构 v1](../design/agentkit-multi-conversation-architecture-v1.md)

## 1. 目的

AgentKit 的多会话 UI 只有在 Runtime 能够安全地同时承载多个 session 时才成立。本文件定义 Code-Agent Runtime 需要提供的执行、路由、调度、审批、client tool、工作区隔离和恢复语义。

Runtime 的目标不是“允许多个 WebSocket”，而是保证多个会话在并发、断线、重连和审批情况下不会串线、互相取消或破坏共享工作区。

## 2. 当前基础与缺口

Code-Agent 已具备部分多会话基础：

- active turn registry 以 `sessionID` 为键，同一会话可拒绝重复 turn；
- subscription manager 提供 session 级事件总线和多订阅者；
- turn 执行可脱离创建它的 WebSocket 生命周期；
- remote approval 按 session 管理，重连可再次交付等待审批。

但尚不能据此声明完整的多会话并发安全：

1. client-tool waiter 绑定 WebSocket，断线执行 `CancelAll`，会把本可恢复的会话工具请求失败掉；
2. serve runner 的 plan tool 使用共享可变 `PlanRef`，并发构建 runner 时可能把 A 会话的 plan 命令路由到 B runner；
3. 缺少全局并发上限、公平排队和队列状态事件；
4. 共享 workspace 上只有 session 级 turn 锁，没有 workspace 级执行隔离；
5. 客户端启动或重连后缺少统一 activity snapshot 来发现所有运行、排队和待审批会话；
6. 控制命令的正确目标在部分路径中依赖当前连接上下文，缺少可验证的端到端路由标识。

当前实现的重点审计位置：

| Runtime 文件 | 当前职责 / 风险 |
| --- | --- |
| `internal/conversation/activeturn.go` | session 级 active turn registry，是并发基础 |
| `internal/conversation/subscription.go` | session 级事件订阅和回放入口 |
| `internal/server/ws.go` | WebSocket attach、审批、client tool 和断线清理边界 |
| `internal/server/tool_waiter.go` | 当前 connection-scoped waiter，需要迁移到 session broker |
| `internal/runtime/serve_builder.go` | 共享 `PlanRef` 写入点，需要改为 turn-scoped |
| conversation store / event log | activity snapshot、稳定 sequence 和恢复依据 |

实现前应再次全仓审计所有 package-level、builder-level 和 server-level 可变对象，不应只修复已发现的两个共享点。

## 3. Runtime 不变量

实现必须满足：

1. 一个 `sessionID` 同时最多一个活动 turn。
2. 多个 `sessionID` 可以在调度和 workspace policy 允许时同时执行。
3. 事件、审批、client tool、取消和恢复始终绑定明确 `sessionID`。
4. WebSocket 断开不自动取消 turn，也不删除等待审批。
5. 同一持久化事件只具有一个稳定 sequence，回放不得产生新的业务事件副本。
6. cancel 只作用于目标 session/turn，不能实现为全局 cancellation。
7. 同一 workspace 的执行服从 Runtime 强制策略，不能信任客户端自行避免冲突。
8. Runtime 只在全部前置能力完成后声明 `multi_session_execution_v1`。

## 4. 目标组件

```text
HTTP / WebSocket Server
  ├─ ActivityService
  ├─ SessionSubscriptionManager
  ├─ SessionControlRegistry
  │    ├─ RemoteApprover[sessionID]
  │    └─ ClientToolBroker[sessionID]
  └─ TurnScheduler
       ├─ ActiveTurnRegistry[sessionID]
       ├─ WorkspaceExecutionPolicy[workspaceID]
       └─ RunnerFactory (turn-scoped dependencies)
```

## 5. TurnScheduler

### 5.1 职责

- 限制全局并发模型 turn 数；
- 保证同一 session 只有一个活动 turn；
- 根据 workspace policy 决定立即运行或排队；
- 维护公平队列，避免单会话或单 workspace 饥饿其他任务；
- 支持取消排队中和运行中的指定 turn；
- 发布可持久化、可回放的队列和启动状态。

### 5.2 建议状态

```text
request received -> accepted -> queued -> running -> completed | failed | cancelled
                                -> waiting_approval -> running
```

建议新增或标准化持久化事件：

- `turn_accepted`: 请求完成校验并已取得稳定 `turn_id`；携带原始 `request_id`，服务端必须在回复/事件流中确认；
- `turn_queued`: `turn_id`, `reason`, `position`, `timestamp`；
- `turn_started`: 真正获得执行槽后发布；
- `turn_queue_updated`: 可选，队列位置发生变化；
- `turn_cancelled`: 明确区分排队取消和运行取消。

不得在尚未获得执行槽时发布语义不准确的 `turn_started`。

落库顺序固定为 `turn_accepted` → 可选 `turn_queued` → `turn_started`。`turn_accepted` 成功落库后客户端即可把发送状态从“发送中”改为“已接收”；在它之前断线，客户端可以用 client request ID 查询/幂等重试，不能假定请求已进入队列。

AgentKit 对每个 turn-starting `agent_input` 发送稳定 `request_id`。Runtime 必须以 `owner + session_id + request_id` 做幂等键；重复输入返回同一 `turn_id`，不得创建第二个 turn。

### 5.3 调度策略

首版建议：

- 配置项 `max_concurrent_turns`；
- 同 session FIFO；
- 跨 session round-robin；
- workspace lease 是获得全局执行槽后的第二道门；
- 首版采用保守占槽：turn 从 `turn_started` 到任一终态始终占用全局调度槽和 workspace lease，包括模型退避、等待审批、等待 client tool。排队状态不占执行槽。

保守占槽会降低峰值吞吐，但保证并发上限真实约束活跃 Agent，也避免等待期间释放 workspace 后被其他 Agent 改写上下文。后续若要细分 model slot 与 workspace lease，必须通过新 capability/schema 版本显式发布。

## 6. WorkspaceExecutionPolicy

### 6.1 为什么需要 Runtime 强制

两个 Agent 在同一目录并发读写会产生超出 Git 冲突的风险：一个 Agent 的上下文可能基于另一个 Agent 随后修改的文件，工具命令和测试也可能互相影响。因此共享 workspace 默认不能因为 session 不同就并行执行。

### 6.2 建议模式

```text
isolated_worktree  每个 session 使用独立 worktree，可并行
shared_workspace   同一 workspace 一次只允许一个可变 turn
read_only          明确禁止写入的 turn，可按配置并行
```

首版对 `shared_workspace` 应采用保守的 whole-turn lease。仅在工具执行瞬间加写锁不能保证 Agent 推理依据仍然有效。

lease key 应使用规范化 workspace identity，而不是未经解析的路径字符串。lease 释放必须覆盖完成、失败、取消、panic 和 Runtime shutdown。

### 6.3 会话元数据

创建 session 时持久化：

- `workspace_id`；
- `workspace_path` 或 worktree path；
- `execution_policy`；
- 可选 `base_workspace_id`，用于展示 worktree 来源。

Runtime 的 activity 和 queued reason 应暴露 workspace 等待原因，但不得泄露不必要的绝对路径。

## 7. ClientToolBroker 会话化

### 7.1 现有风险

当前 waiter 由 socket 拥有，断开时 `CancelAll`。这使“会话仍在 Runtime 执行”和“必须由当前连接完成 client tool”产生冲突，也会让会话切换造成工具失败。

### 7.2 目标语义

`ClientToolBroker` 应由 session control registry 持有：

- pending request 以 `sessionID + requestID` 为键；
- 新 socket attach 后成为该 session 的活动 client-tool sink；
- pending 请求在重连后重新交付，request ID 保持不变；
- 重复结果幂等忽略或返回明确 already-resolved；
- disconnect 不立即失败请求，由超时、turn cancel 或 session policy 决定；
- 同一 session 同时出现两个客户端连接时，必须定义 owner 选择或 claim 机制。

建议默认采用“最近成功 attach 的可执行客户端为 owner”，并给旧连接发送 ownership changed。只读观察连接不得抢占 owner。

### 7.3 安全边界

client tool 响应必须同时验证：

- session 匹配；
- request 仍 pending；
- 连接拥有执行权；
- 工具名称和响应 schema 匹配；
- 重复响应不再次产生 `tool_finished`。

## 8. Plan tool 隔离

共享 `PlanRef` 是跨会话串线风险。修复要求：

- 每次 Build/turn 创建独立 plan runner 引用；
- tool registry 中的 plan tool 捕获 turn-scoped ref；
- 禁止在共享 builder 上写入“当前 runner”；
- 更优方案是从 tool execution context 获取当前 runner/turn，而不是通过全局可变指针。

必须增加并发回归测试：同时构建并运行 A、B，交错调用 plan update，断言每次更新只进入自己的 event stream 和持久化历史。

## 9. ActivityService

### 9.0 路径、鉴权与所有权

首版固定以下路径：

```text
GET /v1/activity
GET /v1/activity/stream   # 可选的 SSE；首版客户端不依赖它
```

两者使用与 conversation API 相同的 Bearer credential 和 device context，不提供匿名旁路。服务端必须按认证主体过滤 session：

- 远程 Runtime：只返回 `owner_subject` 等于当前 credential subject 的 session；
- 本机单用户 Runtime：session 归属当前 runtime instance，仍应用 device context 校验；
- 管理员跨用户查看必须使用独立管理端点，不得复用 `/v1/activity`；
- 响应中的 pending request 只返回摘要和 ID，不返回未授权 workspace 路径或工具秘密参数。

### 9.1 Snapshot

Runtime 提供一次性活动快照，供客户端启动、恢复和定期校准：

```json
{
  "sessions": [
    {
      "session_id": "session_a",
      "turn_id": "turn_3",
      "state": "waiting_approval",
      "last_sequence": 183,
      "pending_approval_count": 1,
      "pending_client_tool_count": 0,
      "queue_position": null,
      "updated_at": "2026-07-13T06:00:00Z"
    }
  ]
}
```

状态至少包括：`queued`、`running`、`waiting_approval`、`paused`。完成和失败通常由历史终态表达，可在短期 activity 中保留以便通知。

### 9.2 Stream

首期允许 AgentKit 为每个活动 session 建立 WebSocket。后续可增加全局 activity stream 降低连接数量，但 stream 中每一项必须携带 `session_id`，且不能承担所有业务事件的唯一持久化职责。

## 10. 定向控制 API

所有控制操作都必须具备完整目标：

```text
cancel:             sessionID + optional turnID
approve:            sessionID + turnID + requestID + decision
client tool result: sessionID + turnID + requestID + result
resume:             sessionID
```

如果继续使用 session 专属 WebSocket，服务端仍需用 URL/session context 验证 payload 所属 session。未来改为多路复用连接时，payload 中的 `session_id` 成为必填字段。

错误响应应区分：

- session 不存在；
- turn 已终止；
- request 已处理；
- 当前连接不是 client-tool owner；
- target mismatch；
- 取消已接受但尚未完成。

## 11. 审批语义

remote approver 已接近目标，但需纳入统一 activity/control 契约：

- pending approval 与 session 生命周期绑定，不与 socket 绑定；
- attach/reconnect 重发相同 request ID；
- 多客户端响应采用原子 first-decision-wins；
- 决策持久化后再恢复 runner；
- activity snapshot 返回 pending count 和最早请求时间；
- cancel turn 会关闭该 turn 所有 pending approval，并产生确定终态。

## 12. 事件与错误语义

多会话状态依赖可重建事件，因此每个生命周期事实只能有一个权威展示来源：

- `model_finished` 用于闭合单次模型调用和统计；
- 导致 turn 失败的权威错误由 `turn_failed` 发布；
- 不应在 `model_finished.err` 和紧随其后的 `turn_failed.err` 重复发布同一可展示错误；
- quota 错误应保留 `quota_exceeded` 分类，不能泛化为 `request_failed`；
- 所有事件保持稳定 sequence、turn ID、invocation/request ID。

该错误去重修复可独立落地，但应遵守本设计的“生命周期事实单一来源”原则。

### 12.1 取消终态与迁移

`turn_cancelled` 定义为与 `turn_finished`、`turn_failed` 互斥的第三种权威终态：

```json
{
  "kind": "turn_cancelled",
  "session_id": "session_a",
  "turn_id": "turn_3",
  "reason": "user_requested",
  "at": "2026-07-13T06:00:00Z"
}
```

- cancel 请求只表示“已接收取消”，直到持久化 `turn_cancelled` 才完成；
- 同一 turn 的多个终态采用 first-terminal-wins，后续终态不得落库；
- `turn_cancelled` 回放必须得到与直播相同的 cancelled UI，不显示为失败；
- 兼容旧 Runtime：连接结束且客户端刚发送 cancel 时，AgentKit 可本地结束动画，但历史重建仍以已有 `turn_finished/turn_failed` 为准；
- 旧版使用 `turn_failed(error.code=cancelled)` 的历史可映射为 cancelled 展示，不重写历史事件；
- Runtime capability schema v1 开启后，新事件不得再用无终态断流表达取消。

## 13. 能力发现

能力的权威入口固定为：

```text
GET /v1/runtime/capabilities
```

Code-Agent R0 返回 Runtime 标准 envelope，当前 `data` 的稳定形态为：

```json
{
  "capabilities": {
    "multi_session_execution_v1": false,
    "session_scoped_client_tools_v1": true,
    "activity_snapshot_v1": true,
    "workspace_execution_policy_v1": true,
    "max_concurrent_turns": 2,
    "max_connected_sessions": 0
  }
}
```

现有 WebSocket `hello.capabilities: [String]` 继续保留，作为该连接可用的 transport feature 列表；它不是 Runtime 全局调度能力的权威来源。AgentKit 只有在 HTTP capability snapshot 声明并发能力，且 session hello 没有否定所需传输能力时才开放并行。旧 Runtime 返回 404 时，客户端降级为单执行模式。

AgentKit 解码器也接受后续版本化扩展：顶层增加 `schema/protocol_version`，并把限制移入 `limits`。限制缺失表示使用客户端保守值，不代表无限制；显式 `schema` 未识别时必须降级，不能按字段猜测。

`GET /v1/activity` 已合并持久化 lifecycle 与 scheduler 实时状态，可返回 `session_id/turn_id/state/queue_position/updated_at`。未返回的 pending 数量和 sequence 表示未知。旧 R0 即使 `activity_snapshot_v1=false`，AgentKit 也会在 capability endpoint 成功后兼容探测该 endpoint。

`agent_input.request_id` 是 turn 创建的持久化幂等键。客户端重发同一输入时必须复用原 ID；Runtime 返回原 `turn_id`，不得再次 accepted、排队或执行。Session control revision 由 Runtime 绑定到 WebSocket connection，客户端不携带 revision 字段；旧连接延迟到达的 approval 或 client-tool result 由 Runtime 拒绝。

声明 `multi_session_execution_v1=true` 前必须完成：

1. plan tool turn 隔离；
2. session-scoped client tool；
3. 定向 cancel/approval；
4. scheduler 与同 session 锁；
5. workspace execution policy；
6. 双会话并发和断线恢复测试。

能力应代表语义保证，而不仅是 endpoint 存在。

## 14. 进程与持久化

CLI 可通过多进程获得天然隔离；GUI daemon 的多会话通常共享同一进程，因此需要显式限制共享可变状态。

检查清单：

- runner、plan ref、tool call context、approval waiter 不使用无 session key 的全局可变实例；
- 模型客户端可共享连接池，但 request context 和 cancellation 独立；
- SQLite 可串行写入保证一致性，但 DB 锁不能替代执行调度；
- Runtime 重启后，无法继续的本地 turn 要生成明确 interrupted/failed 终态，不能永久保持 running；
- 远程可恢复执行则需要持久化 scheduler 和 broker 状态，首版可声明不支持跨进程继续。

## 15. macOS 与 iOS Runtime

### macOS daemon

- 支持多个活动 session；
- GUI 断开不取消任务；
- daemon 退出策略必须考虑活动 turn；
- activity snapshot 是 GUI 重启恢复的入口。

### iOS embedded

- 前台可以按更低的并发上限运行；
- app lifecycle 进入后台时统一 suspend，并向所有活动 session 发布/保存 paused 状态；
- 恢复时逐 session 校准 activity 和历史；
- 不声明系统挂起期间继续执行，除非迁移到远程 Runtime 或具备受支持的后台执行机制。

## 16. 实施顺序

### R0：协议和测试骨架

- 定稿 capability、activity、queued 和定向控制结构；
- 建立两个 session 的并发集成测试 harness；
- 给关键状态增加 session/turn/request 结构化日志。

### R1：消除跨 turn 共享状态

- plan ref turn-scoped；
- 审计 runner builder、tools、model client、approval 和 cancellation；
- 增加 race test。

### R2：会话级控制 broker

- client tool 从 socket waiter 迁移为 session broker；
- reconnect replay、ownership 和幂等响应；
- 定向 cancel/approve/client-tool result。

### R3：调度与工作区策略

- TurnScheduler、队列事件和并发 limits；
- workspace identity、whole-turn lease、worktree 模式；
- queued cancel 和 shutdown 清理。

### R4：activity 与能力开放

- activity snapshot；
- 重启/断线校准；
- 全部验收通过后开启 `multi_session_execution_v1`。

### R5：优化

- 可选 activity stream；
- 连接和订阅上限；
- scheduler 公平性、指标和背压。

## 17. 测试矩阵

| 场景 | 预期 |
| --- | --- |
| A/B 同时启动 | 在不同 workspace/worktree 且有槽时并行完成 |
| 同一 session 启动第二 turn | 明确 busy 或 FIFO 排队，不并行 |
| cancel A | B 不受影响，A 产生唯一终态 |
| A/B 同时审批 | request 路由独立，first-decision-wins |
| A client tool 时断线 | turn 保持等待，重连重发同 request ID |
| B 响应 A 的 client tool | 拒绝 target mismatch |
| A/B 并发 plan update | 各自历史只出现自己的 plan |
| 共享 workspace 两 turn | 后者因 workspace policy 排队 |
| 独立 worktree 两 turn | 可并行且文件修改互不污染 |
| 重连事件回放 | 无重复消息、错误、工具结果和 usage |
| Runtime 重启 | 不留下永久 running；activity 与历史一致 |
| 达到并发上限 | 新 turn 排队，位置和原因可观测 |

所有并发测试应在 Go race detector 下运行。

## 18. 跨仓交付门槛

### Code-Agent 提供

- capability 和 limits；
- activity snapshot；
- session-scoped client-tool broker；
- turn-scoped plan tools；
- scheduler 与 workspace policy；
- 定向控制和完整回归测试。

### AgentKit 提供

- RuntimeService / RuntimeSessionChannel 分层；
- ConversationSupervisor 和多控制器；
- selection 与 execution 解耦；
- sidebar 状态、全局审批、后台恢复；
- 能力降级和跨仓集成测试。

### 联合启用条件

只有 Runtime 返回 `multi_session_execution_v1=true` 且 AgentKit 完成 session-bound routing 后，产品配置才允许用户同时启动多个会话。任一侧未就绪时仍可发布多会话浏览能力，但执行必须安全降级为串行队列。

## 19. 建议提交切片

为降低跨仓联调风险，建议保持以下提交边界：

1. `runtime: isolate plan tools per turn`；
2. `runtime: make client tool requests session scoped`；
3. `runtime: add targeted session controls and activity snapshot`；
4. `runtime: add turn scheduler and workspace execution policy`；
5. `agentkit: split runtime service from session channel`；
6. `agentkit: introduce conversation supervisor`；
7. `agentkit: add background status and approval inbox`；
8. `integration: enable multi-session capability and end-to-end tests`。

每个 Runtime 切片先提供协议 fixture 和测试，再由 AgentKit 消费；能力位只在整个保证闭合后打开。
