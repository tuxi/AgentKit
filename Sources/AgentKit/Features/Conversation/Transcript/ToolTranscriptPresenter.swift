//
//  ToolTranscriptPresenter.swift
//  AgentKit
//
//  Turns raw tool payloads into compact transcript presentation text.
//

import Foundation

struct ToolTranscriptPresentation: Hashable {
    let callID: String
    let family: ToolTranscriptFamily
    let statusTone: ToolTranscriptStatusTone
    let statusText: String?
    let title: String
    let detail: String?
    let elapsed: String?
    let changeSummary: String?
    let outputKind: ToolTranscriptOutputKind

    var compactLine: String {
        var parts = [title]
        if let changeSummary {
            parts.append(changeSummary)
        }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if let statusText {
            parts.append(statusText)
        }
        if let elapsed {
            parts.append(elapsed)
        }
        return parts.joined(separator: "  ")
    }
}

struct ToolTranscriptGroupPresentation: Hashable {
    let callID: String
    let summary: String
    let statusTone: ToolTranscriptStatusTone
    let tools: [ToolTranscriptPresentation]
}

enum ToolTranscriptFamily: Hashable {
    case read
    case list
    case search
    case create
    case edit
    case terminal
    case projectGraph
    case git
    case skill
    case web
    case other
}

enum ToolTranscriptStatusTone: Hashable {
    case completed
    case running
    case failed
    case autoApproved
}

enum ToolTranscriptOutputKind: Hashable {
    case text
    case diff
    case json
    case code(language: String)
    case terminal
}

enum ToolTranscriptPresenter {

    static func presentation(for tool: ToolNodePayload) -> ToolTranscriptPresentation {
        // P8.7 — job_wait 是"阻塞等待后台任务"的专用工具，
        // 长时间 running 是常态，给专属文案避免被读成卡死。
        if tool.toolName == "job_wait" {
            return jobWaitPresentation(for: tool)
        }
        // task 委派卡：prompt 含 "/" 会被通用路径缩写截成尾巴（"directories."），
        // 给专属形态。后端把 task_started bracket 接进父流后，childStream 入口卡
        // 是主形态，这张普通卡仍并存 —— 届时考虑在投影层合并二者。
        if tool.toolName == "task" {
            return taskPresentation(for: tool)
        }
        let family = family(for: tool)
        let target = targetValue(for: tool)
        let displayTarget = target.map(shortDisplayName)

        return ToolTranscriptPresentation(
            callID: tool.callID,
            family: family,
            statusTone: statusTone(for: tool),
            statusText: statusText(for: tool),
            title: title(for: family, target: displayTarget, tool: tool),
            detail: detail(for: family, target: target, tool: tool),
            elapsed: tool.elapsedMs.map(formatElapsed),
            changeSummary: changeSummary(for: tool),
            outputKind: outputKind(for: tool, family: family)
        )
    }

    static func groupPresentation(for group: ToolGroup) -> ToolTranscriptGroupPresentation {
        let tools = group.tools.map(presentation(for:))
        return ToolTranscriptGroupPresentation(
            callID: group.id,
            summary: groupSummary(for: tools),
            statusTone: groupStatusTone(for: tools),
            tools: tools
        )
    }

    private static func jobWaitPresentation(for tool: ToolNodePayload) -> ToolTranscriptPresentation {
        let jobID: String? = {
            if case .object(let dict)? = tool.args {
                return dict["job_id"]?.stringValue.nilIfEmpty
            }
            return nil
        }()
        return ToolTranscriptPresentation(
            callID: tool.callID,
            family: .other,
            statusTone: statusTone(for: tool),
            statusText: tool.status == .running ? "waiting" : statusText(for: tool),
            title: "Waiting for background job",
            detail: jobID,
            elapsed: tool.elapsedMs.map(formatElapsed),
            changeSummary: nil,
            outputKind: .text
        )
    }

    private static func taskPresentation(for tool: ToolNodePayload) -> ToolTranscriptPresentation {
        let prompt: String? = {
            if case .object(let dict)? = tool.args {
                return dict["prompt"]?.stringValue.nilIfEmpty
                    ?? dict["task"]?.stringValue.nilIfEmpty
            }
            return nil
        }()
        let detail = prompt.map { p -> String in
            let firstLine = p.components(separatedBy: "\n").first ?? p
            return firstLine.count > 60 ? String(firstLine.prefix(57)) + "..." : firstLine
        }
        return ToolTranscriptPresentation(
            callID: tool.callID,
            family: .other,
            statusTone: statusTone(for: tool),
            statusText: statusText(for: tool),
            title: "Subagent",
            detail: detail,
            elapsed: tool.elapsedMs.map(formatElapsed),
            changeSummary: nil,
            outputKind: .text
        )
    }

