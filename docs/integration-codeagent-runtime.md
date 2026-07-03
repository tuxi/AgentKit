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
       │  mobile/mobile.go  ──gomobile bind──▶ xcframework
       │  GitHub Release: zip + checksum          │
       └──────────────────────────────────────────┘
```

## 仓库与职责

| 仓库 | 职责 | 关键文件 |
|---|---|---|
| `tuxi/code-agent` | Go 源码 + gomobile 构建 + 发布 xcframework | `mobile/mobile.go`, `scripts/build-ios.sh` |
| `tuxi/AgentKit` | Swift Package，通过 `binaryTarget(url:)` 引用 xcframework | `Package.swift` |
| `CodeAgent` | App 项目，依赖 AgentKit | `project.pbxproj` |

## 构建流程

### 1. Go 源码 → xcframework

在 `code-agent` 仓库中运行：

```bash
# 前置条件：Go 1.25+、Xcode
# 脚本会自动安装 gomobile + gobind（如果未安装）
./scripts/build-ios.sh
```

脚本做了什么：

1. **gomobile init** — 初始化 gomobile 工具链
2. **gomobile bind** — 将 `./mobile` Go 包编译为 xcframework
   - `-target=ios,iossimulator` — 输出真机 + 模拟器两个 slice
   - `-iosversion=15.0` — 设置 MinimumOSVersion
3. **normalize Info.plist** — 确保每个内部 framework 的 `MinimumOSVersion` 为 15.0
4. **打包 skills** — 将内置 skills 复制到 `build/skills/`

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

### 2. xcframework → zip → GitHub Release

```bash
# 打包（macOS 下需要 -y 保留符号链接）
cd build
zip -r -y CodeAgentRuntime.xcframework.zip CodeAgentRuntime.xcframework/

# 计算 checksum
swift package compute-checksum CodeAgentRuntime.xcframework.zip
# 输出示例：aaac9eace1aa812e5dc972a711fbf4e2093a48297fff5b0f19ad604b5bfe8b4d

# 创建 Release 并上传
VERSION="0.2.0"   # 按需修改版本号
gh release create "$VERSION" \
  --title "v$VERSION" \
  --notes "CodeAgentRuntime.xcframework — gomobile bind from ./mobile" \
  CodeAgentRuntime.xcframework.zip
```

> **注意**：Release 创建在 `tuxi/code-agent` 仓库，而非 AgentKit。二进制产物的版本与其源码仓库一致。

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

### 为什么 Release 放在 code-agent 仓库而非 AgentKit？

关注点分离：
- **code-agent**：Go 源码的所有者，负责编译和发布
- **AgentKit**：纯 Swift 消费者，通过 URL 引用

这样 Go 代码的版本、Release Note、构建历史都在同一个仓库，不需要跨仓库搬运二进制。

## 更新 Runtime 的标准流程

当 Go 代码（`mobile/mobile.go` 或 `internal/embed`）变更后：

```bash
# 1. 构建
cd code-agent
./scripts/build-ios.sh

# 2. 打包 + checksum
cd build
zip -r -y CodeAgentRuntime.xcframework.zip CodeAgentRuntime.xcframework/
swift package compute-checksum CodeAgentRuntime.xcframework.zip

# 3. 发 Release
VERSION="0.2.0"  # 遵循语义化版本
git tag "$VERSION"
git push origin "$VERSION"
gh release create "$VERSION" \
  --title "v$VERSION" \
  --notes "$(cat <<EOF
## Changes

- <描述这次 Go 侧的改动>
- <对 iOS 端的影响>

**xcframework built via:** \`gomobile bind -target=ios,iossimulator\`
EOF
)" \
  CodeAgentRuntime.xcframework.zip

# 4. 更新 AgentKit
cd ../AgentKit
# 手动编辑 Package.swift，更新 url 和 checksum
git add Package.swift
git commit -m "chore: bump CodeAgentRuntime to $VERSION"
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
| `AgentKit/Sources/AgentKit/Core/AgentRuntime.swift` | iOS 端 Runtime 封装（`#if os(iOS)`） |
| `CodeAgent/CodeAgent.xcodeproj/project.pbxproj` | App 对 AgentKit 的依赖声明 |
