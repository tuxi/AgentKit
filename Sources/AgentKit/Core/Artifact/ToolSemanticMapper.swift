//
//  ToolSemanticMapper.swift
//  AgentKit
//
//  P4.4: Semantic compiler — 将 raw ToolCallItem 编译为 Work Product。
//  Metadata First + Observation Fallback。
//  输出双 kind：WorkProductKind（语义）+ ArtifactKind（渲染）。
//

import Foundation

// MARK: - ToolSemanticCompiler

public struct ToolSemanticCompiler {

    /// 编译 Work Product。
    public static func compile(_ tool: ToolCallItem, turnID: String) -> ArtifactNode? {
        guard tool.status == .completed || tool.status == .failed else { return nil }
        guard let kind = determineKind(toolName: tool.toolName) else { return nil }

        let renderKind = inferRenderKind(kind: kind, tool: tool)
        let path = extractFilePath(from: tool)
        let content = buildContent(tool: tool, kind: kind, renderKind: renderKind)
        guard let content else { return nil }

        return ArtifactNode(
            callID: tool.callID,
            turnID: turnID,
            kind: kind,
            renderKind: renderKind,
            path: path,
            content: content
        )
    }

    // MARK: - Kind → WorkProductKind

    private static func determineKind(toolName: String) -> WorkProductKind? {
        let name = toolName.lowercased()
        
        let listPatterns = ["list_files"]
        for p in listPatterns where name.contains(p) {
            return .listFiles
        }

        let createPatterns = ["create", "new"]
        for p in createPatterns where name.contains(p) {
            return .fileCreated
        }

        let writePatterns = ["write", "edit", "patch", "apply", "save"]
        for p in writePatterns where name.contains(p) {
            return .fileEdited
        }

        let readPatterns = ["read", "cat", "view", "open", "get", "list"]
        for p in readPatterns where name.contains(p) {
            return .fileRead
        }

        let termPatterns = ["bash", "shell", "exec", "terminal", "run", "cmd"]
        for p in termPatterns where name.contains(p) {
            return .commandRun
        }

        return nil
    }

    // MARK: - Render kind inference

    private static func inferRenderKind(kind: WorkProductKind, tool: ToolCallItem) -> ArtifactKind {
        switch kind {
        case .listFiles:
            return .files
        case .fileEdited:
            // Check if observation looks like a diff
            let obs = tool.result?.observation ?? ""
            if obs.contains("@@") && (obs.contains("+") || obs.contains("-")) {
                return .diff
            }
            return .file
        case .fileCreated, .fileRead:
            return .file
        case .commandRun:
            return .terminal
        }
    }

    // MARK: - Content construction

    private static func buildContent(tool: ToolCallItem, kind: WorkProductKind, renderKind: ArtifactKind) -> ArtifactContent? {
        switch renderKind {
        case .diff:
            let path = extractFilePath(from: tool)
            let diffContent = tool.result?.observation ?? ""
            let (added, removed) = countDiffLines(diffContent)
            return .diff(DiffPayload(filePath: path, diffContent: diffContent, addedLines: added, removedLines: removed))
        case .file:
            let path = extractFilePath(from: tool) ?? "unknown"
            let content = tool.result?.observation ?? ""
            let language = extractLanguage(from: tool, filePath: path)
            let isNew = (kind == .fileCreated)
            return .file(FilePayload(filePath: path, content: content, language: language, isNew: isNew))
        case .files:
            let path = extractFilePath(from: tool) ?? "unknown"
            let content = tool.result?.observation ?? ""
            let language = extractLanguage(from: tool, filePath: path)
            let isNew = (kind == .fileCreated)
            return .file(FilePayload(filePath: path, content: content, language: language, isNew: isNew))
        case .terminal:
            let command = extractCommand(from: tool) ?? "unknown"
            let output = tool.result?.observation ?? ""
            let exitCode = extractExitCode(from: tool)
            return .terminal(TerminalPayload(command: command, output: output, exitCode: exitCode))
        }
    }

    // MARK: - Diff line counting

    private static func countDiffLines(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    // MARK: - Field extractors

    private static func extractFilePath(from tool: ToolCallItem) -> String? {
        if let args = tool.toolArgs {
            for key in ["file_path", "path", "file", "target"] {
                let v = args[key].stringValue
                if !v.isEmpty { return v }
            }
        }
        if let obs = tool.result?.observation {
            return parseFilePathFromObservation(obs)
        }
        return nil
    }

    private static func extractCommand(from tool: ToolCallItem) -> String? {
        if let args = tool.toolArgs {
            for key in ["command", "cmd"] {
                let v = args[key].stringValue
                if !v.isEmpty { return v }
            }
        }
        if let obs = tool.result?.observation {
            return parseCommandFromObservation(obs)
        }
        return nil
    }

    private static func extractLanguage(from tool: ToolCallItem, filePath: String) -> String? {
        if let args = tool.toolArgs {
            let lang = args["language"].stringValue
            if !lang.isEmpty { return lang }
        }
        return inferLanguage(from: filePath)
    }

    private static func extractExitCode(from tool: ToolCallItem) -> Int? {
        if let args = tool.toolArgs {
            let code = args["exit_code"].intValue
            if code != 0 || args["exit_code"].stringValue == "0" { return code }
        }
        if let obs = tool.result?.observation {
            return parseExitCodeFromObservation(obs)
        }
        return nil
    }

    // MARK: - Observation fallback parsers

    private static func parseFilePathFromObservation(_ obs: String) -> String? {
        let patterns = [
            #"^\+\+\+ b/(.+)$"#,
            #"^--- a/(.+)$"#,
            #"^(?:File|Path):\s*(.+)$"#,
            #"^#+\s*(.+\.\w+)"#,
        ]
        for p in patterns {
            if let m = obs.firstMatch(for: p) { return m }
        }
        return nil
    }

    private static func parseCommandFromObservation(_ obs: String) -> String? {
        if let m = obs.firstMatch(for: #"^\$\s+(.+)$"#) { return m }
        let firstLine = obs.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
        if let line = firstLine, !line.isEmpty, line.count < 200 { return line }
        return nil
    }

    private static func parseExitCodeFromObservation(_ obs: String) -> Int? {
        for p in [#"exit(?:\s*code)?[:\s]*(\d+)"#, #"exited with (\d+)"#, #"\[exit[:\s]*(\d+)\]"#] {
            if let m = obs.firstMatch(for: p) { return Int(m) }
        }
        return nil
    }

    private static func inferLanguage(from filePath: String) -> String? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "swift": "swift", "m": "objc", "h": "objc",
            "py": "python", "js": "javascript", "ts": "typescript",
            "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
            "c": "c", "cpp": "cpp", "hpp": "cpp",
            "rb": "ruby", "php": "php", "sh": "bash", "bash": "bash",
            "yaml": "yaml", "yml": "yaml", "json": "json", "xml": "xml",
            "md": "markdown", "sql": "sql",
            "html": "html", "css": "css", "scss": "scss",
        ]
        return map[ext] ?? (ext.isEmpty ? nil : ext)
    }
}

// MARK: - Regex helper

private extension String {
    func firstMatch(for pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
