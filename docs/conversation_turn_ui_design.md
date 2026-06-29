# Conversation Turn UI — Design Spec (v1)

> 对话详情页的渲染规范。目标：一轮对话（turn）在视觉上是**一条连续的消息**，
> 而不是一串平级事件卡片 —— 对齐 Claude Code / Cursor 的 agent turn 体验。

## Status — 已实现（addendum, 2026-06）

Turn → Block 模型已落地（Phase A–E），实机验证通过。落地过程中有一处**关键修正**，
与下文初版设计不同，以本节为准：

- **`thinking` 事件 = 助手的对话叙述，不是隐藏推理，不折叠。** wire 帧实证：
  `kind:"thinking"` 的 text 是「改动涉及 11 个文件…让我逐个 commit 展开：」这类对用户说的话。
  服务端把同一段叙述**同时发到 `thinking` 和 `token_delta` 两条通道**。因此：
  - `thinking` 渲染为 **inline 助手回复文本**（与工具交错），而非折叠的紫色 ThinkingCard。
  - `TimelineProjection.mergeAdjacentNarration` 把相邻、互为前缀的助手文本合并，吃掉两通道的重复。
  - 效果就是 Claude Code 的体感：回复 → 工具 → 回复 → … → 最终答案。
  - 下文「Projection 规则」里 `.thinking → 折叠 block」与「View 层」里「ThinkingCard 斜体折叠」**已作废**。
- **助手文本分段**（reducer，Phase A）+ **turn_finished 按内容去重**：保证最终答案不丢、不重复。
- **生命周期**（model invoked/finished）→ turn footer，不进内容；三个 reorder pass 已删除（Phase E）。
- **工具**：连续同名合并为 `read_file ×N`（完成且 >1 才折叠；运行中保持独立展开）。

**Live / History 一致性**：投影层已一致（live 与 history 走同一个 `projectTurns`）。剩余差异是
**服务端**对失败 turn 未持久化全部中间内容（live 有、history 缺）——属服务端待办，非客户端。

**已知遗留（优化项，未做）**：多轮对话后工具合并/折叠时偶有 UI 跳动。

---

## TL;DR

把渲染模型从 **「扁平事件流 → 每个 node 一张卡」** 升级为 **「Turn → Block 两层树」**：

- 一个 `ConversationTurn` = user prompt + 有序的 `[TurnBlock]` + 一个 turn 级 footer。
- 生命周期事件（`model invoked/finished`）**不再是内容**，降级为元数据（驱动 spinner / footer 的 tokens·耗时）。
- 文本和工具按到达顺序**交错**成 block，流式 delta 原地更新当前文本 block。
- 连续同类工具**合并计数**（`read_file ×3`），默认折叠，展开看明细。

副作用收益：可以删掉投影里三个事后重排 pass（`prioritizeThinking` /
`reorderAssistantToTurnEnd` / `reorderModelFinished`），顺序变成投影时的结构，
而非渲染前的硬排序 —— 一整类「事件错位」bug 从根上消失。

---

## Problem — 当前为什么不像「一条消息」

现状管线：

```
ExecutionGraph → TimelineProjection → 扁平 [ExecutionNode] → 每个 node 一张卡
                                       (+ 3 个重排 pass)
