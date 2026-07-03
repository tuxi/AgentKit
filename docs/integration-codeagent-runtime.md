# CodeAgentRuntime 集成指南

本文档描述 `CodeAgentRuntime.xcframework`（Go 运行时）从构建、分发到被 AgentKit（Swift Package）消费的完整链路，以及如何发布新版本。

## 架构概览

```
┌──────────────────────────────────────────────────────┐
│                   CodeAgent App                       │
│  ┌─────────────────────┐  ┌────────────────────────┐ │
│  │     iOS Target       │  │     macOS Target        │ │
│  │  (link CodeAgent     │  │  (no runtime link)      │ │
│  │   Runtime)           │  │                         │ │
│  └──────────┬───────────┘  └──────────┬──────────────┘ │
└─────────────┼──────────────────────────┼────────────────┘
              │                          │
       ┌──────▼──────┐            ┌──────▼──────┐
       │  AgentKit    │            │  AgentKit    │
       │  (iOS: link  │            │  (macOS:     │
       │   runtime)   │            │   no-op)     │
       └──────┬───────┘            └──────────────┘
              │
       ┌──────▼──────────────────────────────────┐
       │  CodeAgentRuntime.xcframework            │
       │  (binary target — url-based)             │
       │  SPM fetches from GitHub Releases        │
       └──────┬───────────────────────────────────┘
              │
       ┌──────▼──────────────────────────────────┐
       │  tuxi/code-agent (Go)                    │
       │  mobile/mobile.go  ──gomobile bind──▶    │
       │  scripts/release-ios.sh ──▶ Release     │
       └──────────────────────────────────────────┘
              │
       ┌──────▼──────────────────────────────────┐
       │  tuxi/code-agent-releases (public)       │
       │  GitHub Releases: xcframework.zip        │
       │  (no source — pure artifact hosting)     │
       └──────────────────────────────────────────┘
```

## 仓库与职责

| 仓库 | 可见性 | 职责 | 关键文件 |
|---|---|---|---|
| `tuxi/code-agent` | 可私有 | Go 源码 + gomobile 构建 | `mobile/mobile.go`, `scripts/build-ios.sh`, `scripts/release-ios.sh` |
| `tuxi/code-agent-releases` | **public** | 托管 xcframework 的 GitHub Release | 无源码，仅 Release artifacts |
| `tuxi/AgentKit` | public | Swift Package，通过 `binaryTarget(url:)` 引用 xcframework | `Package.swift` |
| `CodeAgent` | 本地 | App 项目，依赖 AgentKit | `project.pbxproj` |

> **闭源设计**：`code-agent` 可以设为 private，因为 `release-ios.sh` 将 xcframework 发布到独立的 public 仓库 `code-agent-releases`。AgentKit 和 SPM 只访问 public 仓库的 Release URL，不受源码仓库可见性影响。

## 构建流程

### 1. Go 源码 → xcframework

在 `code-agent` 仓库中构建：

```bash
# 前置条件：Go 1.25+、Xcode
# 脚本会自动安装 gomobile + gobind（如果未安装）
./scripts/build-ios.sh
```

发布：
```bash
./scripts/release-ios.sh 0.2.0
```

把脚本打印的 url/checksum 更新到 AgentKit/Package.swift
```text
脚本做了什么：

1. **gomobile init** — 初始化 gomobile 工具链
2. **gomobile bind** — 将 `./mobile` Go 包编译为 xcframework
   - `-target=ios,iossimulator` — 输出真机 + 模拟器两个 slice
   - `-iosversion=15.0` — 设置 MinimumOSVersion
3. **normalize Info.plist** — 确保每个内部 framework 的 `MinimumOSVersion` 为 15.0
4. **打包 skills** — 将内置 skills 复制到 `build/skills/`
```

产物：

```
build/
├── CodeAgentRuntime.xcframework/   # 约 149MB
│   ├── Info.plist
│   ├── ios-arm64/                  # 真机 (arm64)
│   │   └── CodeAgentRuntime.framework/
│   └── ios-arm64_x86_64-simulator/ # 模拟器 (arm64 + x86_64)
│       └── CodeAgentRuntime.framework/
└── skills/                         # 内置 skills
```

### 2. 发布到 GitHub Release

```bash
# 一条命令：打包 zip → 算 checksum → 发 Release → 打印 AgentKit 配置
./scripts/release-ios.sh 0.2.0
```

Release 创建在 `tuxi/code-agent-releases`（public 仓库），不需要 `code-agent` 仓库本身公开。

### 3. AgentKit 引用新版本

在 `tuxi/AgentKit` 仓库更新 `Package.swift`：

```swift
.binaryTarget(
    name: "CodeAgentRuntime",
    url: "https://github.com/tuxi/code-agent/releases/download/<VERSION>/CodeAgentRuntime.xcframework.zip",
    checksum: "<NEW_CHECKSUM>"
),
```

