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
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw ProjectsError.invalidName
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw ProjectsError.alreadyExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        reload()
        return Workspace(url: dir)
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