    private static func title(for family: ToolTranscriptFamily, target: String?, tool: ToolNodePayload) -> String {
        if family == .git {
            return "Git \(titleize(tool.toolName.replacingOccurrences(of: "git_", with: "")))"
        }
        if family == .web {
            let verb = titleize(tool.toolName.replacingOccurrences(of: "web_", with: ""))
            if let target, !target.isEmpty {
                return "Web \(verb.lowercased()): \(target)"
            }
            return "Web \(verb)"
        }
        if let target, !target.isEmpty {
            return "\(verb(for: family)) \(target)"
        }
        return verb(for: family, fallback: titleize(tool.toolName))
    }

    private static func detail(for family: ToolTranscriptFamily, target: String?, tool: ToolNodePayload) -> String? {
        switch family {
        case .terminal, .git, .skill:
            return nil
        case .search:
            return nil
        default:
            guard let target, shortDisplayName(target) != target else { return nil }
            return target
        }
    }

    private static func outputKind(for tool: ToolNodePayload, family: ToolTranscriptFamily) -> ToolTranscriptOutputKind {
        if looksLikeDiff(tool.output) {
            return .diff
        }
        if case .object = tool.args {
            if tool.toolName.lowercased().contains("json") {
                return .json
            }
        }
        switch family {
        case .terminal:
            return .terminal
        case .read, .create, .edit:
            if let artifact = tool.artifact {
                switch artifact.content {
                case .file(let payload):
                    if let language = payload.language, !language.isEmpty {
                        return .code(language: language)
                    }
                case .directory:
                    return .text
                case .diff:
                    return .diff
                case .terminal:
                    return .terminal
                }
            }
            return .text
        default:
            return .text
        }
    }

    private static func family(for tool: ToolNodePayload) -> ToolTranscriptFamily {
        let name = tool.toolName.lowercased()
        if name.contains("read") || name.contains("cat") || name.contains("view") || name.contains("open") || name.contains("get") {
            return .read
        }
        if name.contains("list") || name.contains("ls") { 
            return .list
        }
        if name.hasPrefix("web_") || name.hasPrefix("web.") {
            return .web
        }
        if name.contains("grep") || name.contains("search") || name.contains("find") || name == "rg" {
            return .search
        }
        if name.contains("write") || name.contains("create") || name.contains("new") {
            return .create
        }
        if name.contains("edit") || name.contains("patch") || name.contains("apply") || name.contains("save") {
            return .edit
        }
        if name.contains("bash") || name.contains("shell") || name.contains("exec") || name.contains("terminal") || name.contains("run") || name.contains("cmd") {
            return .terminal
        }
        if name.contains("project_graph") {
            return .projectGraph
        }
        if name.contains("git") {
            return .git
        }
        if name.contains("load_skill") || name.contains("skill") {
            return .skill
        }
        return .other
    }

    private static func targetValue(for tool: ToolNodePayload) -> String? {
        guard case .object(let dict)? = tool.args else {
            return tool.argsSummary.nilIfEmpty
        }
        let preferred = ["file_path", "path", "file", "target", "command", "cmd", "query", "pattern", "url", "name"]
        for key in preferred {
            if let value = dict[key]?.stringValue.nilIfEmpty {
                return value
            }
        }
        for key in dict.keys.sorted() {
            if let value = dict[key]?.stringValue.nilIfEmpty {
                return value
            }
        }
        return tool.argsSummary.nilIfEmpty
    }

    private static func statusTone(for tool: ToolNodePayload) -> ToolTranscriptStatusTone {
        if tool.isAutoApproved { return .autoApproved }
        switch tool.status {
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .autoApproved: return .autoApproved
        }
    }

    private static func statusText(for tool: ToolNodePayload) -> String? {
        if tool.isAutoApproved { return "auto" }
        switch tool.status {
        case .running:
            return "running"
        case .completed:
            return nil
        case .failed:
            if let exitCode = tool.exitCode {
                return "failed \(exitCode)"
            }
            return "failed"
        case .autoApproved:
            return "auto"
        }
    }

    private static func verb(for family: ToolTranscriptFamily, fallback: String = "Use tool") -> String {
        switch family {
        case .read: return "Read"
        case .list: return "List"
        case .search: return "Search"
        case .create: return "Create"
        case .edit: return "Edit"
        case .terminal: return "Run"
        case .projectGraph: return "Query"
        case .git: return "Git"
        case .skill: return "Load skill"
        case .web: return "Search web"
        case .other: return fallback
        }
    }

