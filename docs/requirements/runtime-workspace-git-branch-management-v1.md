# Runtime Workspace Git Branch Management v1

## 1. 背景

AgentKit 的草稿输入区需要展示当前工作区的 Git 分支，并支持用户：

1. 查看当前工作区的本地分支；
2. 基于指定起点创建本地分支；
3. 将当前工作区切换到已有本地分支。

当前 AgentKit 只会读取 `<workspace>/.git/HEAD`，Runtime 没有分支管理 API。请在 Code-Agent Runtime 中实现本需求对应的 HTTP API 和 capability。AgentKit 客户端 UI 不属于本次实现范围。

## 2. 目标与非目标

### 目标

- Runtime 作为工作区 Git 操作的唯一执行方。
- 支持主 checkout 的本地分支查询、创建和 checkout/switch。
- 所有操作都必须绑定到调用方已授权的 workspace path。
- 提供结构化结果和结构化错误，供 AgentKit UI 直接展示。
- 兼容非 Git 目录、detached HEAD、普通 worktree 和 managed worktree 场景。

### 非目标

- 不实现远端分支 fetch、push、pull 或 merge。
- 不删除、重命名分支。
- 不修改 managed worktree 的自动分支命名和 provisioning 流程。
- 不通过 Agent 对话中的 terminal/tool 间接执行 Git 操作。
- 不在 Runtime 中创建新的 Conversation 或 Worktree。

## 3. Capability

在 `GET /v1/runtime/capabilities` 中增加：

```json
{
  "workspace_git_branch_v1": true
}
```

没有该 capability 时，客户端必须隐藏分支管理入口。已有 Runtime 不支持该能力时，不能影响现有 conversation、shared workspace 或 managed worktree 功能。

建议 capability 含义为：Runtime 能够对已授权 workspace 安全执行本地 branch list/create/checkout，并返回确定性的结构化结果。

## 4. Workspace 标识与权限

所有 API 必须接收 `workspace_path`，并遵循现有 workspace 授权、路径规范化和 owner/device 隔离规则。

Runtime 必须：

- 规范化路径并解析真实路径；
- 拒绝不存在的路径；
- 拒绝文件路径和非目录路径；
- 拒绝未授权目录；
- 识别当前目录是否属于 managed worktree；
- 返回规范化后的 workspace path 和当前 checkout 状态。

API 不接受任意 Git directory、`.git` 路径或外部 worktree 路径作为替代参数。

## 5. 数据模型

### 5.1 Checkout 状态

```json
{
  "workspace_path": "/repo/AgentKit",
  "is_git_repository": true,
  "head": {
    "kind": "branch",
    "name": "main",
    "commit": "abc1234"
  },
  "is_dirty": true,
  "modified_files": 3,
  "untracked_files": 1,
  "active_worktree": false
}
```

`head.kind` 至少支持：

- `branch`：`name` 为本地分支名；
- `detached`：`name` 为 null，`commit` 必须存在；
- `unborn`：仓库还没有 commit；
- `none`：不是 Git 仓库。

### 5.2 分支

```json
{
  "name": "feature/branch-ui",
  "commit": "abc1234",
  "is_current": false,
  "is_checked_out_elsewhere": false,
  "worktree_path": null
}
```

分支列表只返回本地 branch。远端 tracking 信息可以作为可选字段，但不能把 `origin/*` 当成本地可 checkout 分支返回。

## 6. API

### 6.1 查询分支

```http
POST /v1/workspaces/git/branches/list
```

请求：

```json
{
  "workspace_path": "/repo/AgentKit"
}
```

响应：

```json
{
  "workspace_path": "/repo/AgentKit",
  "checkout": { "...": "..." },
  "branches": [
    {
      "name": "main",
      "commit": "abc1234",
      "is_current": true,
      "is_checked_out_elsewhere": false,
      "worktree_path": null
    }
  ]
}
```

建议按 branch name 排序；当前分支可以排在第一位，但客户端不能依赖排序表达选中状态。

### 6.2 创建分支

```http
POST /v1/workspaces/git/branches/create
```

请求：

```json
{
  "workspace_path": "/repo/AgentKit",
  "name": "feature/branch-ui",
  "start_point": null,
  "checkout": true
}
```

规则：

- `name` 必须是合法 Git ref；
- 禁止以 `/` 结尾；
- 禁止空名称、空白名称和危险 ref；
- `start_point == null` 时从当前 HEAD 创建；
- `start_point` 可为本地 branch 或 commit；
- `checkout=true` 时创建后切换到新分支；
- 创建和 checkout 必须作为一次受保护操作执行；
- 已存在分支不得覆盖，返回 conflict。

成功响应返回创建后的完整 branch list 和 checkout 状态，避免客户端自行拼装状态。

