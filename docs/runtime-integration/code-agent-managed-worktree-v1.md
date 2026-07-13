# Code-Agent Managed Worktree v1 要求

> 状态：Proposed
>
> 目标仓库：Code-Agent Runtime
>
> 客户端设计：[AgentKit Workspace、Worktree 与会话本地状态设计 v1](../design/agentkit-workspace-worktree-local-state-v1.md)
>
> 上位 Runtime 设计：[Code-Agent Runtime 多会话执行要求 v1](code-agent-multi-session-runtime-v1.md)

## 1. 目标

Runtime 已支持：

- 不同 workspace/worktree 路径按 `max_concurrent_turns` 并行；
- 相同规范化真实路径 whole-turn 互斥；
- `isolated_worktree` 执行策略；
- `managed_worktree_v1=false` 的安全能力降级。

当前 `isolated_worktree` 仍要求客户端传入已经存在的独立路径。本里程碑增加 Runtime 托管的 Git worktree provisioning、恢复和清理，但不得改变默认创建语义。

核心要求：用户未显式选择 managed worktree 时，Runtime 不得执行 `git worktree add`。

## 2. 不变量

1. `shared_workspace` 保持默认行为，完全不触发 Git worktree 操作。
2. Managed worktree 必须由显式 `execution_policy=isolated_worktree` 和 `worktree.managed=true` 同时请求。
3. Worktree 属于来源 `base_workspace_id`，但具有独立 `workspace_id` 和真实路径。
4. branch、目录名和 session title 都不是稳定身份。
5. 创建请求幂等；重试和 Runtime 重启不能产生重复 session、目录或分支。
6. Runtime 返回 ready 之前不得启动 turn。
7. 相同规范化 checkout 路径始终互斥；不同 managed worktree 才可并行。
8. terminal、socket disconnect 和 App 切换不删除 worktree。
9. 普通 cleanup 不丢弃 dirty/untracked/committed changes，不自动删除 branch。
10. `managed_worktree_v1` 只在创建、恢复、隔离、清理和测试全部完成后开启。

## 3. 创建协议

沿用 `POST /v1/conversations`，增加稳定的创建幂等键和 managed worktree 描述：

```json
{
  "client_request_id": "create_01J2...",
  "workspace_path": "/repo/AgentKit",
  "workspace_id": "workspace_agentkit_main",
  "base_workspace_id": "workspace_agentkit",
  "execution_policy": "isolated_worktree",
  "worktree": {
    "managed": true,
    "suggested_name": "multi-session-cache",
    "base_ref": "head"
  }
}
```

### 3.1 字段语义

| 字段 | 要求 |
| --- | --- |
| `client_request_id` | session 创建幂等键；作用域至少包含 owner/device + base workspace |
| `workspace_path` | 用户授权的来源主 checkout，不是目标 worktree 路径 |
| `workspace_id` | 来源 checkout identity |
| `base_workspace_id` | UI 项目和 Git common repository identity |
| `execution_policy` | managed worktree 请求时必须是 `isolated_worktree` |
| `worktree.managed` | 必须显式为 `true` 才创建 |
| `suggested_name` | 非权威可读 slug；Runtime 合法化并追加短 ID |
| `base_ref` | 首版仅接受 `head` 或 `fresh` |

客户端不得为 managed 模式指定任意目标绝对路径。目标根由 Runtime 设置决定，默认：

```text
<base-project-root>/.codeagent/worktrees/
```

### 3.2 成功响应

沿用现有 response envelope，conversation 数据增加：

```json
{
  "id": "session_123",
  "base_workspace_id": "workspace_agentkit",
  "workspace_id": "checkout_a31f",
  "workspace_path": "/repo/AgentKit/.codeagent/worktrees/multi-session-cache-a31f",
  "execution_policy": "isolated_worktree",
  "worktree": {
    "managed": true,
    "name": "multi-session-cache-a31f",
    "branch": "codeagent/multi-session-cache-a31f",
    "base_ref": "head",
    "state": "ready"
  },
  "warnings": [
    {
      "code": "source_workspace_dirty",
      "message": "Uncommitted and untracked files were not copied into the worktree."
    }
  ]
}
```

`workspace_path` 从创建成功开始就是 turn 的唯一执行根。后续 list/detail/activity 不得把它改回 base workspace path。

### 3.3 Base ref

- `head`：从来源 workspace 当前 `HEAD` commit 创建新 branch。
- `fresh`：从 `origin/HEAD` 对应默认分支创建；fetch 行为、超时和离线失败必须确定化。
- 两者均不复制来源 workspace 的未提交修改和 untracked 文件。
- 来源 workspace dirty 时返回 warning，但不自动 stash、commit 或复制文件。
- ignored 文件复制机制不进入 v1；未来若实现必须使用显式 allowlist，不能默认复制 `.env`。

## 4. 命名与路径

