//
//  WorkProductKind.swift
//  AgentKit
//
//  P4.4: Work Product 语义分类 — 以"工作成果"而非"工具类型"为视角。
//  对照 Claude Code: fileEdited, fileCreated, commandRun...
//

import Foundation

// MARK: - WorkProductKind

/// Work Product 的种类，描述"用户得到了什么"，而非"用了什么工具"。
/// 由 `ToolSemanticCompiler` 从 toolName + toolArgs 推导。
public enum WorkProductKind: String, Sendable, Hashable, CaseIterable {
    // 查看目录
    case listFiles
    /// 读取文件内容（read_file 等）
    case fileRead
    /// 创建新文件（write_file 创建新文件）
    case fileCreated
    /// 编辑已有文件（write_file/edit 修改已有文件）
    case fileEdited
    /// 终端命令执行
    case commandRun
}
