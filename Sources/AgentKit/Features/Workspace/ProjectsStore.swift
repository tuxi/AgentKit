//
//  ProjectsStore.swift
//  AgentKit
//
//  端侧工作区根（Documents）下的「项目」目录管理。
//  与 AgentRuntime 传给 MobileStart 的 workspaceDir 对齐 —— 项目即 Documents 的子目录，
//  内嵌 runtime 对其天然有读写权（无需 security scope），重装后由 runtime 按相对路径 re-anchor。
//
//  macOS：新建项目位于当前用户的 Documents，并在创建后执行 `git init`。
//  任意位置的现有项目仍通过文件夹选择器原地打开。
//

import Foundation

@MainActor
@Observable
public final class ProjectsStore {

    /// 新建项目的根目录。默认为当前用户的 Documents。
    public let root: URL?

    /// 根下的项目子目录（按名称不区分大小写排序）。
    public private(set) var projects: [Workspace] = []

    public init(root: URL? = ProjectsStore.defaultRoot) {
        self.root = root
        reload()
    }

    /// 平台默认根：Documents。iOS 与内嵌 Runtime 的 workspaceDir 一致；
    /// macOS 使用用户可直接在 Finder 中访问的文稿目录。
    public static var defaultRoot: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 是否启用「项目列表」模式（仅在有工作区根时）。
    public var isAvailable: Bool { root != nil }

    // MARK: - Listing

