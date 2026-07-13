# AgentKit 多会话执行架构 v1

> 状态：Draft
>
> 适用端：macOS、iOS
>
> 配套 Runtime 设计：[Code-Agent Runtime 多会话执行要求 v1](../runtime-integration/code-agent-multi-session-runtime-v1.md)

## 1. 背景

AgentKit 当前把“用户正在查看的会话”和“唯一正在连接、运行的会话”绑定在一起：

- `WorkspaceStore` 只保存一个 `activeConversationViewModel`；
- `CodeAgentTransport` 只保存一个 `AgentWireSocket`；
- `attach(sessionID:)` 会先断开上一条连接；
- 发送、取消、审批等控制命令不显式携带会话目标，而是隐式作用于当前 socket；
- 切换会话需要异步连接新会话后才替换 VM，旧连接的迟到结果可能覆盖新选择；
- 未被选中的会话缺少可靠的运行中、等待审批、失败等状态展示。

这是一种单前台会话模型，不适合桌面 Agent 客户端。会话切换只应改变当前展示内容，不应中断、替换或取消其他会话的执行。

本设计将 AgentKit 改造成“一个工作区拥有多个独立会话控制器，选择仅决定展示”的模型，使用户可以同时运行多个任务、随时切换、集中处理审批，并准确控制任意会话。

## 2. 目标与非目标

### 2.1 目标

1. 同一客户端可以维护多个正在运行、排队、等待审批或已暂停的会话。
2. 切换会话不取消、不重连、不改变其他会话的执行状态。
3. 所有写操作都显式路由到目标 `sessionID`，禁止依赖“当前 socket”。
4. 后台会话的状态、未读事件和审批请求在侧边栏可见。
5. 审批请求可从全局入口处理，审批后回到对应会话。
6. 断线重连和历史回放不会重复投影事件，也不会让旧连接反向覆盖新选择。
7. macOS 本地 Runtime 支持真正的多会话并发；iOS 明确区分前台多会话与操作系统后台执行能力。
8. Runtime 未声明并发安全能力时，AgentKit 保持兼容的单执行模式。

### 2.2 非目标

- 本版本不把多个会话合并为一条共享上下文。
- 本版本不允许同一会话同时运行两个 turn；同一会话仍为串行 turn。
- 本版本不承诺 iOS 内嵌 Runtime 在应用被系统挂起后继续运行。真正后台执行需要远程 Runtime。
- 本版本不通过 UI 规避共享工作区并发写入问题；该问题必须由 Runtime 调度和工作区隔离共同保证。

## 3. 核心原则

### 3.1 Selection is not execution

`selectedConversationID` 只表示当前页面显示哪个会话。它不得拥有以下副作用：

- 断开旧会话；
- 取消旧 turn；
- 清空旧会话状态；
- 更改 Runtime 的活动会话；
- 把控制命令重新路由到新选择。

### 3.2 每个会话拥有独立控制平面

每个活动会话拥有自己的事件游标、连接、投影、发送队列、审批和取消目标。任何控制命令必须绑定 `sessionID`，必要时还需绑定 `turnID`、`requestID` 或 `executionID`。

### 3.3 同会话串行，跨会话可并行

- 同一 `sessionID`：最多一个活动 turn；
- 不同 `sessionID`：在 Runtime 能力、全局并发上限和工作区隔离允许时并行；
- 超过并发上限：进入可观测队列，而不是静默失败或抢占前台会话。

### 3.4 状态来源唯一且可重建

会话视图由持久化事件和明确的 Runtime 活动状态重建。WebSocket 只负责低延迟传输，不作为唯一真相来源。

### 3.5 平台生命周期显式化

macOS、iOS 前台、iOS 后台具有不同执行保证。UI 必须展示真实状态，不能把“应用挂起”伪装成“Runtime 仍在运行”。

## 4. 术语

| 名称 | 含义 |
| --- | --- |
| Conversation / Session | 一个持久化 Agent 会话，协议主键为 `sessionID` |
| Turn | 会话内一次用户输入及其完整 Agent 执行 |
| `RuntimeService` | 无会话状态的管理 API，如列表、创建、历史、能力查询 |
| `RuntimeSessionChannel` | 绑定单个 `sessionID` 的事件和控制通道 |
| `ConversationController` | AgentKit 内单个会话的状态机和投影所有者 |
| `ConversationSupervisor` | 管理全部控制器、选择、资源回收和全局审批的协调器 |
| Activity | Runtime 报告的运行、排队、等待审批、暂停等活动状态 |

## 5. 现状诊断

当前关键耦合点：

