# AgentKit Workspace、Worktree 与会话本地状态设计 v1

> 状态：Active — Runtime M0–M4、AgentKit W2/W3 与服务端原子删除保护已完成；归档契约保留为独立产品里程碑
>
> 适用端：macOS、iOS
>
> 上位设计：[AgentKit 多会话执行架构 v1](agentkit-multi-conversation-architecture-v1.md)
>
> Runtime 配套契约：[Code-Agent Managed Worktree v1](../runtime-integration/code-agent-managed-worktree-v1.md)

## 1. 目的

多会话执行已经允许不同 workspace 并行，并对共享目录采用 whole-turn lease。下一步需要在同一个 Git 项目中安全地并行多个会话，同时避免把 Git worktree、分支、workspace 和 conversation 混成同一个概念。

本设计冻结以下长期边界：

1. 创建会话默认不创建 worktree；worktree 是用户显式选择的执行方式。
2. Worktree 是同一个 Workspace 下的隔离 checkout，不是新的顶层 Workspace。
3. 分支名称用于 Git 和展示，不作为 workspace、checkout 或 session 的稳定身份。
4. Runtime 负责 worktree 的创建、恢复、路径安全和清理；AgentKit 负责选择、展示和用户确认。
5. 模型偏好、输入草稿和已读游标属于客户端本地持久化状态，不属于 Runtime lifecycle 事实。

本设计参考两类成熟交互：