默认目录：

```text
<project>/.codeagent/worktrees/<slug>-<short-id>
```

默认 branch：

```text
codeagent/<slug>-<short-id>
```

要求：

- slug 进行长度限制、Unicode/非法 Git ref 字符处理和空值回退。
- short ID 来自稳定的创建 reservation/session identity，不使用“检查存在后递增”作为唯一并发保护。
- 并发同名请求、重复 request ID 和 Runtime 重启后重试均返回原结果。
- 如果目标 branch/path 已被不相关对象占用，返回结构化 conflict，不覆盖、不强删。
- 不允许在一个 managed worktree 中再次创建 nested managed worktree；需解析回 base project。
- 自定义 worktree 根属于 Runtime 全局或 workspace 设置，不由未授权客户端任意指定。

## 5. Provisioning 事务与恢复

建议持久化状态：

```text
reserved → provisioning → ready
                    └──→ failed
ready → removing → removed
            └──────→ remove_failed
```

创建顺序至少保证：

1. 以 `client_request_id` 预留稳定 session/worktree identity。
2. 校验 owner、workspace 授权、Git repository 和 capability。
3. 计算并持久化目标 path、branch、base commit 和 `provisioning` 状态。
4. 执行 `git worktree add`。
5. 校验 worktree realpath、Git common dir 和 branch 符合 reservation。
6. 事务更新 session 的 checkout metadata 与 `ready` 状态。
7. 返回 conversation；之后才允许首个 turn。

Runtime 在任意步骤崩溃后必须协调：

- DB 为 provisioning、Git worktree 已存在：验证归属后完成或标记 recoverable failure。
- DB 为 provisioning、目录不存在：允许同 request ID 继续创建。
- DB 为 ready、目录丢失：报告 `missing/needs_rebind`，不静默创建空替代品。
- Git worktree 存在但无 Runtime reservation：标记 orphan 并提供诊断，不在启动时直接删除。
- session 持久化失败时，不能遗留一个客户端未知但仍被当作 ready 的 checkout。

需要在 Runtime store 中持久化 managed metadata；不能只通过扫描目录名称推断所有权。

## 6. 项目内 Worktree 隔离

默认路径位于项目内部，因此必须把隔离作为 capability 前置条件。

### 6.1 Git exclude

- 将 `/.codeagent/worktrees/` 加入 Git common dir 的本地 exclude。
- 操作应幂等并保留用户已有内容。
- 不自动修改仓库需要提交的 `.gitignore`。
- 无法安全写入 exclude 时，provisioning 失败或使用已配置的外部根；不能继续并宣称隔离完成。

### 6.2 Runtime 工具边界

以下路径发现必须统一排除 managed root：

- `list_files`；
- `grep`/search；
- project graph/index；
- context/file discovery；
- file watcher；
- workspace-wide diff/status aggregation；
- MCP 资产路径枚举。

排除应位于共享 workspace path policy 层，不能只在某一个工具里增加字符串判断。

### 6.3 路径安全

- 使用 `EvalSymlinks`/realpath 后的规范路径做 containment 和 scheduler lease。
- 处理 macOS 大小写不敏感路径等价。
- 拒绝目标逃出配置 worktree root。
- 验证 worktree 的 Git common dir 与 base workspace 相同。
- base workspace Agent 不得通过 `../`、symlink 或直接绝对路径访问其他 managed worktree，除非独立授权。

## 7. Scheduler 与 activity

- managed worktree ready 后继续使用现有 `isolated_worktree` scheduler mode。
- lease key 是目标 checkout 规范化真实路径，不是 `base_workspace_id` 或 branch。
- 同一仓库的不同 worktree 路径可以并行。
- 主 checkout 与独立 worktree 可以并行，但各自 checkout 内 whole-turn 互斥。
- 两个 session 错误地引用同一 realpath 时必须串行，即使都声明 isolated。
- provisioning 不发布 `turn_started`。若 AgentKit 已创建 session 但 worktree 尚未 ready，activity 可报告 `provisioning`，且不得占用 turn slot。
- queued reason 应区分 `global_capacity`、`workspace_lease`；worktree provisioning 不是普通 turn queue。

## 8. 查询与缺失状态

Conversation list/detail 至少返回：

```json
{
  "base_workspace_id": "workspace_agentkit",
  "workspace_id": "checkout_a31f",
  "workspace_path": "/repo/AgentKit/.codeagent/worktrees/multi-session-cache-a31f",
  "execution_policy": "isolated_worktree",
  "worktree": {
    "managed": true,
    "name": "multi-session-cache-a31f",
    "branch": "codeagent/multi-session-cache-a31f",
    "base_ref": "head",
    "state": "ready"
  }
}
```

状态至少区分：

- `provisioning`；
- `ready`；
- `missing`；
- `removing`；
- `remove_failed`；
- `retained`；
- `removed`。

