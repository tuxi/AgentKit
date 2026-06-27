# CodeAgent

macOS / iOS 原生客户端，Agent Execution Runtime 的图形界面。

## 架构

六层事件溯源运行时：

```
AgentWire (SSE)           ← agent-wire v1 协议，不修改
        │
        ▼
RuntimeEngine (Actor)     ← 唯一状态持有者，单点 ingest
        │
        ▼
ExecutionReducer          ← AgentEvent → Graph 变更（纯逻辑）
        │
        ▼
ExecutionGraph            ← Runtime Truth（节点 + 有向边）
        │
        ├──────────────────┐
        ▼                  ▼
TimelineProjection    InspectorProjection   (未来: Statistics, Cost…)
        │                  │
        └────────┬─────────┘
                 ▼
ExecutionPresentation     ← UI 模型：主题、紧凑、无障碍
                 │
                 ▼
SwiftUI                   ← 消费 Presentation，不接触原始 Graph
```

### 关键约束

1. `ExecutionGraph` 是 Runtime 层唯一的可变状态。`RuntimeSnapshot` 不可变。
2. `ConversationViewModel` 只订阅，不 reduce。只有 `await engine.ingest(event)`。
3. `ExecutionNode` 不存储在 `ExecutionGraph` 中。它是 Projection 的输出。
4. `ReducerInternal`（流式缓冲区）不在 `RuntimeSnapshot` 中。它对 `ExecutionReducer` 私有。
5. `MergePolicy` 注入到 `TimelineProjection`，不硬编码在 Reducer 里。
6. SwiftUI 消费 `ExecutionPresentation`，不消费原始 `ExecutionNode`。

## GUI 设计原则

目标：**Claude Code GUI 的感觉** — Thinking 是叙事主线，工具是叙事中的行动插入。

### Thinking 卡

- 永远展开，**不折叠**。它是 agent 在对你说话。
- 紫色左边框 + 斜体文字，视觉上区别于工具，但有连续的叙事感。
- Streaming 时边框更亮，带 pulse spinner。
- 思考文字先于工具调用出现 — 用户在工具执行前就知道 agent 为什么这样做。

### Tool 卡

- 彩色状态图标（🔵 运行中 / ✅ 完成 / ❌ 失败 / ⚡ 自动审批）。
- 运行时自动展开，完成后默认折叠。
- 展开时显示参数、输出、Artifact→Inspector 链接。
- 工具卡和前面的 Thinking 卡视觉上紧密相连（间距 6px）。

### Observation / Reflection 卡

- **永远展开**。这是 agent 的 "我看到什么" 和 "我怎么想的"。
- Observation → 蓝色左边框，Reflection → 紫色左边框。
- 它们是思考→行动→观察→反思循环中的关键环节。

### 视觉节奏

```
┃ 🤔 THINKING
┃ I need to check the project structure first…
└─────────────────────────────────────────────
      ↓ 6px
┌─────────────────────────────────────────────┐
│ 📁 list_files                       running │
└─────────────────────────────────────────────┘
      ↓
┃ 👁 OBSERVED
┃ Found 12 files in src/
└─────────────────────────────────────────────
      ↓
┃ 🤔 THINKING
┃ Now let me read the main entry point…
└─────────────────────────────────────────────
      ↓
┌─────────────────────────────────────────────┐
│ 📄 read_file      main.swift      ✓        │
└─────────────────────────────────────────────┘
      ↓
┌─────────────────────────────────────────────┐
│ Your project uses async/await pattern…      │  ← 最终答案
└─────────────────────────────────────────────┘
```

### Agent 感的核心

不是漂亮的 UI，而是 **思考 → 行动 → 观察 → 反思** 的循环被完整呈现：

- 用户在工具执行前就知道 **为什么**。
- 用户在工具执行后看到 agent **观察到了什么**。
- 用户看到 agent 对观察结果的 **反思**。
- 所有这一切按时间顺序自然流淌，不折叠、不隐藏。

## 包结构

```
Packages/
├── AgentKit/   — UI + Runtime Engine
│   └── Sources/AgentKit/
│       ├── Core/
│       │   ├── AgentEvent.swift        — v1 事件协议（不改）
│       │   ├── AgentWireSocket.swift   — WebSocket 封装
│       │   ├── RuntimeClient.swift     — HTTP + WS 协议
│       │   └── RuntimeEngine/          — v2 事件溯源引擎
│       │       ├── ExecutionGraph.swift
│       │       ├── ExecutionReducer.swift
│       │       ├── ExecutionNode.swift
│       │       ├── TimelineProjection.swift
│       │       ├── MergePolicy.swift
│       │       ├── ExecutionPresentation.swift
│       │       └── RuntimeEngine.swift
│       └── Features/
│           └── Conversation/
│               ├── Components/         — ThinkingCard, ToolCard, TodoCard, MessageBubble
│               ├── Views/              — ChronologicalTimelineView, ExecutionNodeViews
│               ├── ViewModels/         — ConversationViewModel (薄订阅者)
│               └── Models/             — ConversationState (过渡期保留)
```

## 开发

```bash
# 启动开发服务
codeagent serve

# 构建 macOS 客户端
xcodebuild -scheme CodeAgent -sdk macosx -destination 'platform=macOS' build
```

## 实现路线图

对标 Claude Code / Cursor，差距分四层。每层标注客户端/服务端责任边界。

### L1：渲染质量

> 影响：视觉质感 + 阅读体验。纯客户端改动。

