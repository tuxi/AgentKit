# iOS ask_user 实现规格

## 背景

Go 服务端已实现 `ask_user` 工具——模型在遇到歧义时，通过 WebSocket 发送 `ask_user_request` 帧，阻塞等待客户端渲染卡片、用户选择、返回 `ask_user_response`。和 `approval_request`/`approval_response` 是同一套 control-plane 模式。

---

## 一、Wire 协议

### 1.1 Server → Client：`ask_user_request`

服务端在模型调用 ask_user 时发送，阻塞等客户端回答（或超时 5 分钟）。和 `approval_request` 同级，不经 `agent_input` 信封，直接走 WebSocket control-plane。

```json
{
  "type": "ask_user_request",
  "id": "ask_a1b2c3",
  "session_id": "sess_root",
  "turn_id": "turn_42",
  "question": {
    "id": "ask_a1b2c3",
    "question": "你希望怎么处理这个文件？",
    "header": "文件处理方式",
    "options": [
      {
        "label": "覆盖原文件",
        "description": "直接覆盖现有文件，保留备份"
      },
      {
        "label": "创建新文件（推荐）",
        "description": "创建一个带时间戳的新文件"
      }
    ],
    "multi_select": false,
    "allow_custom": true
  },
  "deadline_ms": 300000
}
```

字段说明：

| 字段 | 类型 | 说明 |
|---|---|---|
| type | string | 固定 `"ask_user_request"` |
| id | string | 请求唯一标识，client 回复时用 `id` 关联 |
| session_id | string | 会话 ID |
| turn_id | string | 当前 turn ID |
| question.id | string | 问题唯一标识 |
| question.question | string | 问题文本 |
| question.header | string | 简短标题（最多 12 字符） |
| question.options[].label | string | 选项标签（1-5 words），含 `(Recommended)` 后缀的是推荐项 |
| question.options[].description | string | 选项详细说明 |
| question.multi_select | bool | 是否允许多选，默认 false |
| question.allow_custom | bool | 是否允许用户输入自定义文本 |
| deadline_ms | int | 超时毫秒数，默认 300000 (5 分钟) |

### 1.2 Client → Server：`ask_user_response`

```json
{
  "type": "ask_user_response",
  "id": "ask_a1b2c3",
  "answer": {
    "selected": ["创建新文件（推荐）"],
    "notes": "记得加 .bak 后缀"
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| type | string | 固定 `"ask_user_response"` |
| id | string | 与 `ask_user_request.id` 对应 |
| answer.selected | [string] | 用户选中的选项 label 列表 |
| answer.notes | string | 用户自由文本输入（自定义选项或补充说明） |

**取消/跳过**：发送 `selected: []` + `notes: ""`，服务端会告诉模型 "user skipped"。

---

## 二、消息分发

`ask_user_request` 和 `ask_user_response` 是独立的 control-plane 消息，**不经过 `agent_input` 信封**。它们和 `approval_request`/`approval_response`、`plan_approval_request`/`plan_approval_response` 同级，直接在 WebSocket 帧的 `type` 字段上区分。

---

## 三、需要改的 5 个文件

### 3.1 AgentWire 协议层 — Codable 模型

新增 `AskUserRequest` + `AskUserResponse` 的 Codable 结构体：

```swift
struct AskUserRequest: Codable {
    let type: String           // "ask_user_request"
    let id: String
    let sessionId: String?
    let turnId: String?
    let question: AskUserQuestion
    let deadlineMs: Int?
}

struct AskUserQuestion: Codable {
    let id: String
    let question: String
    let header: String
    let options: [AskOption]
    let multiSelect: Bool?
    let allowCustom: Bool?
}

struct AskOption: Codable {
    let label: String
    let description: String
}

struct AskUserAnswer: Codable {
    let selected: [String]
    let notes: String?
}

