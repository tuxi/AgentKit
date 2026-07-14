# CodeAgentMac Timeline Integration

`desktop-control-mcp` 已经提供一个可直接消费的 Timeline item 协议。CodeAgentMac 不需要
解析审计数据库，也不需要理解 AX Snapshot 内部结构；在 `action_commit` 成功返回后，按
`auditEventID` 读取 Timeline item 即可。

## 推荐接入流程

```text
action_commit
    │
    ├─ execution / verification / evidence.auditEventID
    │
    ├─ evidence_timeline_item_get(auditEventID)
    │       └─ Timeline item → CodeAgentMac Timeline
    │
    └─ evidence_bundle_export(auditEventID)
            └─ resource_link → 按需归档或展开证据
```

生产集成应使用 MCP 工具；本地演示可以运行：

```bash
Scripts/run-fixture-e2e.sh                 # 产生真实 action_commit
Scripts/run-timeline-demo.sh               # 生成 dist/timeline-demo/
```

## Timeline item 输入

调用：

```json
{
  "auditEventID": "audit_fa038ae1-0c18-4e08-91bc-1ec8294ea308"
}
```

得到 `schemaVersion = desktop-control.timeline-evidence.v1`、`type =
desktop_action_evidence` 的结构：

```json
{
  "itemID": "timeline_audit_...",
  "auditEventID": "audit_...",
  "title": "Verified press on Increment",
  "status": "passed",
  "summary": "Execution succeeded and all declared expectations passed.",
  "actionType": "press",
  "target": "Increment",
  "risk": "medium",
  "sections": [
    {
      "sectionID": "audit_....approval",
      "kind": "approval",
      "title": "Broker approval",
      "status": "passed",
      "summary": "Approval status: consumed.",
      "rows": []
    }
  ],
  "references": {},
  "documents": {
    "markdown": {},
    "html": {}
  }
}
```

CodeAgentMac 的 Timeline 卡片建议这样映射：

| Timeline 字段 | UI 用途 |
| --- | --- |
| `title` | 卡片标题 |
| `status` | 总体状态徽标：passed/failed/observed/unavailable/error |
| `summary` | 卡片摘要 |
| `actionType`, `target`, `risk` | 动作和风险标签 |
| `sections` | 可折叠的审批、执行、验证、diff、审计分区 |
| `sections[].rows` | 分区内字段表格 |
| `documents.markdown.body` | 无原生渲染器时的纯文本 fallback |
| `documents.html.body` | WebView fallback；作为 HTML 文档渲染，不执行脚本 |

## 边界与插件接入

AgentKit 提供两层宿主扩展契约：`TimelineExtension` 可为原生回退返回 `AnyView`；
`WebTimelineExtension` 为单文档 workbench 返回安全的 `TimelineWebNode` 语义节点
（card/section/row/badge/action），不接受任意主文档 HTML/JavaScript。它仍不识别
`action_commit`、desktop-control schema、Broker、MCP socket 或 Artifact URI。

CodeAgentMac 的实现位于 `Examples/CodeAgent/CodeAgent/DesktopControlEvidenceTimeline.swift`：

1. 从 `mcp__desktop_control__action_commit` 的结构化
   `output.evidence.auditEventID` 创建证据锚点；
2. 从 Go runtime 随后发出的
   `mcp__desktop_control__evidence_timeline_item_get` 结构化 output 读取 Timeline item；
3. 直接用 Timeline item 渲染卡片；不读取 SQLite，也不从 Markdown 反推数据；
4. 可选地消费 `mcp__desktop_control__evidence_bundle_export` 的 output，显示 runtime
   已导出的 `resource_link`；
5. 同一份 card 状态同时生成原生卡片和语义 Web 节点；Markdown/HTML 报告动作经
   opaque registry 打开 AgentKit 原生 Inspector。HTML 只进入禁脚本、禁网络和禁二次
   导航的隔离 WebView，不注入对话 DOM。

`.mcp.json`、MCP server 生命周期、`tools/call` 和 `resources/read` 全部由 Go runtime
管理；CodeAgentMac 不启动 `desktop-control-mcp`，也不持有 Broker socket。

## Evidence bundle

Timeline item 本身是展示模型，不是归档包。用户点击“查看证据”时再调用：

```json
{
  "auditEventID": "audit_...",
  "ttlSeconds": 3600
}
```

`evidence_bundle_export` 返回 `manifest` 与 `resource_link`。CodeAgentMac 应保存
resource URI 和 manifest，不要假设本地文件路径永久有效；需要展开时调用
`resources/read`，过期后显示“证据已过期”，不要尝试重新执行动作。

bundle 中的 `artifact-references.json` 记录截图的摘要元数据和
`available`/`missing_or_expired` 状态。存在缩略图时显示缩略图；原始截图仍由 Artifact
Store 的 TTL 管理。

## 安全约束

- Timeline item、Markdown、HTML 和 bundle 都是只读证据，不能触发 `action_commit`。
- UI 上的“重试”必须重新走 snapshot → prepare → Broker approval → commit，不能重放
  `intentID`。
- `set_value` 原文、secure/password/token 等字段不会出现在 Timeline 或 bundle 中。
- `status = passed` 表示执行成功且 expectation 通过；`execution` 成功但验证失败时，
  Timeline 必须显示 `failed`，不能只显示“点击成功”。

## 验收标准

CodeAgentMac 接入完成后，应能展示一次完整卡片：

1. Broker approval：approved/consumed；
2. Action execution：press target；
3. Result verification：expectation passed/failed；
4. Semantic UI diff：例如 `Count: 0 → Count: 1`；
5. Audit persisted：audit event ID；
6. “查看证据”：bundle resource link 与可选缩略图。