| 差距 | 目标 | 状态 |
|------|------|------|
| **Markdown 渲染** | 最终答案和思考文本渲染 Markdown：标题、粗斜体、行内代码、列表、引用、链接 | 🔲 待实现 |
| **代码块高亮** | 深色背景 + Swift/SwiftUI 语法高亮 + 语言标签 + 一键复制按钮 | 🔲 待实现 |
| **流式体感** | 逐 token 或小 chunk 渲染（当前 50ms 合并 → 降到 16ms），光标平滑闪烁动画 | 🔲 待实现 |
| **Diff 内联预览** | 绿色/红色 diff 直接在对话卡片中展示，不需打开右侧 Inspector | 🔲 待实现 |

**实现方案**：
- Markdown：macOS 15 `AttributedString` 原生 Markdown 解析 + 手动 AttributedString 构造（代码块部分）。零外部依赖。
- 语法高亮：内置 `SyntaxHighlighter`，支持 Swift / Python / Bash / JSON / YAML / JS / TypeScript / Go 语言的 tokenization + 着色。
- 流式：`MergePolicy` 新增 `StreamingMergePolicy`（16ms debounce），光标 `Text("|").opacity(blinkAnimation)`。
- Diff：`ToolCard` 展开时内联渲染 diff（复用已有的 `DiffPayload` 结构）。

### L2：Tool 过程可视化

> 影响：用户信赖度。需要服务端新增事件类型。

| 差距 | 目标 | 状态 |
|------|------|------|
| **长命令实时输出** | `bash`/`shell` 工具执行时，stdout/stderr 逐行流式推送到 UI | 🔲 需服务端 `tool_stdout` / `tool_stderr` 事件 |
| **Tool 耗时标注** | 每个工具卡片底部显示 "⏱ 1.2s" | 🔲 客户端就绪，需服务端 `tool_finished.elapsed_ms` |
| **文件变更摘要** | 编辑/创建文件后显示 "+23 -5 lines in main.swift" 摘要行 | 🔲 客户端就绪（`DiffPayload` 已有 addedLines/removedLines） |

**当前服务端协议限制**：v1 协议只有一个 `tool_finished` 事件包含完整 output。长命令（如 `npm install`）执行期间 UI 无反馈。详见 [agent-wire v1 协议](docs/client_integration_v1.md)。

**需要服务端新增**（v2 wire 协议提案）：
```
事件: tool_stdout  { call_id, chunk }   — 工具执行中逐行输出
事件: tool_stderr  { call_id, chunk }   — 工具执行中 stderr 输出
字段: tool_finished.elapsed_ms           — 工具执行耗时
```

### L3：上下文感知

> 影响：用户对 agent 状态的理解。客户端 + 服务端配合。

| 差距 | 目标 | 状态 |
|------|------|------|
| **Todo 地位强化** | Todo 列表置顶或侧边固定，带进度条 (2/5)，不埋在 timeline 里 | 🔲 待实现 |
| **文件上下文指示** | 当前 turn 读取/编辑了哪些文件，显示在工作区芯片旁 | 🔲 待实现 |
| **Token 用量** | Turn 底部或侧边显示 "📊 12K / 200K tokens" | 🔲 服务端 `model_finished` 已有，客户端未展示 |
| **工作区状态** | 分支名 + 未暂存文件数，显示在输入框上方 | 🔲 待实现 |

**实现方案**：
- Todo：`TodoPanel` 固定在 timeline 右侧（macOS `.inspector` 的第二 tab，或 timeline 顶部的 sticky bar）。
- 文件上下文：从当前 turn 的 `ArtifactGraph` 提取所有 `path`，去重后渲染为 `WorkspaceChipBar` 中的 tag。
- Token 用量：在 turn 结束时从 `model_finished` 事件提取 `promptTokens`，渲染为 mini indicator。

### L4：交互效率

> 影响：高级用户效率。纯客户端改动。

| 差距 | 目标 | 状态 |
|------|------|------|
| **快捷键** | `⌘K` 命令面板（清空对话 / 切换工作区 / 导出 / 设置） | 🔲 待实现 |
| **附件拖拽** | 拖入文件/图片到输入框，自动形成 `@file path` 引用 | 🔲 待实现 |
| **消息操作** | 每条用户消息可编辑重发、每条 assistant 消息可复制/重新生成 | 🔲 待实现 |
| **历史搜索** | `⌘F` 在对话历史中搜索文本 | 🔲 待实现 |

### 实施顺序

```
当前 ──────────────────────────────────────────────→ 目标

L1: Markdown 渲染 ──── 代码高亮 ──── 流式体感 ──── Diff 内联
  │                    (客户端独立完成)
  │
L2: 服务端 stdout ──── 耗时标注 ──── 文件变更摘要
  │  (需服务端配合)
  │
L3: Todo 强化 ──── 文件上下文 ──── Token 指示
  │
  │
L4: 快捷键 ──── 拖拽 ──── 消息操作
```

### 当前优先级

**P0 — 本周**：L1 Markdown 渲染 + 代码高亮 + 流式优化。不依赖服务端，做完后 agent 感显著提升。

**P1 — 服务端就绪后**：L2 长命令实时输出 + 耗时标注。依赖服务端新增 `tool_stdout`/`tool_stderr` 事件。

**P2 — P1 之后**：L3 Todo 强化 + 文件上下文。

**P3 — 后续迭代**：L4 快捷键 + 交互增强。