1. `WorkspaceStore.selectedConversation` 驱动唯一 `activeConversationViewModel`。
2. `WorkspaceStore` 只有一个共享 `RuntimeClient`。
3. `CodeAgentTransport.socket` 是单例状态，`attach` 首先执行 `disconnect`。
4. `send`、`approve`、`cancelTurn` 通过当前 socket 发送，不显式声明目标会话。
5. `ConversationViewModel.disconnect` 会断开共享客户端，VM 的生命周期因此影响其他会话。
6. 切换流程包含异步连接窗口，旧选择和新选择之间存在完成顺序竞争。

“立即断开/清空旧 VM，再安装新 VM”只能缓解旧连接覆盖新选择，仍会破坏后台执行，因此不作为最终修复。

## 6. 目标架构

```text
WorkspaceStore
  └─ ConversationSupervisor
       ├─ selectedConversationID ───────► 当前页面
       ├─ approvalInbox ────────────────► 全局审批入口
       └─ controllers[sessionID]
            ├─ ConversationController A ── RuntimeSessionChannel A
            ├─ ConversationController B ── RuntimeSessionChannel B
            └─ ConversationController C ── RuntimeSessionChannel C

RuntimeService ── list/create/history/capabilities/activity
```

选择 A、B 或 C 只替换页面订阅的控制器，不改变其余控制器及通道。

### 6.1 RuntimeService

管理 API 不持有“当前会话”：

```swift
public protocol RuntimeService: Sendable {
    func capabilities() async throws -> RuntimeCapabilities
    func listConversations() async throws -> [ConversationRef]
    func createConversation(_ request: CreateConversationRequest) async throws -> ConversationRef
    func history(sessionID: String, after sequence: Int?) async throws -> [AgentEvent]
    func activity() async throws -> [SessionActivity]
    func openSession(sessionID: String) -> any RuntimeSessionChannel
}
```

### 6.2 RuntimeSessionChannel

通道创建时绑定唯一会话，控制命令不再依赖全局当前 socket：

```swift
public protocol RuntimeSessionChannel: Sendable {
    var sessionID: String { get }

    func events(since sequence: Int) async throws -> AsyncStream<AgentEvent>
    func send(_ input: AgentInput) async throws
    func cancel(turnID: String?) async throws
    func approve(requestID: String, decision: ApprovalDecision) async throws
    func respondToClientTool(requestID: String, result: ClientToolResult) async throws
    func disconnect() async
}
```

首期可以继续采用“一会话一 WebSocket”，优点是协议改动小且路由边界清晰。后续可增加复用的 activity stream，但不能重新引入隐式当前会话。

### 6.3 ConversationController

每个控制器独立拥有：

- `sessionID` 和会话元数据；
- timeline/projection 和最后应用的事件序号；
- 当前 turn、模型统计、思考计时；
- 连接状态与重连任务；
- 等待审批和 client-tool 请求；
- 未读计数、失败状态和最后活动时间；
- 发送、取消、审批等绑定会话的命令。

建议状态：

```swift
public enum ConversationExecutionState: Equatable, Sendable {
    case dormant
    case connecting
    case idle
    case queued(position: Int?)
    case running(turnID: String)
    case waitingForApproval(turnID: String, requestIDs: [String])
    case paused(reason: PauseReason)
    case completed(turnID: String)
    case failed(turnID: String?, error: AgentError)
    case disconnected(recoverable: Bool)
}
```

网络连接状态和执行状态应分开建模。“socket 断开”不等于“turn 已失败”；Runtime 可能仍在执行。

### 6.4 ConversationSupervisor

监督器负责：

- 根据 `sessionID` 创建或复用控制器；
- 维护 `selectedConversationID`，立即切换展示对象；
- 汇总后台运行、排队、审批、失败和未读状态；
- 执行连接保活和空闲控制器 LRU 回收；
- 应用 Runtime capability，决定是否允许启动跨会话并发；
- 在启动和恢复时用 activity + history 重建控制器状态。

监督器不负责 turn 的业务投影；业务投影仍属于各自控制器。

## 7. 会话切换语义

切换必须是同步且无破坏性的：

1. 立即更新 `selectedConversationID`；
2. 若控制器已存在，立即展示其缓存投影；
3. 若不存在，立即创建占位控制器并开始加载历史；
4. 旧控制器保持原状态；
5. 加载完成只更新对应 `sessionID` 的控制器，不能再次修改 selection。

`selectionRevision` 仍然有价值，但只用于丢弃旧的“页面加载结果”，不能用它决定断开哪个运行会话：

```swift
let revision = selectionRevision
let targetID = selectedConversationID
let controller = supervisor.controller(for: targetID)
await controller.ensureLoaded()
guard revision == selectionRevision,
      targetID == selectedConversationID else { return }
// 仅提交与当前页面相关的派生 UI 状态
```

## 8. 连接与资源策略

不是所有历史会话都需要常驻 socket，但所有活动会话都必须被监督：

