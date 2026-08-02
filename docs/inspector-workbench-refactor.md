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

工作台状态按任务或 conversation 隔离。Phase 2 已落地为引用类型状态树：

```swift
@Observable final class InspectorWorkspaceState {
    let conversationID: String?
    var isPresented: Bool
    var selectedTabID: InspectorTabState.ID?
    var tabs: [InspectorTabState]
    let selectionPathState: InspectorPathState
}

@Observable final class InspectorTabState {
    let id: UUID
    let session: InspectorSessionState
    let pathState: InspectorPathState
}

@Observable final class InspectorSessionState {
    let id: UUID
    let entry: InspectorEntry
    var hostResourceID: String?
}
```

`InspectorSession` 按入口保存独立状态，例如：

- 审阅：轮次、文件筛选、当前文件和滚动位置；
- 终端：PTY session ID；
- 浏览器：WebView session 和导航历史；
- 文件：workspace、文件路径、展开节点、选区和滚动位置；
- 侧边聊天：辅助 conversation ID。

`WorkspaceStore` 按 conversation ID 保留 `InspectorWorkspaceState`；conversation 切换时只替换
当前状态引用。PTY、WebView 和辅助聊天等资源仍由宿主持有，以 `InspectorSessionState.id`
作为稳定绑定键。

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

- [x] 增加 Inspector tab/session 模型。
- [x] 每个 tab 独立保存 NavigationPath。
- [x] 关闭 Inspector 仅隐藏，不销毁 session 状态。
- [x] conversation 切换时恢复各自 Inspector 状态。
- [x] 增加标签新增、关闭和选择交互。

### Phase 3：文件入口

- [x] 使用 FileViewerKit 文件树构建宽屏文件工作区。
- [x] 保留 `NativeCodePreviewView` 作为 macOS 优先代码渲染器。
- [x] 统一实时文件和 Agent 事件快照的语义。
- [x] 消除实时文件内容与类型识别的重复 provider 实现。
- [ ] 消除 AgentKit/FileViewerKit 两套 Diff 模型转换（并入 Phase 4）。
- [x] 建立大文本上限、二进制拒绝和图片、视频、PDF 的类型分发。
- [x] 补齐超大文件分段读取、视频/PDF 加载失败恢复等边界状态。

### Phase 4：审阅入口

- [x] 以只读方式明确展示 `HEAD ↔ working tree`，不与 turn-scoped diff 混用。
- [x] 展示本地 A/M/D 文件、筛选、刷新、增删统计和当前文件选择。
- [x] macOS 宿主通过受工作区根目录约束的 Git provider 注入数据。
- [x] FileViewerKit 提供统一 `LineDiffBuilder` 和自适应 `ReviewWorkspaceView`。
- [x] 变更文件按目录树组织，选择与 Diff 联动，并展示 hunk 之间的未修改行数。
- [ ] 从 Diff/时间线反向定位文件树，以及按需展开被省略的原文件内容。
- [x] iOS Workspace diff 迁移到统一 builder，并将旧 AgentKit 模型转换集中为单一兼容适配器。
- [ ] 最终移除 AgentKit 旧 Diff 协议模型；需先确认 AgentKit 是否允许依赖独立展示包。
- [ ] 暂存、撤销、提交、分支比较和行评论。

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
- 2026-08-01：Phase 2 建立 conversation-scoped `InspectorWorkspaceState`、稳定的
  `InspectorSessionState` 身份、可增删选的标签栏，以及每标签独立的
  `InspectorPathState`；时间线 selection 使用单独 path，关闭 Inspector 时清理该临时
  selection，但不销毁长期入口 session。
- 2026-08-01：Phase 2 完整回归为 317 项测试通过、1 项跳过、0 项失败；chater 的
  `Talkify-MacDirect` macOS 构建与 `Talkify` iOS Simulator 构建均通过。
- 2026-08-01：Phase 3 第一切片完成：FileViewerKit 新增根目录受限的本地 provider、
  可选中文件树和自适应 `FileWorkspaceView`；AgentKit 公开 `AgentCodePreviewView`，
  让宿主在 macOS 复用 `NativeCodePreviewView`，其他平台保留现有 SwiftUI 预览。
- 2026-08-01：文件标签保存 `selectedFilePath`，读取实时工作区；时间线 `FilePayload`
  继续表示 Agent 事件快照，两者不隐式覆盖。
