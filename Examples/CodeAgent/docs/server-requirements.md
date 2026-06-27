# CodeAgent Runtime 服务端需求

客户端版本：v2 event-sourcing runtime（已完成）
目标体验：对标 Claude Code GUI

---

## 需求 1：`tool_finished` 新增 `elapsed_ms` 字段

**现状**：工具执行完毕后，客户端不知道这个工具花了多长时间。

**改动**：在 `tool_finished` 事件中新增 `elapsed_ms` 字段（整数，毫秒）。

```json
{
  "kind": "tool_finished",
  "call_id": "call_1",
  "tool_name": "bash",
  "observation": "依赖安装完成...",
  "elapsed_ms": 1200
}
```

**客户端使用**：每个工具卡片底部显示 "⏱ 1.2s"。长命令耗时直观可见。

**优先级**：🟡 P2

---

## 需求 2：新增 `tool_stdout` / `tool_stderr` 流式事件

**现状**：长命令（`npm install`、`pod install`、`git clone`）执行期间，客户端完全无反馈。用户看到 spinner 一直转，不知道命令在正常跑还是卡死了。直到 `tool_finished` 才一次性拿到全部输出。

Cursor 和 Claude Code 都有实时滚动输出，这是当前最大的 UX 差距。

**改动**：新增两个事件类型，工具执行期间逐 chunk 推送。

### `tool_stdout`

```json
{
  "kind": "tool_stdout",
  "call_id": "call_1",
  "chunk": "Downloading packages...\n"
}
```

### `tool_stderr`

```json
{
  "kind": "tool_stderr",
  "call_id": "call_1",
  "chunk": "Warning: deprecated package\n"
}
```

### 生命周期

```
tool_started  →  tool_stdout (多个)  →  tool_stderr (任意)  →  tool_finished
```

**客户端使用**：`ToolCard` 在执行期间展开并实时滚动显示输出，类似终端效果。`tool_finished.observation` 保留完整输出作为非流式回退。

**优先级**：🟡 P2（影响最大的 UX 差距）

---

## 总结

| # | 事件 | 新增字段 | 类型 | 用途 |
|---|------|---------|------|------|
| 1 | `tool_finished` | `elapsed_ms` | Int | 工具耗时展示 |
| 2 | 新事件 | `tool_stdout` | `{call_id, chunk}` | 长命令实时输出 |
| 3 | 新事件 | `tool_stderr` | `{call_id, chunk}` | 标准错误流式 |
