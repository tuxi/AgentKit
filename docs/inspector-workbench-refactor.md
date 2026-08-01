# Inspector Workbench 重构设计

> 状态：进行中
> 建立日期：2026-08-01
> 适用仓库：AgentKit、FileViewerKit、宿主应用（当前为 chater/Talkify）

## 1. 背景

现有 AgentKit Inspector 由两个主要视图组成：

- `InspectorView(selection:)` 根据 `InspectorSelection` 渲染某个 Agent 产物或详情。
- `InspectorNavigationView(initialSelection:fileProvider:)` 在其外部提供
  `NavigationStack`，支持工具结果、文件、Diff、Agent 状态和资产详情的纵深导航。

这套结构可以展示单个详情，但还不是 Codex 风格的工作台。目标 Inspector 需要提供五个稳定主入口：

1. 审阅
2. 终端
3. 浏览器
4. 文件
5. 侧边聊天

这是一项结构重构，不应通过继续向 `InspectorSelection` 增加临时 case 完成。

## 2. 设计原则

### 2.1 Inspector 是工作台，不只是详情页

主聊天负责 Agent 的指挥、停止、审批和主要输入；Inspector 负责观察产物、操作环境和补充上下文。隐藏 Inspector 不应销毁其中的终端、浏览器、文件位置或辅助聊天。

### 2.2 保留现有产物查看能力

`InspectorSelection` 表示由时间线或 Agent 事件选中的产物。它和五个主入口不是同一层概念：

- `InspectorEntry`：用户主动进入的长期工作区。
- `InspectorSelection`：从对话内容临时打开的详情对象。
- `InspectorDestination`：Inspector 内部的 push 导航目标。

### 2.3 文件预览采用渐进式收敛

FileViewerKit 是文件树和多类型文件预览的专用模块，但目前仍不完整。AgentKit 的 `NativeCodePreviewView` 在 macOS 源码展示、选区和性能方面更成熟，因此现阶段不能简单删除 AgentKit 的实现。

短期策略：

- Agent 事件携带的 `FilePayload` 继续使用 AgentKit 的原生代码预览。
- 工作区实时文件浏览逐步使用 FileViewerKit 的 provider、文件树和多媒体预览。
- Diff 渲染在 FileViewerKit 完善前保留现有 AgentKit 路径。

长期策略：抽取统一的代码预览能力供 AgentKit 和 FileViewerKit 复用，避免两个语法高亮和代码滚动实现继续分叉。

### 2.4 宿主持有数据与权限

宿主应用负责：

- 当前 conversation 对应的 workspace/worktree 根目录；
- 文件系统权限和 security-scoped URL；
- Git 对象读取和基线选择；
- 外部编辑器、浏览器和终端的实际创建；
- 侧边聊天的 conversation 生命周期。

AgentKit 负责工作台结构、路由、选择语义和公共接入协议。

## 3. 目标层次

```text
Host inspector column / sheet
└── InspectorWorkbenchView
    ├── InspectorLandingView         五个主入口
    ├── Inspector tab/session state  后续阶段
    └── InspectorNavigationView      详情纵深导航
        └── InspectorView            InspectorSelection 内容分发
            ├── NativeCodePreview
            ├── Diff / Terminal / Asset
            └── Tool / Child Stream / Workflow
```

文件相关能力：

```text
Inspector 文件入口
├── 工作区文件树：FileViewerKit
├── 文本代码预览：先按场景选择 NativeCodePreview 或 FileViewerKit
├── 图片/视频/PDF/二进制：FileViewerKit
└── 内容与 Git 数据：宿主 FileContentProvider
```

## 4. 状态模型方向

最终工作台状态应按任务或 conversation 隔离：

```swift
struct InspectorWorkspaceState {
    var isPresented: Bool
    var selectedTabID: InspectorTab.ID?
    var tabs: [InspectorTab]
}

struct InspectorTab {
    var id: UUID
    var entry: InspectorEntry
    var navigationPath: [InspectorDestination]
    var session: InspectorSession
}
```

`InspectorSession` 按入口保存独立状态，例如：

- 审阅：轮次、文件筛选、当前文件和滚动位置；
- 终端：PTY session ID；
- 浏览器：WebView session 和导航历史；
- 文件：workspace、文件路径、展开节点、选区和滚动位置；
- 侧边聊天：辅助 conversation ID。

第一阶段不立即把该状态塞入 `WorkspaceStore`，先建立主入口和兼容容器，避免一次改动同时影响宿主、时间线点击和 Inspector 深层导航。

## 5. API 边界

### 保留

- `InspectorView(selection:)`
- `InspectorNavigationView(initialSelection:fileProvider:)`
- `WorkspaceStore.showInspector(_:)`
- 现有 `InspectorSelection` case

### 新增

- `InspectorEntry`：五个主入口的稳定标识。
- `InspectorWorkbenchView`：新的推荐主入口。
- `InspectorLandingView`：无 selection 时展示五入口。

### 后续迁移