Runtime 重启时不得把 `missing` session 的 `workspace_path` 当成可执行目录自动创建。

## 9. 清理协议

首版建议增加显式端点：

```text
POST /v1/conversations/{session_id}/worktree/remove
```

请求：

```json
{
  "request_id": "remove_01J2...",
  "force": false
}
```

语义：

1. session 有 active/queued turn 时返回 conflict。
2. `force=false` 时检测未提交修改、untracked 文件和相对 base 的新提交。
3. 有数据风险时返回 `409 worktree_dirty` 和摘要，不执行 remove。
4. `force=true` 只接受已授权宿主的显式破坏性确认；Runtime 不自行升级为 force。
5. remove 使用 `git worktree remove` 语义并在成功后持久化 `removed`。
6. v1 不删除 branch。branch cleanup 需要独立显式 API。
7. 请求幂等；已 removed 的相同请求返回原结果。
8. 删除 conversation 的 API 不得隐式 remove worktree。宿主必须先选择 keep/remove，或显式传 disposition。

## 10. 错误结构

至少提供稳定错误 code：

```text
managed_worktree_not_supported
managed_worktree_not_requested
workspace_not_git_repository
workspace_not_authorized
source_workspace_dirty        # warning，通常不阻断
base_ref_unavailable
worktree_name_conflict
worktree_path_conflict
worktree_branch_conflict
worktree_nested_not_allowed
worktree_escape_detected
worktree_missing
worktree_dirty
worktree_busy
worktree_provision_failed
worktree_remove_failed
```

错误必须保留 `client_request_id/session_id` 等关联字段，日志包含 session/worktree identity，但远程响应不得泄露未授权绝对路径。

## 11. Capability

完成前：

```json
"managed_worktree_v1": false
```

全部验收通过后：

```json
{
  "multi_session_execution_v1": true,
  "workspace_execution_policy_v1": true,
  "managed_worktree_v1": true
}
```

`managed_worktree_v1=true` 表示同时保证：

- opt-in 创建；
- 幂等与重启恢复；
- 项目内路径的工具排除；
- realpath 安全；
- list/detail metadata；
- dirty-safe 显式 remove；
- scheduler 正确使用目标 checkout；
- 常规、集成和 race 测试通过。

只实现 `git worktree add` 不能开放 capability。

## 12. 测试矩阵

### 12.1 创建

- shared workspace 创建不调用 Git worktree。
- managed 请求生成约定目录和唯一 branch。
- 相同 `client_request_id` 并发/重试只产生一个 session、目录和 branch。
- 同名不同 request ID 生成不同短 ID。
- 非 Git、无权限、非法 base ref、branch/path 冲突返回稳定错误。
- source dirty 返回 warning，且修改不会出现在 worktree。

### 12.2 隔离与调度

- 同仓库两个 managed worktree 可按 `max_concurrent_turns` 并行。
- main checkout 与 managed worktree 可并行。
- 同一 realpath 即使声明 isolated 仍互斥。
- base workspace 的 list/search/index 不返回 `.codeagent/worktrees` 内容。
- symlink、`..`、大小写变体不能逃逸或绕过 lease。
- 禁止从 managed worktree 创建 nested managed worktree。

### 12.3 恢复

- provisioning 各步骤崩溃后重启可协调。
- Runtime 重启后 ready session 仍绑定同一路径和 checkout ID。
- worktree 被手动删除后报告 missing，不创建替代目录。
- orphan worktree 被发现但不自动删除。

### 12.4 清理

- turn 活动时拒绝 remove。
- clean worktree 可移除，branch 保留。
- dirty、untracked、新提交在 `force=false` 时拒绝。
- remove 重试幂等。
- conversation 删除不会隐式删除 worktree。

### 12.5 并发与 race

- 双会话真实 HTTP + WebSocket 集成测试使用同仓库不同 managed worktree。
- provisioning/remove 与 Runtime restart、duplicate request 并发测试。
- `go test -race` 覆盖 registry、store、scheduler、provisioner 和 cleanup。

## 13. 推荐实施顺序

### M0：Fixture 与存储

- 冻结 request/response/error fixture。
- 增加 managed metadata、状态和创建 request 幂等存储。

### M1：Provisioner

- Git repository/base ref 解析。
- 命名、创建、验证和结构化错误。
- shared workspace 零副作用测试。

### M2：路径隔离

- local exclude。
- Runtime 工具统一 managed-root 排除。
- realpath containment 和 nested 防护。

### M3：恢复与清理

- startup reconciliation。
- missing/orphan 状态。
- dirty-safe 显式 remove。

### M4：生产 wiring 与能力

- daemon/embedded 接入同一 provisioner。
- list/detail/activity metadata。
- HTTP + WebSocket 双 worktree、重启和 race 验收。
- 全部通过后设置 `managed_worktree_v1=true`。