- [Claude Code Worktree](https://code.claude.com/docs/en/worktrees) CLI 使用显式 `--worktree`，默认路径为 `<project>/.claude/worktrees/<name>`；[Claude Desktop](https://code.claude.com/docs/en/desktop) 将 session 按 project 组织，并用 worktree 隔离各 session。
- [Codex App](https://openai.com/index/introducing-the-codex-app/) 将 thread 按 project 组织，worktree 是 agent 的隔离代码副本，而不是新的 project。

CodeAgent 不复制“每个新会话自动创建 worktree”的默认行为，而采用显式 opt-in，以兼顾轻量问答、共享工作区任务和隔离并行任务。

## 2. 术语与身份

| 概念 | 定义 | 稳定身份 | 示例 |
| --- | --- | --- | --- |
| Workspace / Project | 用户添加并在侧边栏分组的主项目 | `baseWorkspaceID` | `AgentKit` |
| Checkout | Runtime 实际执行文件工具和命令的物理目录 | `workspaceID`，未来可别名为 `checkoutID` | 主目录或一个 worktree 目录 |
| Managed Worktree | Runtime 为会话托管的隔离 checkout | 独立 `workspaceID` + 持久化 worktree metadata | `.codeagent/worktrees/token-ui-a31f` |
| Branch | Checkout 当前检出的 Git ref | 不作为产品主键 | `codeagent/token-ui-a31f` |
| Conversation / Session | 持久化 Agent 会话 | `sessionID` | “升级 Token 展示” |
| Turn | 会话内一次完整执行 | `turnID` | 一次用户发送到终态 |

身份关系固定为：

```text
Workspace(baseWorkspaceID)
  ├─ Main Checkout(workspaceID = main)
  │    ├─ Conversation A
  │    └─ Conversation B
  ├─ Managed Worktree Checkout(workspaceID = wt-a31f)
  │    └─ Conversation C
  └─ Managed Worktree Checkout(workspaceID = wt-b82d)
       └─ Conversation D
```

### 2.1 不变量

- 一个 conversation 绑定一个 checkout；首个 turn 开始后不静默切换 checkout。
- 一个 managed worktree v1 只绑定一个 conversation；conversation 的后续 turn 复用该 worktree。
- `baseWorkspaceID` 决定 UI 项目分组和 worktree 来源。
- `workspaceID` 决定 Runtime workspace lease 和资产 URI 的 checkout 身份。
- `workspacePath` 是本机执行路径，不是跨设备身份。
- branch 可重命名、detached 或被用户手动操作，因此不能作为主键。
- worktree 目录名称用于可读性，仍必须附带短随机 ID 防冲突。

## 3. 新建会话交互

### 3.1 默认策略

新会话默认采用：

```text
execution_policy = shared_workspace
managed_worktree = false
```

点击“新建任务”只创建本地 `SessionDraft`。用户第一次发送时才创建真实 session；如果用户未选择 worktree，Runtime 不得执行 `git worktree add`。

### 3.2 显式 Worktree 选项

Composer 的 workspace chip 区域提供显式选项：

```text
Local · AgentKit · main · □ 独立 Worktree
```

选择后展示预期 checkout：

```text
Local · AgentKit · main → codeagent/token-ui-a31f · ☑ Worktree
```

第一次发送的顺序为：

1. AgentKit 冻结 draft 的 workspace、模型、执行策略和 `clientRequestID`。
2. 请求 Runtime 创建 managed worktree session。
3. Runtime 返回 `ready` 后，AgentKit 才发送首个 turn。
4. 创建失败时保留本地输入草稿、模型和 worktree 选择，允许重试或回退共享工作区。
5. 不允许出现 session 已开始执行但 UI 仍把它归类为主 checkout 的中间状态。

### 3.3 Base ref

首版提供两个来源：

- `head`：从用户选中主 workspace 的当前 `HEAD` 创建；推荐默认。
- `fresh`：从远端默认分支创建干净 worktree；无远端时按 Runtime 契约失败或明确回退。

两者都只包含已提交 Git 对象。主工作区未提交修改和未跟踪文件不会自动进入 worktree。UI 在源 workspace 脏时必须提示这一点，不能让用户误以为 worktree 复制了当前文件系统状态。

## 4. 路径与命名

### 4.1 默认路径

Managed worktree 默认位于：

```text
<project-root>/.codeagent/worktrees/<slug>-<short-id>/
```

例如：

```text
/repo/AgentKit/.codeagent/worktrees/multi-session-cache-a31f/
```

使用复数 `worktrees`，与其容器语义一致。允许未来在设置中配置外部根目录，但客户端不能在每次创建时提交任意未授权绝对路径。

### 4.2 分支命名

默认新分支：

```text
codeagent/<slug>-<short-id>
```

要求：

- slug 仅用于可读性；短 ID 保证并发和重试下不冲突。
- Runtime 最终决定合法化后的目录和分支名称，客户端只提供建议名称。
- 客户端不得从 user prompt、会话正文或文件内容自动派生 `suggested_name`；这既会泄露用户内容，也会把任意 Unicode 和标点带入路径、Git ref、日志及外部工具边界。
- `suggested_name` 只能来自用户显式填写的 Worktree 名称，或草稿创建时一次性生成并保持稳定的 ASCII 可读名称（如 `fervent-mirzakhani`）；字段缺失时由 Runtime 安全回退。Runtime 仍负责最终合法化并追加 reservation 短 ID。
- 目录名、分支名和会话标题允许不同步变化。
- session 重命名不得自动重命名已存在的目录或分支。

### 4.3 项目内目录的隔离风险

将 worktree 放进项目目录会产生递归扫描和跨会话可见性风险。Managed Worktree v1 开启前必须同时满足：

1. Runtime 将 `/.codeagent/worktrees/` 写入 Git common dir 的本地 exclude；不得擅自修改用户需要提交的 `.gitignore`。
2. Runtime 的 `list_files`、`grep`、project graph、文件 watcher、索引和上下文发现明确排除 managed worktree 根目录。
3. base workspace 中的 Agent 不能读取另一个会话 worktree 的文件，除非用户显式把路径加入授权范围。
4. 禁止在 managed worktree 内再次创建 managed worktree；必须回到其 `baseWorkspaceID` 对应的主项目。
5. 规范化真实路径并防止 symlink、`..` 或大小写差异绕过排除和 workspace lease。

仅依靠 `.gitignore` 或 UI 分组不构成隔离保证。

## 5. 侧边栏与 Workspace 分组

Worktree session 仍显示在来源 Workspace 下：

```text
AgentKit
├─ 修复会话状态        main
├─ 升级 Token 展示     token-ui-a31f · worktree
└─ 重构审批交互        approval-ui-b82d · worktree
```

分组规则：

1. 优先使用 `baseWorkspaceID` 查找主 Workspace。
2. 没有 `baseWorkspaceID` 的旧 session 继续按原 `workspaceID/path` 分组。
3. branch 和 worktree 是 row metadata/badge，不创建新的顶层 Workspace。
4. Worktree 丢失时仍保留原 Workspace 分组，并显示“Worktree 不可用”，不得生成幽灵 Workspace。
5. 排队原因区分全局并发上限、共享 workspace lease 和 worktree provisioning。

## 6. Worktree 生命周期与用户所有权

建议状态：

```text
not_requested
  → provisioning
  → ready
  → retained
  → removing
  → removed

provisioning/removing → failed(recoverable)
```

### 6.1 创建

- 只在用户选择独立 worktree 后创建。
- 创建请求必须幂等；网络重试不得产生第二个目录、分支或 session。
- 创建完成和 session metadata 落库之间必须具备崩溃恢复策略。
- Runtime 返回 ready 之前，不启动首个 turn。

### 6.2 保留与恢复

- turn 完成、失败或取消不删除 worktree。
- app/Runtime 重启后，conversation 重新绑定同一规范化路径和 checkout identity。
- 用户可在 Finder、Terminal 或 IDE 打开 worktree；Runtime 不假设目录只由自己修改。
- 用户手动删除或移动目录后，Runtime 报告 missing/needs_rebind，不自动创建一个同名空 worktree 覆盖事实。

### 6.3 归档和删除

- Runtime `6e4875a` 仅开放永久删除并提供原子 `conversation_in_use` 保护；归档、归档列表和恢复 API 尚未开放，AgentKit 当前不显示归档入口，也不在本地伪造归档状态。
- 未来开放归档契约后，归档 conversation 默认保留 worktree，并由 Runtime 持久化归档事实。
- 删除 conversation 时必须明确选择 `keep` 或 `remove`，不能隐式删除。
- worktree 有未提交修改、未跟踪文件或新提交时，普通 remove 返回冲突并要求用户确认。
- v1 的“删除 worktree”只移除 checkout；不自动删除 Git 分支。
- force remove 属于破坏性操作，必须由宿主 UI 二次确认，Runtime 不能根据 session 已完成自行执行。

## 7. 能力与兼容降级

能力分层：

```json
{
  "workspace_execution_policy_v1": true,
  "multi_session_execution_v1": true,
  "managed_worktree_v1": false
}
```

- `workspace_execution_policy_v1=true` 只说明 Runtime 能按已存在 checkout 执行和加 lease。
- `managed_worktree_v1=true` 才说明 Runtime 能安全创建、恢复、检查和移除 worktree。
- AgentKit 不得因为 `isolated_worktree` 已可用就猜测 Runtime 支持 `git worktree add`。
- 能力缺失时隐藏 managed worktree 创建选项；已有外部 worktree 仍可作为普通 Workspace 添加。

## 8. ConversationLocalStateStore（后续里程碑）

### 8.1 为什么不是普通缓存

以下数据是客户端拥有的持久状态，不能按可丢弃 cache 处理：

- 每个 conversation 尚未发送的输入草稿；
- 新建 session draft 的输入、workspace 和执行策略；
- 每个 conversation 当前模型及最近使用模型；
- 已读 sequence 和 attention notification 游标。

当前实现已经存在：

- `ModelSettingsStore.lastSelectedModel`；
- `ModelSettingsStore.usedModels[conversationID]`；
- `ConversationAttentionReadStore` 的 terminal/notification 游标。

但输入文本仍由 `DraftComposerPanel.@State` 持有，App 退出或 view 重建后会丢失；并且模型偏好与已读状态分散在不同 Store。长期应引入统一持久化边界：

```swift
public protocol ConversationLocalStateStore: Sendable {
    func state(for key: ConversationLocalStateKey) async throws -> ConversationLocalState?
    func save(_ state: ConversationLocalState, for key: ConversationLocalStateKey) async throws
    func migrateDraft(_ draftID: UUID, to sessionID: String) async throws
    func removeState(for key: ConversationLocalStateKey) async throws
    func flush() async
}
```

### 8.2 建议数据结构

```swift
public enum ConversationLocalStateKey: Hashable, Sendable {
    case draft(UUID)
    case session(String)
}

public struct ConversationLocalState: Codable, Sendable, Equatable {
    public var composerDraft: ComposerDraft
    public var selectedModelID: String?
    public var recentModelIDs: [String]
    public var lastReadSequence: Int64
    public var lastSeenTerminalSequence: Int64
    public var lastNotifiedTerminalSequence: Int64
    public var lastNotifiedApprovalSequence: Int64
    public var updatedAt: Date
}

public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [DraftAttachmentReference]
    public var workspaceID: String?
    public var executionPolicy: String?
    public var wantsManagedWorktree: Bool
    public var updatedAt: Date
}
```

`lastSelectedModel` 仍是 App 级新会话默认值；per-conversation 模型和 recent models 迁入 local state。Gateway 模型目录继续由 `ModelSettingsStore` 或后续 `ModelCatalogStore` 负责。

### 8.3 持久化策略

- 使用 Application Support 下的 SQLite 或等价事务存储，不用 UserDefaults 保存长文本和附件草稿。
- 输入变化采用 300–500ms debounce；进入后台和 App 退出路径尽力 `flush`。
- Composer 展示前先恢复草稿，避免先显示空输入框再跳变。
- 首个 session 创建成功后，将 `draft:<UUID>` 原子迁移为 `session:<sessionID>`。
- 创建或发送失败保留草稿；确认发送成功后才清空对应文本和已提交附件引用。
- 归档保留本地状态，永久删除才清理；孤立 draft 按明确保留周期清理。
- v1 为设备本地状态。跨设备同步、冲突合并和端到端加密另立协议。
- iOS 文件采用合适的 Data Protection；草稿可能包含敏感信息，不进入日志和 notification payload。

### 8.4 已读语义

- Runtime 的 `last_sequence/latest_terminal` 是服务端事实。
- `lastReadSequence` 是客户端已读游标，只在对应 conversation 可见并已展示到最新内容时推进。
- terminal 与 approval notification 游标继续独立，避免“收到通知”被误当成“用户已读”。
- 本地状态丢失时重新建立保守 baseline，不能把所有历史 terminal 一次性标红。

本地状态 Store 是后续里程碑，不阻塞 Managed Worktree v1；但 Worktree 选择必须先保存在 `SessionDraft`，保证 provisioning 失败后输入和选择不丢失。

## 9. 实施顺序

### W0：契约和能力

- 定稿 managed worktree request/response、路径、命名、base ref 和清理语义。
- Runtime capability 保持 `managed_worktree_v1=false`。

### W1：Runtime provisioning

- 实现 opt-in 创建、幂等、持久化和重启恢复。
- 实现项目内 worktree 根的工具排除和路径安全。
- 实现非破坏性 remove 和 dirty 检查。

完成于 Code-Agent Runtime `35e2620`、`dfa2c1d`、`4f8c89c`、`b925335`、`0682721`、`3d141ff`。

### W2：AgentKit / CodeAgent

- 新建会话增加独立 Worktree 开关。
- 按 `baseWorkspaceID` 分组，row 展示 checkout/branch 状态。
- provisioning、失败、missing、cleanup 状态可见。
- capability 缺失时安全隐藏或降级。

AgentKit 已完成创建协议、能力门控、项目分组、Worktree/branch/异常状态展示与 macOS/iOS 宿主构建验证。显式 remove 已接入 conversation 删除入口，不改变“删除会话不得隐式删除 worktree”的约束。

### W3：生产验收

- 同仓库两个 worktree 并行、共享目录串行。
- 创建幂等、Runtime 重启、App 重启和 WebSocket 重连。
- 源 workspace 脏状态提示、名称冲突、symlink 和路径逃逸。
- dirty worktree 清理保护和 crash orphan reconciliation。
- 常规测试、集成测试和 race 测试。

AgentKit 的真实 Runtime 黑盒矩阵通过临时 Git 仓库、独立 SQLite 和真实模型 turn 验证以上路径。Runtime `6e4875a` 起，事件 `reason` 与 activity `queue_reason` 已区分 `workspace_lease`、`global_capacity`、`session_serialization`；AgentKit 同时兼容旧 `position` 和正式 `queue_position` 字段，并在详情与侧栏展示对应原因。

删除流程已经采用显式两阶段语义：用户选择保留 checkout，或先安全 remove（dirty 时再次确认 force）再删除 conversation；AgentKit 会阻止删除已知活动中的会话。但该客户端检查只负责 UX，无法消除状态快照与 `DELETE` 之间的竞态；Runtime 必须在删除事务内原子拒绝 queued/running/waiting/paused session，并返回稳定的 conflict code，才能把该入口视为生产安全。

Runtime `6e4875a` 已为永久删除增加原子 `conversation_in_use` 保护，AgentKit 解码该结构化冲突并保留会话。当前 Runtime 仍明确未开放 conversation archive/list-archived/restore 契约，AgentKit 不在本地伪造服务端归档事实，也不显示无效归档入口。归档 UI 待 Runtime 提供持久化 endpoint/capability 后复用同一 Worktree disposition 流程。

### 后续：客户端持久状态与远程通知

- `ConversationLocalStateStore`：模型、草稿、附件和已读状态。
- APNs：iOS 被完全挂起时的审批和 terminal 通知。

## 10. 验收标准

1. 未勾选 Worktree 时，不执行任何 `git worktree add`。
2. 勾选后 worktree 位于配置根目录，默认使用 `.codeagent/worktrees/`。
3. Worktree session 仍归属原 Workspace，不生成新的顶层项目。
4. 目录名和 branch 不作为 workspace/session 主键。
5. 主 workspace 搜索和工具无法误读其他 managed worktree。
6. 同仓库不同 worktree 可按并发上限运行；相同真实路径始终互斥。
7. Runtime/App 重启后 session 恢复到同一 checkout。
8. 删除 conversation 不会静默丢弃 worktree 修改或分支。
9. provisioning 失败时用户输入草稿和选择仍然存在。
10. `managed_worktree_v1` 只在全部 Runtime 验收通过后开启。

## 11. 决策记录

1. Worktree 是 opt-in，不是所有新会话的默认副作用。
2. Workspace 是项目分组；worktree 是 checkout；branch 是可变 Git 属性。
3. 默认目录采用 `<project>/.codeagent/worktrees/<slug>-<short-id>`。
4. Managed worktree v1 一会话一 worktree，后续 turn 复用。
5. 完成 turn 不自动删除；清理由用户在归档/删除流程中决定。
6. 项目内路径只有在 Runtime 工具排除和真实路径安全完成后才能启用。
7. 会话草稿、模型偏好和已读游标属于 `ConversationLocalStateStore`，不进入 Runtime activity。