提交并推送：

```bash
cd AgentKit
git add Package.swift
git commit -m "chore: bump CodeAgentRuntime to <VERSION>"
git push origin main
```

### 4. App 项目更新

`CodeAgent` 项目的 `project.pbxproj` 已经配置为跟踪 AgentKit 的 `main` 分支：

```
kind = branch;
branch = main;
```

因此提交 AgentKit 后，App 下次构建会自动拉取新版本。如需锁定特定版本，可将 `kind` 改为 `revision`。

## 关键设计决策

### 为什么用 remote URL 而不是本地 path？

`binaryTarget(path:)` 的问题：
- xcframework 约 149MB，不宜纳入 Git
- `.gitignore` 排除后，其他开发者 clone 后编译直接失败

`binaryTarget(url:)` 的好处：
- 二进制托管在 GitHub Releases，不占仓库空间
- SPM 自动下载并缓存到 `~/Library/Caches/org.swift.swiftpm/artifacts/`
- Checksum 确保完整性和安全性

### 为什么 xcframework 只包含 iOS slice？

macOS App 不需要嵌入式运行时——它通过网络连接远程 code-agent 服务。因此：
- `xcframework` 只构建 `ios-arm64` 和 `ios-arm64_x86_64-simulator`
- `AgentKit` target 只在 iOS 上依赖 `CodeAgentRuntime`：

```swift
.target(name: "CodeAgentRuntime", condition: .when(platforms: [.iOS]))
```

- AgentKit 源码中的 import 也有编译时守卫：

```swift
#if os(iOS)
import CodeAgentRuntime
#endif
```

### 为什么 Release 放在 code-agent-releases 而非 code-agent 或 AgentKit？

三层分离：
- **code-agent**（可私有）：Go 源码的所有者，负责编译
- **code-agent-releases**（public）：纯 artifact 托管，零源码，永远公开
- **AgentKit**（public）：纯 Swift 消费者，通过 URL 引用

这样 `code-agent` 闭源后，AgentKit 的 SPM 解析不受任何影响——它只访问 public 仓库的 Release URL。

## 更新 Runtime 的标准流程

当 Go 代码（`mobile/mobile.go` 或 `internal/embed`）变更后：

```bash
# 1. 构建
cd code-agent
./scripts/build-ios.sh

# 2. 发布到 public release 仓库
./scripts/release-ios.sh 0.2.0

# 3. 把脚本打印的 url/checksum 更新到 AgentKit/Package.swift
cd ../AgentKit
# 编辑 Package.swift，替换 binaryTarget 的 url 和 checksum
git add Package.swift
git commit -m "chore: bump CodeAgentRuntime to 0.2.0"
git push origin main
```

## 故障排查

### SPM 报 "does not contain a binary artifact"

**原因**：SPM artifact 缓存损坏或残留。

```bash
# 清理 SPM 缓存
rm -rf ~/Library/Caches/org.swift.swiftpm/
rm -rf ~/Library/Developer/Xcode/DerivedData/CodeAgent-*
```

### SPM 报 "already exists in file system"

**原因**：上一次下载中断，残留了不完整的缓存目录。

```bash
# 删除特定 artifact 缓存
rm -rf ~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_tuxi_code_agent_releases_download_*
rm -rf ~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_tuxi_code_agent-releases_download_*
```

### SPM 一直使用旧版本

**原因**：`Package.resolved` 或 `project.pbxproj` 中钉死了旧版本。

检查三个位置：
1. `CodeAgent.xcodeproj/project.pbxproj` — 搜索 `XCRemoteSwiftPackageReference "AgentKit"`，确认 `kind = branch`
2. `CodeAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — 删除后让 Xcode 重新生成
3. `~/Library/Developer/Xcode/DerivedData/` — 删除 CodeAgent 对应的 DerivedData

## 相关文件索引

| 文件 | 说明 |
|---|---|
| `code-agent/mobile/mobile.go` | gomobile 绑定面 — Server 的 Start/Stop/Suspend/ResumeSession |
| `code-agent/scripts/build-ios.sh` | xcframework 构建脚本 |
| `code-agent/internal/embed/` | 嵌入式运行时实现 |
| `code-agent/build/CodeAgentRuntime.xcframework/` | 构建产物（gitignored） |
| `AgentKit/Package.swift` | binaryTarget 声明 — url + checksum |
| `AgentKit/.gitignore` | `/Frameworks` 已排除，防止本地 xcframework 被误提交 |
| `AgentKit/Sources/AgentKit/Core/AgentRuntime.swift` | iOS 端 Runtime 封装（`#if os(iOS)`） |
| `CodeAgent/CodeAgent.xcodeproj/project.pbxproj` | App 对 AgentKit 的依赖声明 |