```

三个连锁问题：

1. **生命周期当内容渲染**。`model invoked` / `model finished: 44795 prompt tokens, 3306ms`
   被投影成 `.system(.modelActivity)` 节点，和工具、消息**平级**进 timeline → 满屏噪音。
2. **没有 turn 容器**。`ChronologicalTimelineView` 用 `LazyVStack(spacing: 6)` 平铺，
   每张卡又自带 `background(.quaternary)` 圆角 → 视觉碎片化，读起来「很多事件拼起来」。
3. **靠重排硬凑顺序**。因为底层是扁平数组，投影里塞了三个 reorder pass 事后摆位置。
   其中 `reorderAssistantToTurnEnd` **强行把助手文本沉到 turn 末尾**，这与「文本/工具交错」
   的正确形态相反 —— 真实 turn 是 `文本 → 工具 → 文本 → 工具`，沉底破坏了连续感。
   （问题 2「model_finished 错位」正是这套重排的产物。）

---

## Reference — Claude Code / Cursor 怎么建模 turn

调研结论一致：**turn = 一个有序的 block 序列，而不是一串平级事件**。

- **Claude Code**（React + Ink）：一次助手回复由若干 streamed block 组成 —— 文本是 bullet 行，
  工具输出是 fenced 块，thinking/system 是斜体注释。**连续同类工具合并**：40 次 read 折叠成
  一行「40 actions」+ 当前正在跑的那个的一行摘要。滚出视口的消息整棵子树冻结缓存。
- **Cursor**：一条 agent 消息内联渲染工具调用，args/results 可展开，thinking 可折叠；
  compact 模式直接隐藏工具图标和 diff 来降噪。

共同点：① 一个 turn 容器；② 内部 block 按到达顺序排列、文本与工具**交错**；
③ 生命周期是**元数据**（驱动 spinner / footer），不是内容行；④ 同类工具**合并计数**。

---

## Architecture — Turn → Block 两层模型

在 `[ExecutionNode]` 和视图之间插一层**结构化投影**，把扁平流折叠成树：

```
RuntimeSnapshot.timeline ([ExecutionNode])
  → TurnProjection.projectTurns()
    → [ConversationTurn]
         ├─ userPrompt : MessageNodePayload?
         ├─ blocks     : [TurnBlock]        // 按到达顺序，天然交错
         │     .text(MessageNodePayload)        // 流式文本段，delta 原地更新
         │     .thinking(ThinkingNodePayload)   // 折叠，斜体
         │     .toolGroup(ToolGroup)            // 连续同类/同批工具合并
         │     .artifact(ArtifactNode)
         │     .system(SystemNodePayload)       // 仅 observation/reflection/error
         └─ footer     : TurnStats?         // tokens·耗时·invocations
```

### Data model（建议放 `Features/Conversation/Models/`）

```swift
/// 一轮对话：一条 user prompt + 它触发的助手活动，渲染成一条连续消息。
public struct ConversationTurn: Identifiable, Sendable {
    public let id: String            // = turnID
    public let userPrompt: MessageNodePayload?
    public let blocks: [TurnBlock]
    public let footer: TurnStats?    // nil = 进行中（footer 还没数据）
    public let isLive: Bool          // 该 turn 是否仍在流式接收
}

/// turn 内的一个有序块。文本可重复出现（与工具交错）。
public enum TurnBlock: Identifiable, Sendable {
    case text(id: String, MessageNodePayload)
    case thinking(id: String, ThinkingNodePayload)
    case toolGroup(ToolGroup)
    case artifact(id: String, ArtifactNode)
    case system(id: String, SystemNodePayload)   // observation / reflection / error only
}

/// 连续同类（或同一批并行）工具的合并组。
public struct ToolGroup: Identifiable, Sendable {
    public let id: String
    public let tools: [ToolNodePayload]
    /// 折叠摘要："read_file ×3" / 单个时就是工具名。
    public var summary: String
    /// 当前应展开的工具 callID（沿用现有 activeToolCallID 规则）。
    public var activeToolCallID: String?
}

