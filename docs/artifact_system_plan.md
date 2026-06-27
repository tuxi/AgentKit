# P4 Artifact System — Final Plan (v3)

## Architecture

```
AgentEvent (stream)
  → ConversationState reducer
    → TurnGroup.toolCalls[callID] = ToolCallItem
    → TurnGroup.artifacts[callID] = ToolSemanticMapper.map(item, turnID)
      → ArtifactNode (flat + relations, not tree)
        → ArtifactView system (pure rendering, group by callID order)
```

**Core principle**: `Tool output ≠ Artifact` → `Tool output → semantic mapping → Artifact graph`

**Three architectural constraints:**

1. **Turn-scoped**: artifacts 挂在 `TurnGroup.artifacts` 字典，非全局列表
2. **Upsert by callID**: `artifacts[callID] = node`，非 append，避免 retry/update 重复
3. **Flat + relations**: `relatedCallIDs: [String]` 表示关联图，非 `children` tree — 保持 semantic layer 扁平，UI 负责 grouping

## PR-1: Artifact Domain Model

### `Core/Artifact/ArtifactKind.swift`

```swift
public enum ArtifactKind: String, Sendable, CaseIterable {
    case diff
    case file
    case terminal
}
```

### `Core/Artifact/ArtifactPayload.swift`

```swift
public enum ArtifactPayload: Sendable {
    case diff(DiffPayload)
    case file(FilePayload)
    case terminal(TerminalPayload)
}

public struct DiffPayload: Sendable {
    public let filePath: String?
    public let diffContent: String
}

public struct FilePayload: Sendable {
    public let filePath: String
    public let content: String
    public let language: String?
}

public struct TerminalPayload: Sendable {
    public let command: String
    public let output: String
    public let exitCode: Int?
}
```

### `Core/Artifact/ArtifactNode.swift`

```swift
public struct ArtifactNode: Identifiable, Sendable {
    public var id: String { callID }
    public let turnID: String
    public let callID: String
    public let kind: ArtifactKind
    public let title: String
    public let payload: ArtifactPayload
    public var relatedCallIDs: [String]   // flat relation graph, not tree
}
```

`relatedCallIDs` 指针指向同 turn 内的其他 artifact callID。UI 可按需 grouping，但不强制嵌套结构。未来可扩展为 full DAG。

## PR-2: ToolSemanticMapper + State Integration

### `Core/Artifact/ToolSemanticMapper.swift`

Domain-layer mapper — stateless, deterministic, pure function。

```swift
public struct ToolSemanticMapper {
    /// Maps a completed ToolCallItem to an optional ArtifactNode.
    /// Returns nil for non-artifact tools.
    /// Multiple related artifacts (e.g. write → diff + preview) share callIDs via relatedCallIDs.
    public static func map(_ tool: ToolCallItem, turnID: String) -> ArtifactNode?
}
```

**Metadata First + Observation Fallback:**

| Step | Source | Purpose |
|------|--------|---------|
| 1 | `tool.toolName` | Determine `ArtifactKind` via pattern matching |
| 2 | `tool.toolArgs` (JSONValue) | Extract filePath, command, language |
| 3 | `tool.result?.observation` | Fallback: content/diff/output text |

**Kind判定（toolName contains check）:**

| Pattern | Kind | Example tools |
|---------|------|---------------|
| `write`/`edit`/`patch`/`diff`/`apply`/`create`/`save` | `.diff` | write_file, apply_patch |
| `read`/`cat`/`view`/`open`/`get`/`list` | `.file` | read_file, view_code |
| `bash`/`shell`/`exec`/`terminal`/`run`/`cmd` | `.terminal` | run_terminal, exec |
| other | nil | returns no artifact |

**字段提取（args first, observation fallback）：**
- `filePath`: `toolArgs["file_path"]` ?? `toolArgs["path"]` ?? `toolArgs["file"]`
- `command`: `toolArgs["command"]` ?? `toolArgs["cmd"]`
- `language`: `toolArgs["language"]` ?? inferred from filePath extension
- content/diff/output: `result.observation` (primary content)

### State Integration

**`TurnGroup` 新增字段：**
```swift
/// callID → ArtifactNode (upsert, not append)
public var artifacts: [String: ArtifactNode]
```

**Reducer `toolFinished` case 新增：**
```swift
// 在现有 tool_finished 处理末尾追加：
if let item = turn.toolCalls[callID],
   let node = ToolSemanticMapper.map(item, turnID: tid) {
    turn.artifacts[callID] = node
}
```

**`ConversationState` 便利访问器：**
```swift
public var currentArtifacts: [ArtifactNode] {
    guard let turn = currentTurn else { return [] }
    return turn.toolCallIDs.compactMap { turn.artifacts[$0] }
}
```

## PR-3: Artifact Renderer

### `Features/Conversation/Views/Artifacts/`

所有 View 为纯渲染层，不包含任何解析/mapping 逻辑。

**`ArtifactView.swift`** — 分发器：
- 接收 `ArtifactNode` 及关联 artifacts 字典（用于 resolve `relatedCallIDs`）
- `switch artifact.payload` → `DiffArtifactView` / `FileArtifactView` / `TerminalArtifactView`
- 统一容器：标题栏 + 折叠/展开

**`DiffArtifactView.swift`**：
- 标题 "Diff: \(filePath ?? "unknown")"
- 等宽字体，`+`绿/`-`红行着色，水平滚动

**`FileArtifactView.swift`**：
- 标题 "📄 \(filePath)" + 语言标签
- 等宽深色背景代码区 + 行号，双向滚动，默认 50 行

**`TerminalArtifactView.swift`**：
- 标题 "$ \(command)" + exit code badge
- 等宽深色终端风格，复制按钮

### 集成点

`ConversationTimelineView` → `TurnCardView`，tool cards 之后、assistant bubble 之前：

```swift
// 在 TurnCardView body 中
let orderedArtifacts = turn.toolCallIDs.compactMap { turn.artifacts[$0] }
ForEach(orderedArtifacts) { artifact in
    ArtifactView(artifact: artifact)
}
```

## Future (not in this PR)

- **P4.2**: Artifact Streaming Model — `toolStarted → skeleton`, `toolDelta → patch`, `toolFinished → finalize`
- **P4.3**: Artifact Patch Engine — diff-level incremental update
- **P4.4**: Artifact Graph Viewer — relation-aware browsing

## Files Changed

| PR | File | Action |
|----|------|--------|
| PR-1 | `Core/Artifact/ArtifactKind.swift` | Create |
| PR-1 | `Core/Artifact/ArtifactPayload.swift` | Create |
| PR-1 | `Core/Artifact/ArtifactNode.swift` | Create |
| PR-2 | `Core/Artifact/ToolSemanticMapper.swift` | Create |
| PR-2 | `Models/ConversationState.swift` | Edit: TurnGroup +artifacts, reducer +1行, state +便利访问器 |
| PR-3 | `Views/Artifacts/ArtifactView.swift` | Create |
| PR-3 | `Views/Artifacts/DiffArtifactView.swift` | Create |
| PR-3 | `Views/Artifacts/FileArtifactView.swift` | Create |
| PR-3 | `Views/Artifacts/TerminalArtifactView.swift` | Create |
| PR-3 | `Views/ConversationTimelineView.swift` | Edit: 集成 ArtifactView |

## Verification

1. `xcodebuild -scheme AgentKit -destination 'platform=macOS' build`
2. `swift test` (AgentKit)
3. 手动验证 tool → artifact 映射正确性
4. 验证 upsert 不产生重复