| 会话状态 | 连接策略 |
| --- | --- |
| running / queued | 保持连接；断线自动重连并回放 |
| waitingForApproval | 保持连接并进入全局审批箱 |
| client tool 执行中 | 保持连接；断线按 Runtime 可恢复语义处理 |
| selected + idle | 保持短期连接，便于即时发送 |
| background + idle | 可断开，保留投影和事件游标 |
| completed / failed | 空闲超时后 LRU 回收控制器 |

即使空闲控制器被回收，侧边栏状态仍由会话摘要和 Runtime activity 保留；重新进入时从最后序号增量恢复。

## 9. 后台状态与审批

### 9.1 侧边栏

每个会话至少展示以下一种状态：

- 运行中；
- 排队中及可选队列位置；
- 等待审批及数量；
- 已暂停；
- 失败；
- 已完成但有未读更新。

会话标题不得被临时工具输出或错误文本替代。

### 9.2 全局审批箱

审批项必须包含：

```text
sessionID + turnID + requestID + requestKind + summary + createdAt
```

用户可以直接审批，也可以先跳转到来源会话。审批命令必须发给审批项自己的 channel；当前选中会话不参与路由。

### 9.3 通知

后台会话进入审批、失败或完成时可发送本地通知。点击通知先选中对应会话，再定位事件；不能创建新控制器后误发命令到旧 socket。

## 10. 事件一致性与恢复

1. 每个持久化事件具备单调 `sequence`；控制器记录最后应用序号。
2. 重连使用 `since=lastSequence`，相同序号事件幂等忽略。
3. invocation、tool、approval 等业务对象继续使用自身 ID 去重。
4. 启动时先查询 Runtime activity，再为活动会话加载历史和建立通道。
5. 如果 activity 显示 running 而 socket 尚未建立，UI 应显示“恢复连接中”，不得显示为 idle。
6. 如果连接丢失，取消按钮可在重连后发送；如果 Runtime 提供无状态 HTTP cancel，可直接按 `sessionID/turnID` 取消。

## 11. Runtime 能力握手

AgentKit 不应仅根据版本号猜测并发安全性。全局能力通过 `GET /v1/runtime/capabilities` 获取；WebSocket hello 的字符串列表只描述当前连接的 transport feature。

Code-Agent R0 已上线的标准 envelope 中，`data` 使用紧凑结构，布尔能力和限制同处 `capabilities`：

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

AgentKit 同时兼容后续增加 `schema/protocol_version`、把限制移入 `limits` 的版本化扩展。endpoint 返回 404、所需字段缺失、未知显式 schema 或 HTTP/hello 互相冲突时，一律降级为单执行模式。不能因为 endpoint 存在就推断并发安全。

当前 `/v1/activity` 已能可靠返回持久化状态与 scheduler 的 `turn_id/queued/queue_position`。缺失的序号和 pending 数量仍表示“未知”，不得解释为零。即使旧 R0 Runtime 尚未开启 `activity_snapshot_v1`，AgentKit 也会在 capability endpoint 可用时兼容探测该 endpoint。

启用跨会话同时运行的最低门槛：

- `multi_session_execution_v1`；
- `session_scoped_client_tools_v1`；
- Runtime 返回明确的 workspace execution policy。

能力不足时，UI 仍可维护多个会话和切换，但新 turn 进入客户端队列，并说明当前 Runtime 只允许单执行。

## 12. 工作区并发语义

多会话不等于允许多个 Agent 无保护地修改同一目录。

AgentKit 创建会话时应携带或保存执行隔离信息：

- `isolatedWorktree`：每个会话独立 worktree，可按 Runtime 并发上限运行；
- `sharedWorkspace`：同一 workspace 默认一次只运行一个可能写入的 turn；
- `readOnly`：声明为只读或 plan 的 turn 可按 Runtime 策略并行。

最终仲裁必须由 Runtime 执行，客户端只负责展示策略、队列原因和冲突提示。

## 13. macOS 与 iOS

### macOS

本地 daemon 可在进程存活期间维护多个 session turn。窗口关闭、会话切换和 sidebar 折叠都不得取消后台 turn。应用退出前应清楚提示仍在运行的本地任务。

### iOS

- 应用前台：可以维护多个会话控制器，受内存和 Runtime 并发上限约束；
- 应用进入后台：内嵌 Runtime 可能被系统挂起，AgentKit 应把活动会话标为 paused/suspended；
- 远程 Runtime：应用断线不影响执行，恢复后通过 activity + history 重建；
- UI 不得承诺内嵌 Runtime 在系统后台持续运行。

## 14. 迁移方案

### Phase 0：契约与观测

- 定稿 Runtime 能力、activity、队列和定向控制契约；
- 给当前连接、selection、session、turn 打结构化日志；
- 增加“切换时活动 turn 未被取消”的现状回归用例。