    /// 重新枚举根下的子目录。目录可能被「文件」App 改动（新增/解压/删除），
    /// 故在新建草稿、视图出现、创建项目后调用以保持新鲜。
    public func reload() {
        guard let root else { projects = []; return }
        #if os(macOS)
        // macOS 的 Documents 是用户通用目录，不能把其中每个子目录都当成
        // CodeAgent 项目。新建/打开的项目由 RecentWorkspacesStore 持久化。
        projects = []
        #else
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        projects = urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Workspace(url: $0) }
        #endif
    }

    // MARK: - Creation

    /// 在根下创建新项目目录并返回对应 Workspace。
    /// 若同名路径已存在，依次追加 `1`、`2`……，不覆盖任何现有内容。
    /// macOS 创建后立即执行 `git init`；iOS 仍只创建沙盒目录。
    @discardableResult
    public func createProject(named rawName: String) throws -> Workspace {
        guard let root else { throw ProjectsError.noRoot }
        let name = try Self.validatedName(rawName)
        let dir = Self.uniqueProjectDestination(for: name, in: root)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        #if os(macOS)
        do {
            try Self.initializeGitRepository(at: dir)
        } catch {
            // 该目录是本次操作刚创建的；git 初始化失败时不留下半成品项目。
            try? fm.removeItem(at: dir)
            throw error
        }
        #endif
        reload()
        return Workspace(url: dir)
    }

    /// **copy-in**：把外部文件夹复制进根下、命名为 `rawName`，返回新项目 Workspace。
    /// 源 URL 为 security-scoped（document picker 授予）→ 仅在复制期间临时持有访问权、
    /// 用完即停，**不持久化 bookmark**（这正是 copy-in 相对 in-place 的优势）。
    /// 复制在后台线程执行，避免大目录阻塞 UI。名称冲突时自动加序号（不覆盖）。
    @discardableResult
    public func importProject(from sourceURL: URL, named rawName: String) async throws -> Workspace {
        guard let root else { throw ProjectsError.noRoot }
        let name = try Self.validatedName(rawName)
        let dest = Self.uniqueDestination(for: name, in: root)
        try await Task.detached(priority: .userInitiated) {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        }.value
        reload()
        return Workspace(url: dest)
    }

    /// 为「导入外部文件夹」推荐一个项目名。
    /// iOS 不会把来源 App 名直接给我们（沙盒容器路径是 UUID），故按可靠度回退：
    ///   1) iCloud 容器路径含 `iCloud~com~vendor~App` → 解析出 App 名（最可靠）；
    ///   2) 非通用的 `lastPathComponent`（如已是项目名）；
    ///   3) 父目录名（非 UUID/通用名）；
    ///   4) 回退 "Imported"。
    /// 最终仍由用户在导入弹窗里确认/修改。
    public static func suggestedName(forImporting url: URL) -> String {
        let generic: Set<String> = ["Documents", "Library", "tmp", "Caches", "Mobile Documents"]

        // (1) iCloud 容器：.../Mobile Documents/iCloud~com~apple~Pages/Documents
        if let segment = url.pathComponents.first(where: { $0.hasPrefix("iCloud~") }) {
            let bundleID = segment.dropFirst("iCloud~".count).replacingOccurrences(of: "~", with: ".")
            if let app = bundleID.split(separator: ".").last, !app.isEmpty {
                return String(app)
            }
        }
        // (2) lastPathComponent，若不是通用名
        let last = url.lastPathComponent
        if !last.isEmpty, !generic.contains(last) {
            return last
        }
        // (3) 父目录名，若非 UUID / 通用名
        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, !generic.contains(parent), !looksLikeUUID(parent) {
            return parent
        }
        return "Imported"
    }

    // MARK: - Helpers

    /// 校验项目名：去空白后非空、不含 "/"、不以 "." 开头。
    private static func validatedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw ProjectsError.invalidName
        }
        return name
    }

    /// 形如容器 UUID（36 字符、4 个连字符）→ 不适合当项目名。
    private static func looksLikeUUID(_ s: String) -> Bool {
        s.count == 36 && s.filter { $0 == "-" }.count == 4
    }

    /// 在 root 下为 name 找一个不冲突的目标 URL（已存在则追加 " 2"、" 3"…）。
    private static func uniqueDestination(for name: String, in root: URL) -> URL {
        let fm = FileManager.default
        let base = name.isEmpty ? "Imported" : name
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) \(i)", isDirectory: true)
            i += 1
        }
        return candidate
    }

    /// 空白项目使用无空格数字后缀：Project、Project1、Project2……。
    private static func uniqueProjectDestination(for name: String, in root: URL) -> URL {
        let fm = FileManager.default
        var suffix = 0
        while true {
            let component = suffix == 0 ? name : "\(name)\(suffix)"
            let candidate = root.appendingPathComponent(component, isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    #if os(macOS)
    private static func initializeGitRepository(at directory: URL) throws {
        // App Sandbox 不允许启动 `/usr/bin/git`（该 shim 会转入 xcrun）。
        // 直接生成 Git 定义的最小非 bare 仓库结构，与 `git init -b main`
        // 的持久化结果等价，且不需要子进程或逃离沙盒。
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        let fm = FileManager.default
        do {
            for relativePath in [
                "objects/info",
                "objects/pack",
                "refs/heads",
                "refs/tags",
                "hooks",
                "info",
            ] {
                try fm.createDirectory(
                    at: git.appendingPathComponent(relativePath, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }

            try "ref: refs/heads/main\n".write(
                to: git.appendingPathComponent("HEAD"),
                atomically: true,
                encoding: .utf8
            )
            try """
                [core]
                \trepositoryformatversion = 0
                \tfilemode = true
                \tbare = false
                \tlogallrefupdates = true
                \tignorecase = true
                \tprecomposeunicode = true

                """.write(
                    to: git.appendingPathComponent("config"),
                    atomically: true,
                    encoding: .utf8
                )
            try "Unnamed repository; edit this file 'description' to name the repository.\n".write(
                to: git.appendingPathComponent("description"),
                atomically: true,
                encoding: .utf8
            )
            try "# git ls-files --others --exclude-from=.git/info/exclude\n".write(
                to: git.appendingPathComponent("info/exclude"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw ProjectsError.gitInitializationFailed(error.localizedDescription)
        }
    }
    #endif
}

// MARK: - Errors

public enum ProjectsError: LocalizedError {
    case noRoot
    case invalidName
    case alreadyExists(String)
    case gitInitializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRoot:               return "当前平台没有工作区根目录。"
        case .invalidName:          return "项目名不能为空，且不能包含「/」或以「.」开头。"
        case .alreadyExists(let n): return "项目「\(n)」已存在。"
        case .gitInitializationFailed(let detail): return "无法初始化 Git 仓库：\(detail)"
        }
    }
}