/// turn 级统计：由该 turn 内所有 model_finished 聚合而来。
public struct TurnStats: Sendable {
    public let promptTokens: Int
    public let elapsedMs: Int
    public let invocationCount: Int
}
```

### Projection 规则

| 源 `ExecutionNode` | 投影后 |
|---|---|
| `.message(.user)` | 开启一个新 `ConversationTurn`，作为 `userPrompt` |
| `.message(.assistant)` | 追加 `.text` block；流式 delta 合并进**当前**文本 block |
| `.thinking` | 追加 `.thinking` block（连续 thinking 合并） |
| `.tool` | 追加进**当前** `toolGroup`；与上一个工具同类/同批则合并，否则开新组 |
| `.artifact` | 追加 `.artifact` block（或挂在产出它的工具上，沿用现有逻辑） |
| `.system(.observation/.reflection/.error)` | 追加 `.system` block（保留） |
| `.system(.modelActivity, phase=started)` | **不进 block** → 置 turn `isLive`，驱动 spinner |
| `.system(.modelActivity, phase=finished)` | **不进 block** → 累加进 `footer`（tokens/耗时/invocationCount++） |
| `.system(.contextCompact/.skillLoaded)` | 降级为 turn 内一行 meta chip（或并入 footer），不占主流 |

**关键：顺序即结构**。block 按事件到达顺序追加，文本与工具天然交错，
不需要任何事后 reorder。流式时只更新「当前」文本 block / toolGroup，不重排已落定的 block。

---

## View 层改造

| 层 | 现在 | 升级后 |
|---|---|---|
| 投影 | `project() -> [ExecutionNode]` + 3 个重排 pass | 新增 `projectTurns() -> [ConversationTurn]`，按 `turnID`/`invocationID` 折叠 |
| 容器 | `LazyVStack { ForEach(nodes) { NodeCard } }` | `LazyVStack { ForEach(turns) { TurnView } }` |
| `TurnView`（新） | — | 一个 turn 一段连续 VStack：user 气泡 + 共享左 rail 的 blocks + 底部 subtle footer，**去掉每卡的 background 圆角** |
| `ToolGroupView`（新） | — | 合并组：折叠时一行 `read_file ×3 ›`，展开列出每个工具 |
| `ToolCard` | 独立填充卡 | 降级为「一行」样式（icon + 名 + 计时 + chevron），归入 `ToolGroupView` |
| `ThinkingCard` | 紫底大块 | 斜体小字、默认折叠，可展开 |
| 生命周期 | `SystemEventRow` 渲染 `modelActivity` | `modelActivity` 不进 block；observation/error 仍保留 |

`turnID` / `invocationID` 数据已存在于 `ExecutionNode`（见 `Core/RuntimeEngine/ExecutionNode.swift`），
投影折叠不需要协议改动。

### 视觉规范（TurnView）

- **连续感**：turn 内 block 之间用小间距（2–4pt）+ 可选共享左 rail，**不要**每个 block 单独描边/填充背景。
- **层级**：user prompt 气泡 → 助手活动区（thinking 折叠、tool 行、文本段交错）→ footer（次要色，token·耗时）。
- **live 态**：turn 末尾 spinner/timer 由 `isLive` 驱动；当前文本 block 显示流式光标。
- **history 与 live 同构**：同一套 `projectTurns()`，history 只是 `isLive=false` + footer 已就绪。

---

## Live / History Consistency（核心不变量）

> **要求**：实时流和历史回放必须渲染成**完全相同**的结果。现在不是。

### 现状：live 和 history 走出两种 graph 形状

| | 实时流（live） | 历史回放（history） |
|---|---|---|
| 助手文本来源 | `token_delta` 增量 | `turn_finished` 整段完成文本 |
| 节点构建 | `handleTokenDelta`：单累加器 `streamingAssistant` + 单节点 `turnID_assistant`，**整轮一个、跨 invocation 不重置**（`ExecutionReducer.swift:212`） | `handleTurnFinished` line 167 分支：一个 **completed** 节点，位置自然（`ExecutionReducer.swift:164`） |
| 排序 | `reorderAssistantToTurnEnd` 把它**强行沉底**（`TimelineProjection.swift:294`） | 无 reorder 戏剧性 |

→ 两条路径构建出**不同形状的 graph**，这是不一致的根因。

### 由此产生的两个实时 bug

1. **助手消息总是钉在最底部**：`reorderAssistantToTurnEnd` 把唯一的助手节点移到 turn 末尾，
   破坏了「文本/工具交错」的真实顺序。
2. **助手文本和 thinking 拼接 / 跨轮合并成一坨**：助手文本是**单节点单累加器**，而 thinking 是
   **分段的**（`nextThinkingSeq`，在 `toolStarted`/`modelFinished` 处 finalize + 清空，
   `ExecutionReducer.swift:269` / `:409`）。多次 invocation 的助手文本全被塞进同一个底部节点，
   又紧挨最后一段 thinking → 视觉上「和 think 事件粘在一起」。

### 不变量（本方案要建立的契约）

```
一个 reducer + 一个 projection + 等价的事件粒度 → 同形状 graph → 同一套 UI
```

落地这套方案后一致性**自然成立**，但需要两处配合（不是纯视图层改动）：

1. **Reducer：助手文本要像 thinking 一样分段。** 现在 thinking 在 `toolStarted`/`modelFinished`
   处 finalize 并重置，产出按 invocation/段落分开的多个节点；助手文本缺这套。
   **修法**：镜像 thinking 的逻辑 —— 在 tool 开始或新 invocation 开始时，finalize 当前助手节点、
   清空 `streamingAssistant`、`nextAssistantSeq += 1`，从而每个文本段是独立节点、落在真实位置。
   这样 live 产出的 graph 形状 == history 应有的形状。

2. **Projection：Turn → Block 按到达顺序，删掉 reorder。** 文本段已在正确位置，`projectTurns()`
   只需折叠成有序 `.text` block。没有 `reorderAssistantToTurnEnd` → 不沉底、不粘 thinking。
   live / history 共用同一个 `projectTurns()` over 同形状 graph → **逐像素一致**。

### Text-segment 不变量

> **一个 `.text` block 的边界 = 任意非文本块（thinking / tool / 新 invocation）。**

live 和 history 都必须遵守。含义：

- 同一段连续助手输出（中间无工具/thinking）= 一个 `.text` block。
- history 侧若服务端只给整轮一坨文本、但该轮其实交错了工具，则**无法事后切分** ——
  因此历史数据也必须按段交付（与 live 等价粒度），或由投影按 invocation 边界规整。
  这是 live/history 真正一致的前提，需在协议/回放层保证（见 Non-goals 之外的协议确认项）。

---

## Migration Plan（分阶段，每阶段独立可编译/验证）

### PR-0 — Reducer：助手文本分段（一致性前提）
- `handleTokenDelta` 镜像 thinking：在 `toolStarted` / 新 invocation 处 finalize 当前助手节点、
  清空 `streamingAssistant`、`nextAssistantSeq += 1`，每个文本段独立节点。
- 单测：同一组事件分别按「live 增量」和「history 整段」喂入，断言产出的 graph **节点结构等价**。
- 验收：live 不再单节点累加；为 PR-1 的一致性打底。

### PR-1 — Model + Projection（不碰 UI）
- 新增 `ConversationTurn` / `TurnBlock` / `ToolGroup` / `TurnStats`。
- 新增 `TurnProjection.projectTurns(_ timeline:) -> [ConversationTurn]`，遵守 text-segment 不变量。
- 单测：喂典型事件序列（含交错文本/工具、并行工具、多 invocation），断言 block 结构与 footer 聚合；
  **关键用例**：同一会话的 live 流与 history 回放 → `projectTurns()` 输出 deep-equal。
- 验收：纯逻辑，现有 UI 不变，测试绿。

### PR-2 — TurnView 渲染
- 用 `ForEach(turns) { TurnView }` 替换 `ChronologicalTimelineView` 的平铺。
- 生命周期降级为 spinner + footer；`modelActivity` 不再渲染成内容行。
- 暂不做工具合并（toolGroup 内逐个渲染即可）。
- 验收：一轮对话视觉上是一条消息；`Model invoked/finished` 噪音消失。

### PR-3 — Tool 行化 + 合并 + 折叠
- `ToolGroupView`：折叠一行 `×N` + 当前运行项摘要；展开列明细。
- `ToolCard` 改为单行样式；接上现有 `activeToolCallID` 展开规则。
- `ThinkingCard` 改斜体折叠样式。

### PR-4 — 清理旧管线
- 删除 `prioritizeThinking` / `reorderAssistantToTurnEnd` / `reorderModelFinished`。
- `TimelineProjection` 仅保留 graph → 有序 node 的纯投影；排序交给 `projectTurns()` 的结构。
- 回归：实时流多轮带工具 + 历史回放，对比 turn 边界与交错顺序。

---

## Open questions（需确认）

- **历史回放的文本粒度**：若服务端历史只返回整轮一坨助手文本、而该轮交错了工具，
  则无法事后切分以匹配 live 的分段（见 text-segment 不变量）。需确认历史接口能否按段/按
  invocation 返回，或由回放层拆分。这是 live/history 真正逐像素一致的前提。

## Non-goals（本期不做）

- 不主动扩展服务端协议（`turnID`/`invocationID` 已够用）；但上面「历史文本粒度」需先确认。
- 不做 off-screen 子树冻结那类性能优化（后续可选，先保证模型正确）。
- 不动 Inspector / Artifact 详情页，只改 timeline 主流的组织方式。

---

## References

- Claude Code — streamed blocks 模型：<https://fazm.ai/t/watch-claude-code-desktop-agent-ui>
- Claude Code from Source — Ch.13 Terminal UI：<https://claude-code-from-source.com/ch13-terminal-ui/>
- Claude Code UI/UX (DeepWiki)：<https://deepwiki.com/anthropics/claude-code/3.9-uiux-and-terminal-integration>
- Cursor 3.0 — compact chat：<https://cursor.com/changelog/3-0>
- Cursor Agent overview：<https://cursor.com/docs/agent/overview>

## Related docs

- [`artifact_system_plan.md`](artifact_system_plan.md) — artifact 语义层（toolGroup 内 artifact 复用其映射）
- [`client_integration_v1.md`](client_integration_v1.md) — 事件流协议
