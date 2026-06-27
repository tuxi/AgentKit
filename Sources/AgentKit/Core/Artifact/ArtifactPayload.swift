//
//  ArtifactPayload.swift
//  AgentKit
//
//  Artifact 的强类型 payload — 每种 kind 对应一个结构化数据。
//  使用 enum + associated value 而非 protocol，避免 type erasure 和 protocol explosion。
//

import Foundation

// MARK: - ArtifactContent

/// Artifact 的类型化内容 — v4 中 Artifact 是唯一的 UI 语义输出层。
/// 由 `ToolSemanticCompiler` 从 `ToolCallItem` 编译并结构化。
public enum ArtifactContent: Sendable, Hashable {
    case diff(DiffPayload)
    case file(FilePayload)
    case terminal(TerminalPayload)
}

// MARK: - DiffPayload

/// Diff/patch/edit 类工具的结构化产出。
public struct DiffPayload: Sendable, Hashable {
    /// 目标文件路径（可能为空，如纯 diff 输出）。
    public let filePath: String?
    /// diff 内容（unified diff 或 patch 文本）。
    public let diffContent: String
    /// 新增行数（从 diff 统计，P4.4 用于 summary 生成）。
    public let addedLines: Int
    /// 删除行数（从 diff 统计，P4.4 用于 summary 生成）。
    public let removedLines: Int

    public init(filePath: String?, diffContent: String, addedLines: Int = 0, removedLines: Int = 0) {
        self.filePath = filePath
        self.diffContent = diffContent
        self.addedLines = addedLines
        self.removedLines = removedLines
    }
}

// MARK: - FilePayload

/// 文件读取/创建类工具的结构化产出。
public struct FilePayload: Sendable, Hashable {
    /// 文件路径。
    public let filePath: String
    /// 文件内容。
    public let content: String
    /// 语言标识（如 "swift"、"python"），可缺省。
    public let language: String?
    /// 是否为新建文件（P4.4: 用于区分 fileCreated vs fileRead）。
    public let isNew: Bool

    public init(filePath: String, content: String, language: String?, isNew: Bool = false) {
        self.filePath = filePath
        self.content = content
        self.language = language
        self.isNew = isNew
    }
}

// MARK: - TerminalPayload

/// 终端命令的结构化产出。
public struct TerminalPayload: Sendable, Hashable {
    /// 执行的命令。
    public let command: String
    /// 终端输出文本。
    public let output: String
    /// 退出码（nil 表示无法确定）。
    public let exitCode: Int?

    public init(command: String, output: String, exitCode: Int?) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
    }
}