### Phase 1：AgentKit 传输解耦

- 拆分 `RuntimeService` 与 `RuntimeSessionChannel`；
- 让 channel 实例绑定 `sessionID`；
- 保留现有单控制器 UI，但移除全局当前 socket 语义；
- 用适配器兼容旧 Runtime。

### Phase 2：Runtime 并发安全

- 完成 session-scoped client-tool broker；
- 修复 plan-tool 的跨 turn 共享引用；
- 增加全局调度器、定向取消、activity snapshot；
- 实施 workspace/worktree 执行策略；
- 对外声明 `multi_session_execution_v1`。

### Phase 3：AgentKit 多控制器

- 引入 `ConversationSupervisor` 和控制器字典；
- selection 只切换展示；
- 支持后台运行、队列、未读和状态徽标；
- 启用 Runtime 允许的跨会话并发。

### Phase 4：全局审批与平台恢复

- 增加 Approval Inbox 和通知跳转；
- 完成 macOS 重启恢复、iOS suspend/resume；
- 增加空闲连接 LRU 和资源上限。

### Phase 5：可选的多路复用

- 评估全局 activity stream 或单连接多会话协议；
- 仅优化资源，不改变显式 session 路由语义。

## 15. 测试与验收

### AgentKit 单元测试

- A 运行时切换到 B，A 控制器和 channel 不被断开；
- A、B 事件交错到达时只更新各自投影；
- 旧 selection 加载晚完成，不覆盖新的 selection；
- 从 B 页面取消 A，只取消 A；
- A、B 同时等待审批，分别路由到正确会话；
- 重连回放不重复消息、错误、统计或审批；
- 回收 idle 控制器不影响 running/waiting 会话；
- Runtime 不支持并发时，第二个 turn 明确排队。

### 跨仓集成测试

- 两个不同会话同时模型调用，均能独立完成；
- 同一会话第二个 turn 被拒绝或排队，状态明确；
- A 断线后 B 继续运行，A 重连后恢复相同结果；
- A 审批不会释放 B 的审批；
- A 取消不会取消 B；
- 两个会话的 client tool 结果不会串线；
- 同一共享 workspace 按策略串行，独立 worktree 可并行；
- Runtime 重启后活动/终态可从持久化事件重建。

### UI 验收

- 用户可启动 A，切到 B 并启动 B，再切回 A 查看实时进度；
- sidebar 同时展示 A/B 的真实状态；
- 任一后台审批都可被发现和处理；
- 运行中的会话始终有可用且目标明确的取消入口；
- 不再出现“切回来继续输出，但状态永远进行中且无法取消”。

## 16. 影响范围

| 模块 | 主要改动 |
| --- | --- |
| AgentKit Core | client 拆分、session channel、能力模型、事件路由 |
| Workspace | supervisor、控制器缓存、selection 语义、恢复流程 |
| Conversation | VM/Controller 生命周期、定向命令、幂等投影 |
| macOS/iOS UI | sidebar 状态、后台任务、审批箱、取消入口 |
| Code-Agent Runtime | 调度、会话级 broker、plan 隔离、activity、workspace 策略 |
| 测试 | reducer、竞争、重连、双会话、审批和工作区隔离 |

### 16.1 AgentKit 首批实现触点

| 当前文件 | 改造方向 |
| --- | --- |
| `Core/AgentClientImpl.swift` | 拆分 service/channel；移除单例 socket 和 attach 前全局 disconnect |
| `Features/Workspace/WorkspaceStore.swift` | selection 改为纯展示状态；引入 supervisor |
| `Features/Conversation/ViewModels/ConversationViewModel.swift` | 演进为 session-bound controller，禁止断开共享 client |
| `Core/RuntimeEngine.swift` | 明确 reducer 实例归属单 session，保持事件幂等 |
| `Features/Conversation/TimelineProjection.swift` | 确保 projection 不共享跨会话可变状态 |
| macOS/iOS sidebar 与 timeline | 状态徽标、全局审批、定向取消和恢复展示 |
| AgentKitTests | selection race、交错事件、定向控制、重连回放、能力降级 |

实际提交应以小切片推进，禁止在一个提交中同时替换传输层、状态机和全部 UI。

## 17. 决策记录

1. 采用“每会话控制器 + 每会话通道”，不采用“全局 active VM”。
2. 首期采用多 WebSocket，暂不把协议复杂度集中到单 socket 多路复用。
3. selection revision 只保护页面选择结果，不管理执行生命周期。
4. AgentKit 只有在 Runtime 声明并发安全能力后才开放跨会话同时执行。
5. 共享工作区安全由 Runtime 强制；UI 提示不能替代隔离和调度。
