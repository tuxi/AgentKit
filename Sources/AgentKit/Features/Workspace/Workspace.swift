//
//  Workspace.swift
//  AgentKit
//
//  P5.0 — Session 的绑定上下文。一个 Workspace 永远对应磁盘上的真实目录，
//  在 Session 生命周期内不可变（immutable binding）。
//

import Foundation

/// 工作区：Session 的绑定上下文。
/// `url` 是用户选中的真实目录；`branch` 为尽力而为的 git 分支（读 `.git/HEAD`）。
public struct Workspace: Identifiable, Hashable, Sendable {

    /// 以路径作为稳定标识（同一目录视为同一 workspace）。
    public var id: String { url.path }

    /// 真实磁盘目录。
    public let url: URL

    /// 尽力而为读取的 git 分支名（无 git 仓库时为 nil）。
    public var branch: String?

    public init(url: URL, branch: String? = nil) {
        self.url = url
        self.branch = branch ?? Workspace.resolveBranch(at: url)
    }

    /// 目录显示名（最后一段路径）。
    public var name: String { url.lastPathComponent }

    // MARK: - Git branch (best-effort)

    /// 读取 `<url>/.git/HEAD` 解析当前分支名。
    /// - `ref: refs/heads/<branch>` → `<branch>`
    /// - detached HEAD（直接是 commit hash）→ 取前 7 位
    /// - 无 `.git/HEAD` → nil
    public static func resolveBranch(at url: URL) -> String? {
        let head = url.appendingPathComponent(".git/HEAD")
        guard let raw = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = line.range(of: "refs/heads/") {
            return String(line[range.upperBound...])
        }
        // detached HEAD：直接是 commit hash
        return line.isEmpty ? nil : String(line.prefix(7))
    }
}