### 6.3 切换分支

```http
POST /v1/workspaces/git/branches/checkout
```

请求：

```json
{
  "workspace_path": "/repo/AgentKit",
  "name": "feature/branch-ui",
  "allow_dirty": false
}
```

默认必须拒绝 dirty checkout。`allow_dirty=true` 只允许在 Runtime 明确支持安全 checkout 的情况下启用；v1 可以直接不支持该参数并始终拒绝 dirty workspace。

成功响应返回切换后的完整 branch list 和 checkout 状态。

## 7. 并发与安全规则

### 7.1 Shared workspace 会话

主 checkout 可能被已有 shared-workspace conversation 使用。Runtime 必须查询当前 workspace lease/session 状态：

- 如果存在运行中的 turn，禁止 branch checkout/create-and-checkout；
- 如果只有 idle session，建议仍返回 warning 或 conflict，由客户端确认后重试；
- 不得让 branch checkout 绕过现有 workspace lease；
- Git 操作必须与 workspace lease 互斥，避免查询后到 checkout 前状态发生变化。

建议错误码：

```text
workspace_git_busy
workspace_git_session_conflict
```

### 7.2 Managed worktree

- 对 managed worktree 执行 branch checkout 默认拒绝；
- 不得修改 managed worktree provisioning 记录；
- 不得复用 `managed_worktree_v1` 的 branch 自动生成逻辑；
- 如果请求路径是 managed worktree，应返回 `workspace_git_managed_worktree`，并携带 base workspace 信息；
- 主 workspace 的 branch 操作不能删除或改变其他 managed worktree 的 branch。

### 7.3 Dirty workspace

工作区存在 modified、untracked、conflict 或 merge/rebase 状态时：

- branch checkout 默认拒绝；
- create with `checkout=true` 默认拒绝；
- create with `checkout=false` 可以在不改变 HEAD 的前提下允许；
- 返回文件数量和可读 summary；
- Runtime 不得自动 stash、reset、clean、commit 或丢弃文件。

建议错误码：

```text
workspace_git_dirty
workspace_git_conflict_state
```

## 8. 错误协议

所有业务错误使用现有 Runtime envelope，并在 `data` 中返回：

```json
{
  "code": "workspace_git_dirty",
  "message": "workspace has uncommitted changes",
  "workspace_path": "/repo/AgentKit",
  "checkout": { "...": "..." },
  "conflicts": []
}
```

至少覆盖：

```text
workspace_not_found
workspace_not_authorized
workspace_not_git_repository
workspace_git_unsupported
workspace_git_invalid_ref
workspace_git_branch_exists
workspace_git_branch_not_found
workspace_git_dirty
workspace_git_conflict_state
workspace_git_busy
workspace_git_session_conflict
workspace_git_managed_worktree
workspace_git_checkout_failed
workspace_git_create_failed
```

## 9. 幂等性与状态一致性

创建分支 API 应支持可选 `client_request_id`：

- 相同 workspace、相同 branch name、相同 request ID 的重试不能创建第二个 branch；
- 已经成功但响应丢失时，重试应返回原结果；
- 不允许通过“先 list 再 create”实现并发保护，必须由 Runtime/Git 操作本身保证冲突安全；
- checkout 成功后，响应中的 `head` 必须反映实际 HEAD，而不是请求参数推测值。

## 10. 测试要求

必须增加 Runtime 单元测试和 HTTP/API 测试，至少覆盖：

1. 非 Git 目录查询；
2. branch list 返回当前 branch；
3. detached HEAD；
4. unborn repository；
5. 创建 branch，不 checkout；
6. 创建 branch 并 checkout；
7. branch 已存在；
8. 非法 Git ref；
9. checkout 到已有 branch；
10. branch 不存在；
11. dirty workspace 拒绝 checkout；
12. merge/rebase 冲突状态拒绝 checkout；
13. active shared-workspace turn 拒绝 branch 操作；
14. managed worktree 拒绝 branch checkout；
15. 未授权 workspace；
16. 相同 `client_request_id` 重试幂等；
17. 并发创建同名 branch 只有一个成功；
18. Git 命令失败时不返回伪造成功状态。

## 11. 交付内容

Code-Agent 完成后请提供：

- Runtime API 路由和请求/响应模型；
- capability 变更；
- 结构化错误码清单；
- workspace 授权和 lease 处理说明；
- 测试结果；
- 至少一份 API 示例或协议文档；
- AgentKit 接入所需的客户端模型字段和 endpoint 契约。

AgentKit 侧后续将基于本协议实现：

- `RuntimeClient` facade；
- `WorkspaceStore` 的 branch 状态；
- `WorkspaceChipBar` 分支菜单；
- 创建并检出分支 sheet；
- dirty/session conflict 的确认 UI。