struct AskUserResponse: Codable {
    let type: String           // "ask_user_response"
    let id: String
    let answer: AskUserAnswer
}
```

### 3.2 RuntimeEngine 层

⚠️ **不要用单槽位**。和审批队列一样，用字典防重复：

```swift
// 参考 _pendingApprovals 的实现模式
private var _pendingAskUsers: [String: AskUserRequest] = [:]  // key = request.id
private var _resolvedAskUserIDs: Set<String> = []              // 去重：已回复的忽略
```

WS 消息处理分支：
- 收到 `ask_user_request` → 检查 `_resolvedAskUserIDs`，已回复的跳过；已存在未回复的恢复卡片；新的加入 `_pendingAskUsers`
- 用户回复 → 发送 `ask_user_response`，移入 `_resolvedAskUserIDs`，从 `_pendingAskUsers` 移除

### 3.3 UI 层 — AskUserCard

卡片 UI 示意：

```
┌──────────────────────────────────────────────┐
│  🔔 渲染方式                        [关闭]   │
│                                              │
│  工具组运行时怎么渲染，才能既稳定又保留可追溯感？ │
│                                              │
│  ● 即时合并＋当前一行状态（推荐）              │
│    — 已完成的折成计数，当前运行的只显示一行状态  │
│                                              │
│  ○ 即时合并+当前工具展开但限高                 │
│    — 已完成的立即折进计数...                  │
│                                              │
│  ○ 不合并，每工具一行稳定行                    │
│    — 完整可追溯、零塌缩...                    │
│                                              │
│  ┌ Other ─────────────────────────────────┐  │
│  │ 用户自定义输入...                       │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  [确认选择]                                   │
└──────────────────────────────────────────────┘
```

交互规则：
- **单选模式** (`multi_select: false`)：tap 选中，再 tap 确认按钮发送
- **多选模式** (`multi_select: true`)：tap 切换选中状态，确认按钮发送
- **关闭/下滑关闭**：取消 → 发送 `selected: []` + `notes: ""`（服务端会告诉模型 "user skipped"）
- **allow_custom: true**：在选项列表末尾显示 "Other" 输入行
- **推荐项**：label 包含 `(Recommended)` 后缀，默认高亮

### 3.4 ConversationDetailView

在会话详情视图中，当 `_pendingAskUsers` 非空时，在消息流上方渲染 AskUserCard。

**渲染优先级**：`AskUserCard > ApprovalCard > PlanApprovalCard`（和 TUI 的键盘优先级一致：ask_user → pending → planPending）。

### 3.5 消息路由/Dispatcher

在 WebSocket 消息分发处添加两个 case：
- `"ask_user_request"` → 交给 RuntimeEngine 处理
- `"ask_user_response"` → 序列化发送（或留在 RuntimeEngine 处理）

---

## 四、陷阱清单

| # | 陷阱 | 说明 |
|---|---|---|
| 1 | 不要用单槽位 | 模型一次 turn 可能调两次 ask_user。用 `[String: AskUserRequest]` 字典 |
| 2 | 去重 | 维护 `_resolvedAskUserIDs: Set<String>`，WS 重连后服务端重发同一 id。收到已回复的 id → 跳过；收到已展示未回复的 id → 恢复卡片不重复创建 |
| 3 | 超时 | `deadline_ms` 后服务端自动降级为 text fallback，客户端无需特殊处理 |
| 4 | 卡片优先级 | AskUser > Approval > PlanApproval，确保用户先看到 ask_user 卡片 |
| 5 | observability 事件 | 服务端会发 `ask_user_posted`、`ask_user_resolved`、`ask_user_timeout` 三种事件。客户端可以当前不做处理，但**不要把它们当错误** |
| 6 | 和审批队列模式一致 | 如果你已经实现了 `approval_request → approval_response` 的队列化处理，ask_user 的代码路径完全对称，照搬即可 |

---

## 五、测试用例

1. 单选 → 选中一项 → 确认 → 验证 response JSON 正确
2. 多选 → 选中多项 → 确认 → 验证 selected 数组正确
3. 自定义输入 (`allow_custom: true`) → 输入文本 → 确认 → 验证 notes 字段
4. 关闭/取消 → 验证发送 `selected: [], notes: ""`
5. 同一 turn 两次 ask_user → 验证队列不丢失、不覆盖
6. WS 断线重连 → 验证卡片从 `_pendingAskUsers` 恢复，不重复创建
7. 5 分钟超时 → 验证服务端自动降级，不阻塞

---

## 六、Review Checklist

实现完成后，检查以下各项：

- [ ] Codable 模型字段名与 JSON key 对齐（用 `CodingKeys` 映射 snake_case）
- [ ] `_pendingAskUsers` 和 `_resolvedAskUserIDs` 在 WS 断开/重连时的清理逻辑正确
- [ ] 卡片在 ConversationDetailView 中的渲染位置（消息流上方，和审批卡同级）
- [ ] 卡片优先级：AskUser > Approval > PlanApproval
- [ ] 单选/多选切换逻辑正确
- [ ] `allow_custom` 时 Other 输入行正常显示
- [ ] 关闭/取消时发送正确的空 response
- [ ] `ask_user_posted`/`ask_user_resolved`/`ask_user_timeout` 事件不被当错误
- [ ] 和审批队列的代码风格一致，不引入新的模式