    private static func noun(for family: ToolTranscriptFamily, count: Int) -> String {
        switch family {
        case .read: return count == 1 ? "file" : "files"
        case .list: return count == 1 ? "directory" : "directories"
        case .search: return count == 1 ? "search" : "searches"
        case .create: return count == 1 ? "file" : "files"
        case .edit: return count == 1 ? "file" : "files"
        case .terminal: return count == 1 ? "command" : "commands"
        case .projectGraph: return count == 1 ? "query" : "queries"
        case .git: return count == 1 ? "operation" : "operations"
        case .skill: return count == 1 ? "skill" : "skills"
        case .web: return count == 1 ? "search" : "searches"
        case .other: return count == 1 ? "tool" : "tools"
        }
    }

    private static func groupSummary(for tools: [ToolTranscriptPresentation]) -> String {
        guard !tools.isEmpty else { return "" }
        if tools.count == 1 {
            return tools[0].title
        }

        var orderedFamilies: [ToolTranscriptFamily] = []
        var counts: [ToolTranscriptFamily: Int] = [:]
        for tool in tools {
            if counts[tool.family] == nil {
                orderedFamilies.append(tool.family)
            }
            counts[tool.family, default: 0] += 1
        }

        let phrases = orderedFamilies.map { family -> String in
            familySummaryPhrase(family, count: counts[family, default: 0])
        }
        guard let first = phrases.first else { return "" }
        return ([first.capitalizedFirst] + phrases.dropFirst()).joined(separator: ", ")
    }

    private static func familySummaryPhrase(_ family: ToolTranscriptFamily, count: Int) -> String {
        switch family {
        case .read:
            return count == 1 ? "read a file" : "read \(count) files"
        case .list:
            return count == 1 ? "listed a directory" : "listed \(count) directories"
        case .search:
            return count == 1 ? "searched code" : "ran \(count) searches"
        case .create:
            return count == 1 ? "created a file" : "created \(count) files"
        case .edit:
            return count == 1 ? "edited a file" : "edited \(count) files"
        case .terminal:
            return count == 1 ? "ran a command" : "ran \(count) commands"
        case .projectGraph:
            return count == 1 ? "queried project graph" : "ran \(count) graph queries"
        case .git:
            return count == 1 ? "ran git operation" : "ran \(count) git operations"
        case .skill:
            return count == 1 ? "loaded a skill" : "loaded \(count) skills"
        case .web:
            return count == 1 ? "searched the web" : "ran \(count) web searches"
        case .other:
            return count == 1 ? "used a tool" : "used \(count) tools"
        }
    }

    private static func groupStatusTone(for tools: [ToolTranscriptPresentation]) -> ToolTranscriptStatusTone {
        if tools.contains(where: { $0.statusTone == .failed }) { return .failed }
        if tools.contains(where: { $0.statusTone == .running }) { return .running }
        if tools.contains(where: { $0.statusTone == .autoApproved }) { return .autoApproved }
        return .completed
    }

    private static func changeSummary(for tool: ToolNodePayload) -> String? {
        if let artifact = tool.artifact,
           case .diff(let payload) = artifact.content {
            return diffSummary(added: payload.addedLines, removed: payload.removedLines)
        }

        // 只有真 diff 才逐行统计 — markdown 列表（"- item"）会被 +/- 前缀误判，
        // 曾把 task observation 里的 13 行列表渲染成 "+0 -13"。
        guard looksLikeDiff(tool.output) else { return nil }
        let counts = countDiffLines(tool.output)
        return diffSummary(added: counts.added, removed: counts.removed)
    }

    private static func diffSummary(added: Int, removed: Int) -> String? {
        guard added > 0 || removed > 0 else { return nil }
        return "+\(added) -\(removed)"
    }

    private static func countDiffLines(_ text: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }

    private static func shortDisplayName(_ value: String) -> String {
        if value.contains("/") {
            return (value as NSString).lastPathComponent
        }
        if value.count > 52 {
            return String(value.prefix(49)) + "..."
        }
        return value
    }

    private static func titleize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func formatElapsed(_ ms: Int) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }

    /// 结构化 diff 证据（hunk 头 / 文件头）才算 diff。不能只看行首 +/-：
    /// markdown 列表、命令输出都常以 "-" 开头，会把普通文本渲染成 diff。
    private static func looksLikeDiff(_ text: String) -> Bool {
        text.contains("@@")
            || text.contains("\n+++ ") || text.hasPrefix("+++ ")
            || text.contains("\n--- ") || text.hasPrefix("--- ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
