//
//  SummaryRenderer.swift
//  AgentKit
//
//  P4.4: 运行时 summary 生成器。
//  不存储于 ArtifactNode 模型 — i18n-ready，可在 View 层按需调用。
//

import Foundation

// MARK: - SummaryRenderer

/// 从 `ArtifactNode` 运行时生成 Timeline 展示摘要。
/// 纯函数，不依赖任何状态。
public struct SummaryRenderer {

    /// 生成人类可读的 Timeline 摘要。
    /// 示例：
    /// - "Read config.json (42 lines)"
    /// - "Created main.swift (15 lines)"
    /// - "Edited skill-model.md +3 -1"
    /// - "Ran ls -la"
    /// - "Ran npm test (exit 1)"
    public static func summary(for node: ArtifactNode) -> String {
        let fileName = node.path.map { ($0 as NSString).lastPathComponent } ?? "file"

        switch (node.kind, node.content) {
        case (.listFiles, .file(let p)):
            let count = p.content.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
            let dirName = node.path.map { ($0 as NSString).lastPathComponent } ?? "."
            return "Listed \(count) files in \(dirName)/"

        case (.fileRead, .file(let p)):
            let lines = p.content.components(separatedBy: "\n").count
            return "Read \(fileName) (\(lines) lines)"

        case (.fileCreated, .file(let p)):
            let lines = p.content.components(separatedBy: "\n").count
            return "Created \(fileName) (\(lines) lines)"

        case (.fileEdited, .diff(let p)):
            let added = p.addedLines
            let removed = p.removedLines
            var parts: [String] = []
            if added > 0 { parts.append("+\(added)") }
            if removed > 0 { parts.append("-\(removed)") }
            let delta = parts.isEmpty ? "" : " \(parts.joined(separator: " "))"
            return "Edited \(fileName)\(delta)"

        case (.fileEdited, .file(let p)):
            let lines = p.content.components(separatedBy: "\n").count
            return "Edited \(fileName) (\(lines) lines)"

        case (.commandRun, .terminal(let p)):
            let cmd = p.command
            let shortCmd = cmd.count > 40 ? String(cmd.prefix(40)) + "…" : cmd
            if let code = p.exitCode, code != 0 {
                return "Ran \(shortCmd) (exit \(code))"
            }
            return "Ran \(shortCmd)"
        default:
            return node.kind.rawValue
        }
    }
}
