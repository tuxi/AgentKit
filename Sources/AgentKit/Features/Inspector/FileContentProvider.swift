//
//  FileContentProvider.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import Foundation

/// Diff 内容
public struct DiffContent {
    public let original: String
    public let modified: String
    public let hunks: [DiffHunk]

    public init(original: String, modified: String, hunks: [DiffHunk] = []) {
        self.original = original
        self.modified = modified
        self.hunks = hunks
    }
}

/// Diff 块
public struct DiffHunk: Identifiable, Sendable {
    public let id: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public init(
        id: String = UUID().uuidString,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine] = []
    ) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

/// Diff 行
public enum DiffLine: Sendable {
    case unchanged(String)
    case added(String)
    case removed(String)
}

/// 文件内容提供者协议。
/// 由宿主（Talkify）实现，注入到 InspectorNavigationView 以支持文件预览和 diff 对比。
public protocol FileContentProvider: AnyObject, Sendable {
    /// 读取文件内容
    func content(for filePath: String) async throws -> String

    /// 读取文件变更对比
    func changes(for filePath: String, baseRef: String?) async throws -> DiffContent?
}
