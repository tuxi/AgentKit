//
//  RecentWorkspacesStore.swift
//  AgentKit
//
//  P5.0 — 最近打开的工作区。以 security-scoped bookmark 持久化到 UserDefaults，
//  这样重启 App（以及未来开启沙盒后）仍保有目录访问权限。
//

import Foundation

@MainActor
@Observable
public final class RecentWorkspacesStore {

    /// 最近使用的工作区，最新在前。
    public private(set) var workspaces: [Workspace] = []

    /// 最近一次使用的工作区（用于新建草稿时预选）。
    public var mostRecent: Workspace? { workspaces.first }

    private let defaults: UserDefaults
    private let key = "code_agent.recent_workspaces.bookmarks"
    private let maxCount = 8

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    /// 标记一个工作区为「刚使用」：移到队首并持久化。
    public func touch(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.insert(workspace, at: 0)
        if workspaces.count > maxCount {
            workspaces = Array(workspaces.prefix(maxCount))
        }
        persist()
    }

    /// 从持久化的 bookmark 恢复列表。
    public func load() {
        guard let datas = defaults.array(forKey: key) as? [Data] else {
            workspaces = []
            return
        }
        workspaces = datas.compactMap { Self.resolveBookmark($0) }
    }

    // MARK: - Persistence

    private func persist() {
        let datas = workspaces.compactMap { Self.makeBookmark(for: $0.url) }
        defaults.set(datas, forKey: key)
    }

    private static func makeBookmark(for url: URL) -> Data? {
        #if os(macOS)
        // 沙盒应用用 security-scoped bookmark；非沙盒（开发态）会失败，回退到普通 bookmark。
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        #endif
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolveBookmark(_ data: Data) -> Workspace? {
        var isStale = false
        #if os(macOS)
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return Workspace(url: url)
        }
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return Workspace(url: url)
    }
}
