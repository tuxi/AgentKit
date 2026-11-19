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
    private var bookmarks: [URL: Data] = [:]
    private var bookmarkTask: Task<Void, Never>?

    /// 当前持有 security scope 的目录（path → url）。
    /// iOS：从 document picker / bookmark 取得的「沙盒外」目录需在访问期间持有 scope，
    /// 否则内嵌 runtime（同进程）无权读写。沙盒内目录（Documents 子目录）`start` 返回
    /// false → 不计入、无需释放。生命周期与 recents 列表对齐：进入即 begin，被挤出即 end。
    private var heldScopes: [String: URL] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    /// 取得并持有对该目录的 security-scoped 访问（幂等）。
    /// 沙盒内目录无需 scope（`start` 返回 false）→ 静默忽略、不计入 `heldScopes`。
    /// 导入新目录时由 `WorkspaceChipBar` 先行调用，使 `Workspace.init` 能读取 `.git/HEAD`。
    public func beginAccess(to url: URL) {
        let path = url.path
        guard heldScopes[path] == nil else { return }   // 已持有 → 幂等
        if url.startAccessingSecurityScopedResource() {
            heldScopes[path] = url
        }
    }

    /// 释放对某 path 的 scope（若持有）。
    private func endAccess(_ path: String) {
        guard let url = heldScopes.removeValue(forKey: path) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    /// 标记一个工作区为「刚使用」：移到队首并持久化。
    public func touch(_ workspace: Workspace) {
        beginAccess(to: workspace.url)
        let updated = [workspace] + workspaces.filter { $0.id != workspace.id }
        for evicted in updated.dropFirst(maxCount) { endAccess(evicted.id) }
        let retained = Array(updated.prefix(maxCount))
        if workspaces != retained { workspaces = retained }
        persist()
    }

    /// 从持久化的 bookmark 恢复列表，并为每个恢复的目录重新取得 scope。
    /// 关键：bookmark 解析得到的是 security-scoped URL，必须重新 `startAccessing…`，
    /// 否则重启后 recents 虽在列表里却无访问权（旧实现遗漏了这一步）。
    public func load() {
        bookmarks.removeAll()
        guard let datas = defaults.array(forKey: key) as? [Data] else {
            workspaces = []
            return
        }
        // A security-scoped URL is not readable until access has started. Resolve
        // and acquire each URL before constructing Workspace, because Workspace.init
        // probes `.git/HEAD` to decide whether managed worktree creation is available.
        // The previous order constructed Workspace first, so every restored sandboxed
        // Git project lost its branch and the Worktree control disappeared from drafts.
        workspaces = datas.compactMap { data in
            guard let (url, isStale) = Self.resolveBookmarkURL(data) else { return nil }
            if !isStale { bookmarks[url] = data }
            beginAccess(to: url)
            return Workspace(url: url)
        }
    }

    // MARK: - Persistence

    private func persist() {
        let urls = workspaces.map(\.url)
        let retained = Set(urls)
        bookmarks = bookmarks.filter { retained.contains($0.key) }
        let missing = urls.filter { bookmarks[$0] == nil }
        guard !missing.isEmpty else {
            defaults.set(urls.compactMap { bookmarks[$0] }, forKey: key)
            return
        }
        guard bookmarkTask == nil else { return }

        // A bookmark may involve disk access or security-scoped services. Reordering
        // existing bookmarks is immediate, and only previously unseen URLs need I/O.
        bookmarkTask = Task { [weak self] in
            let created = await Task.detached(priority: .utility) {
                var data: [URL: Data] = [:]
                for url in missing {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    data[url] = Self.makeBookmark(for: url)
                }
                return data
            }.value
            guard let self else { return }
            bookmarkTask = nil
            let current = workspaces.map(\.url)
            for url in current where bookmarks[url] == nil {
                bookmarks[url] = created[url]
            }
            defaults.set(current.compactMap { bookmarks[$0] }, forKey: key)
            let attempted = Set(missing)
            if current.contains(where: { bookmarks[$0] == nil && !attempted.contains($0) }) {
                persist()
            }
        }
    }

    private nonisolated static func makeBookmark(for url: URL) -> Data? {
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

    private static func resolveBookmarkURL(_ data: Data) -> (URL, Bool)? {
        var isStale = false
        #if os(macOS)
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, isStale)
        }
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url, isStale)
    }
}