- `WorkspaceStore` 从单一 `inspectorSelection` 迁移到按 conversation 保存的工作台状态。
- `InspectorNavigationView` 的 path 迁移到 tab/session 级持久状态。
- 宿主由 `InspectorView` 切换到 `InspectorWorkbenchView`。

## 6. 分阶段实施

### Phase 1：主入口骨架

- [x] 建立重构文档。
- [x] 定义五个 `InspectorEntry`。
- [x] 新增 `InspectorWorkbenchView`。
- [x] selection 为空时展示五入口，不再展示 `Nothing Selected`。
- [x] 保留现有 selection 与 NavigationStack 行为。
- [x] 在 chater 中接入新的主入口。

### Phase 2：入口会话与标签

- [ ] 增加 Inspector tab/session 模型。
- [ ] 每个 tab 独立保存 NavigationPath。
- [ ] 关闭 Inspector 仅隐藏，不销毁资源。
- [ ] conversation 切换时恢复各自 Inspector 状态。
- [ ] 增加标签新增、关闭和选择交互。

### Phase 3：文件入口

- [ ] 使用 FileViewerKit 文件树构建宽屏文件工作区。
- [ ] 保留 `NativeCodePreviewView` 作为 macOS 优先代码渲染器。
- [ ] 统一实时文件和 Agent 事件快照的语义。
- [ ] 消除 AgentKit/FileViewerKit 两套 provider 与 Diff 模型的重复转换。
- [ ] 完善大文件、二进制、图片、视频和 PDF 状态。

### Phase 4：审阅入口

- [ ] 区分 Git working tree diff 与 turn-scoped diff。
- [ ] 文件树与 Diff 双向定位。
- [ ] 支持轮次、筛选、增删统计和未修改行折叠。
- [ ] 完善 FileViewerKit 的 DiffView，或抽取统一 Diff 渲染核心。

### Phase 5：终端、浏览器、侧边聊天

- [ ] 终端使用宿主持有的 PTY session。
- [ ] 浏览器使用可持久化的 WebView session。
- [ ] 侧边聊天与主任务执行队列隔离，但可以引用当前 Inspector 上下文。
- [ ] 明确 Agent 控制浏览器/终端时的所有权和状态提示。

## 7. 已知风险

1. macOS 的 `NavigationSplitView` Inspector 列嵌套 `NavigationStack` 曾触发
   `comparisonTypeMismatch`。在恢复 macOS 深度导航前必须建立复现用例。
2. FileViewerKit 的 `FilePreviewHost(showDiff: true)` 当前加载了 `change`，但没有把它渲染为 Diff。
3. AgentKit 和 FileViewerKit 各自定义了 `FileContentProvider`、DiffHunk 和 DiffLine。
4. `InspectorSelection.file` 是事件快照，而工作区文件入口读取的是实时文件，不能互相替代。
5. Terminal 和 WebView 不能以普通 SwiftUI 条件分支的生命周期管理，否则切换入口时会丢失进程或页面状态。

## 8. 验收标准

第一阶段完成时：

- 宿主可以把 `InspectorWorkbenchView` 作为 Inspector 唯一主入口；
- selection 为空时稳定展示五入口；
- 点击入口通过明确回调交给宿主或后续 session router；
- selection 非空时现有文件、Diff、终端、资产、工具和子流详情行为不变；
- iOS Sheet 与 macOS Inspector 列可以选择是否启用内部 NavigationStack；
- 不要求 FileViewerKit 在第一阶段完成统一。

第一阶段推荐接入方式：

```swift
InspectorWorkbenchView(
    selection: store.inspectorSelection,
    fileProvider: fileProvider,
    // macOS 嵌套导航问题解决前可关闭；iOS Sheet 保持开启。
    usesNavigationStack: supportsInspectorNavigation
) { entry in
    inspectorCoordinator.open(entry)
}
```

入口回调暂时由宿主接管是有意的兼容边界：终端、浏览器和侧边聊天都包含
宿主持有的长生命周期资源，不能在第一阶段用临时 SwiftUI 页面冒充完整实现。

## 9. 决策记录

- 2026-08-01：确认重构从主入口开始，FileViewerKit 后续改造。
- 2026-08-01：确认暂时保留 AgentKit `NativeCodePreviewView`，不以 FileViewerKit 当前实现强制替换。
- 2026-08-01：确认五入口属于工作台层，不继续膨胀 `InspectorSelection`。
- 2026-08-01：Phase 1 通过 `swift test`，311 项测试通过、1 项跳过、0 项失败。
- 2026-08-01：chater 新增宿主协调层 `TalkifyInspectorWorkbench`，iOS Sheet 与
  macOS Inspector 列均切换到 `InspectorWorkbenchView`；文件入口在 iOS 转交现有
  Workspace Browser，其余尚未实现的入口显示明确的阶段性状态，不创建伪会话。
- 2026-08-01：宿主接入通过 `Talkify-MacDirect` macOS 构建与 `Talkify` iOS
  Simulator 构建；现有 Swift 6 concurrency 警告不属于本轮改造。