- 2026-08-01：首次宿主验证发现 macOS `OutlineGroup` 在展开目录的布局 pass 中同步观察
  懒加载 children 变化，会触发 AppKit 重复 Update Constraints 并以 `EXC_BAD_ACCESS`
  终止。文件树已改为显式递归分支：展开状态先稳定，再异步单飞加载 children；
  FileViewerKit 回归 26 项测试通过，chater `Talkify-MacDirect` macOS 构建通过。
- 2026-08-01：第二次宿主验证发现拖拽 Inspector 分割线仍可触发同类约束循环。
  原因是 macOS 没有 compact size class，文件工作区在 280–480pt 内仍强制树与预览双栏，
  同时 detail 曾声明低于最小宽度的 `idealWidth: 0`。现改用 `ViewThatFits` 按父级 proposal
  无状态切换单双栏，并统一 detail/Inspector 的合法宽度区间；macOS 宿主构建通过。
- 2026-08-01：Phase 3 预览边界继续收敛：超限文本不再伪装成二进制，而是携带
  文件大小与预览上限；`Makefile`、`Dockerfile`、`.gitignore` 等无扩展名文本获得统一
  类型识别；本地图片改为异步读取后使用平台原生解码，并提供失败重试。
- 2026-08-01：chater iOS 的 Workspace Provider 不再复制文件类型识别和文本读取，
  改为复用 FileViewerKit 的受根目录约束 provider，再向旧 AgentKit 文本协议做投影；
  Diff 模型转换保留到 Phase 4。FileViewerKit 28 项测试、macOS 与 iOS 宿主构建通过。
- 2026-08-01：Phase 3 文件预览收尾：Provider 增加带默认实现的 `textChunk` 能力，
  本地 provider 按 UTF-8 安全边界读取 256 KB 分段；超大文本自动显示首段并支持继续加载。
  视频通过 AVPlayer 状态和失败通知展示可重试错误，PDF 在进入 PDFKit 前验证文档并支持重试。
  FileViewerKit 29 项测试、chater macOS 与 iOS Simulator 构建通过。实时文件预览部分完成，
  剩余 Diff 数据模型统一随 Phase 4 审阅入口实施。
- 2026-08-01：Phase 4 第一切片采用只读边界：FileViewerKit 建立 canonical
  `FileReviewProvider`、`LineDiffBuilder` 与自适应 `ReviewWorkspaceView`；chater macOS 从
  `git status --porcelain -z` 读取 A/M/D 和未跟踪文件，以 `HEAD` 与当前工作区内容生成统一
  Diff。审阅选择与文件浏览选择独立保存；暂不支持暂存、撤销、提交、分支比较和行评论。
- 2026-08-01：Phase 4.2 收敛 Diff 计算链路：chater iOS 的两套 provider 均先生成
  FileViewerKit canonical hunks，删除宿主内重复的 `LineDiffer`；AgentKit 旧 Inspector 协议
  暂由唯一的 `AgentKitDiffCompatibilityAdapter` 承接，避免 AgentKit 反向依赖展示包。
  同时补齐新增、删除、尾部换行和远距离多 hunk 回归用例。iOS 的 loose Git object
  读取修正了 zlib wrapper、嵌套 tree 和 packed ref，并通过 5000 行嵌套文件 fixture；
  packfile object 解析仍明确留作后续能力。
- 2026-08-01：本阶段宿主构建暂受工作区中另一组未提交并发改动阻塞：
  `ConversationListViewModel.refreshTask` 的推断类型为 `Task<()?, Never>`，而声明为
  `Task<Void, Never>`。该改动不属于 Inspector 重构，因此未在本阶段代为修改。
- 2026-08-02：Phase 4.3 将审阅文件列表升级为显式递归目录树，目录聚合 A/M/D 状态并
  独立保存展开集合；继续避开曾在 macOS Inspector 分栏中触发约束循环的 `OutlineGroup`。
  `DiffHunk` 公开 old/new 行数，Diff 在 hunk 前显示保守计算的“未修改行”折叠提示。
  当前提示有意保持只读：canonical hunk 尚未携带被省略正文，后续接入原文件按需读取后
  再提供展开交互，避免按钮承诺无法呈现的数据。
