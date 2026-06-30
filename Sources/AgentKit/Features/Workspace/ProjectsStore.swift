//
//  ProjectsStore.swift
//  AgentKit
//
//  端侧工作区根（iOS = 沙盒 Documents）下的「项目」目录管理。
//  与 AgentRuntime 传给 MobileStart 的 workspaceDir 对齐 —— 项目即 Documents 的子目录，
//  内嵌 runtime 对其天然有读写权（无需 security scope），重装后由 runtime 按相对路径 re-anchor。
//
//  macOS：无单一工作区根（root == nil）→ isAvailable == false，沿用任意文件夹选择。
//

import Foundation

@MainActor
@Observable
public final class ProjectsStore {

    /// 工作区根目录。iOS = Documents；macOS = nil（表示用任意文件夹选择，不走项目列表）。
    public let root: URL?

    /// 根下的项目子目录（按名称不区分大小写排序）。
    public private(set) var projects: [Workspace] = []

    public init(root: URL? = ProjectsStore.defaultRoot) {
        self.root = root
        reload()
    }

    /// 平台默认根：iOS 取 Documents，与 runtime 的 workspaceDir 一致。
    public static var defaultRoot: URL? {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #else
        return nil
        #endif
    }

    /// 是否启用「项目列表」模式（仅在有工作区根时）。
    public var isAvailable: Bool { root != nil }

    // MARK: - Listing

    /// 重新枚举根下的子目录。目录可能被「文件」App 改动（新增/解压/删除），
    /// 故在新建草稿、视图出现、创建项目后调用以保持新鲜。
    public func reload() {
        guard let root else { projects = []; return }
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
    }

    // MARK: - Creation

    /// 在根下创建新项目目录并返回对应 Workspace。
    /// 名称非法 / 已存在 / 无根 时抛 `ProjectsError`。
    @discardableResult
    public func createProject(named rawName: String) throws -> Workspace {
        guard let root else { throw ProjectsError.noRoot }
        let name = try Self.validatedName(rawName)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw ProjectsError.alreadyExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
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
}

// MARK: - Errors

public enum ProjectsError: LocalizedError {
    case noRoot
    case invalidName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .noRoot:               return "当前平台没有工作区根目录。"
        case .invalidName:          return "项目名不能为空，且不能包含「/」或以「.」开头。"
        case .alreadyExists(let n): return "项目「\(n)」已存在。"
        }
    }
}
