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

    /// Existing transcript glyphs / SF Symbols, shared by the Web and native rows.
    var icon: String {
        switch family {
        case .read: return "□"
        case .list: return "≡"
        case .search: return "⌕"
        case .create: return "+"
        case .edit: return "±"
        case .terminal: return "$"
        default: return "◇"
        }
    }
    var systemImage: String {
        switch family {
        case .read: return "doc.text"
        case .list: return "folder"
        case .search: return "magnifyingglass"
        case .create: return "doc.badge.plus"
        case .edit: return "pencil"
        case .terminal: return "terminal"
        default: return "wrench.and.screwdriver"
        }
    }

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
    case todo
    case plan
    case workflow
    case session
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

    static func presentation(for tool: ToolNodePayload, locale: String? = nil) -> ToolTranscriptPresentation {
        let text = ToolTranscriptText(locale: locale)
        if let summary = semanticSummary(for: tool, text: text) {
            return ToolTranscriptPresentation(callID: tool.callID, family: summary.family,
                statusTone: statusTone(for: tool), statusText: statusText(for: tool, locale: locale),
                title: ToolTranscriptText.bounded(summary.title, limit: 180), detail: summary.detail,
                elapsed: tool.elapsedMs.map(formatElapsed), changeSummary: changeSummary(for: tool),
                outputKind: outputKind(for: tool, family: ["run_command", "exec_command", "bash", "shell", "terminal"].contains(tool.toolName.lowercased()) ? .terminal : summary.family))
        }
        // P8.7 — job_wait 是"阻塞等待后台任务"的专用工具，
        // 长时间 running 是常态，给专属文案避免被读成卡死。
        if let operation = BackgroundJobPresentation.operation(tool.toolName) {
            return jobPresentation(for: tool, operation: operation, text: text)
        }
        // task 委派卡：prompt 含 "/" 会被通用路径缩写截成尾巴（"directories."），
        // 给专属形态。后端把 task_started bracket 接进父流后，childStream 入口卡
        // 是主形态，这张普通卡仍并存 —— 届时考虑在投影层合并二者。
        if tool.toolName == "task" {
            return taskPresentation(for: tool)
        }
        if let presentation = sessionPresentation(for: tool) {
            return presentation
        }
        // Do not infer file/search semantics from substrings in unknown or MCP names.
        guard let family = legacyFamily(for: tool.toolName) else {
            return ToolTranscriptPresentation(callID: tool.callID, family: .other,
                statusTone: statusTone(for: tool), statusText: statusText(for: tool, locale: locale),
                title: text.text("unknown", ToolTranscriptText.bounded(tool.toolName)), detail: nil,
                elapsed: tool.elapsedMs.map(formatElapsed), changeSummary: changeSummary(for: tool), outputKind: .text)
        }
        let target = targetValue(for: tool)
        let displayTarget = target.map(shortDisplayName)

        return ToolTranscriptPresentation(
            callID: tool.callID,
            family: family,
            statusTone: statusTone(for: tool),
            statusText: statusText(for: tool),
            title: title(for: family, target: family == .terminal ? target : displayTarget, tool: tool),
            detail: detail(for: family, target: target, tool: tool),
            elapsed: tool.elapsedMs.map(formatElapsed),
            changeSummary: changeSummary(for: tool),
            outputKind: outputKind(for: tool, family: family)
        )
    }

    static func groupPresentation(for group: ToolGroup, locale: String? = nil) -> ToolTranscriptGroupPresentation {
        let tools = group.tools.map { presentation(for: $0, locale: locale) }
        return ToolTranscriptGroupPresentation(
            callID: group.id,
            summary: group.isActivityGroup ? activitySummary(for: group, tools: tools, text: ToolTranscriptText(locale: locale)) : groupSummary(for: tools),
            statusTone: group.isThinking && !tools.contains(where: { $0.statusTone == .failed })
                ? .running : groupStatusTone(for: tools),
            tools: tools
        )
    }

    /// Original command for the explicitly expanded result card. Unlike the
    /// compact header this is full source data, matching the raw-arguments view.
    static func commandValue(for tool: ToolNodePayload) -> String? {
        let name = tool.toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        guard ["run_command", "exec_command", "bash", "shell", "terminal"].contains(name),
              case .object(let args)? = tool.args else { return nil }
        for key in ["command", "cmd"] {
            if case .string(let value)? = args[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func semanticSummary(for tool: ToolNodePayload, text: ToolTranscriptText) -> ToolCommandPresentation.Summary? {
        let name = tool.toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        let args: [String: JSONValue]
        if case .object(let values)? = tool.args { args = values } else { args = [:] }
        func value(_ keys: [String]) -> String? {
            keys.lazy.compactMap { key -> String? in
                guard case .string(let value)? = args[key], !value.isEmpty else { return nil }
                return value
            }.first
        }
        let family: ToolTranscriptFamily
        let action: String
        switch name {
        case "read_file", "read_files", "view_file": family = .read; action = "read"
        case "list_files", "list_directory", "list_dir": family = .list; action = "list"
        case "grep", "rg", "search_code", "search_files", "file_search": family = .search; action = "search"
        case "edit_file", "apply_patch", "patch_file", "replace_in_file": family = .edit; action = "edit"
        case "write_file": family = .create; action = "write"
        case "create_file": family = .create; action = "create"
        case "run_command", "exec_command", "bash", "shell", "terminal":
            let command = value(["command", "cmd"])
            if let command, let summary = ToolCommandPresentation.summarize(command, text: text) { return summary }
            return .init(family: .terminal, title: text.text("run"),
                         detail: command.map { ToolCommandPresentation.preview($0, text: text) })
        default: return nil
        }
        let path = value(["file_path", "path", "file", "directory"]) ?? tool.artifact?.path
        let boundedPath = path.map { ToolTranscriptText.bounded($0) }
        if family == .search {
            let pattern = value(["pattern", "query", "search_term", "regex"])
            return .init(family: family,
                title: pattern.map { text.text("search", ToolTranscriptText.bounded($0)) } ?? text.text("search.generic"),
                detail: boundedPath.map { text.text("scope", $0) })
        }
        let target = path.map { ToolTranscriptText.bounded(($0 as NSString).lastPathComponent) }
        if family == .read, let target,
           let start = positiveInteger(args["start_line"]), let end = positiveInteger(args["end_line"]), end >= start {
            return .init(family: family, title: text.text("view.lines", target, start, end), detail: boundedPath)
        }
        return .init(family: family, title: target.map { text.text(action, $0) } ?? text.text(action + ".generic"),
                     detail: path != target ? boundedPath : nil)
    }

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        let result: Int?
        switch value {
        case .integer(let number): result = number
        case .number(let number): result = Int(exactly: number)
        default: result = nil
        }
        guard let result, result > 0, result <= 10_000_000 else { return nil }
        return result
    }

    private static func jobPresentation(for tool: ToolNodePayload, operation: String,
                                        text: ToolTranscriptText) -> ToolTranscriptPresentation {
        let detail = tool.backgroundJobCommand.map { BackgroundJobPresentation.summary($0, text: text) }
            ?? BackgroundJobPresentation.jobID(for: tool).map { ToolTranscriptText.bounded($0) }
        return ToolTranscriptPresentation(
            callID: tool.callID, family: .other, statusTone: statusTone(for: tool),
            statusText: operation == "wait" && tool.status == .running
                ? text.text("waiting") : statusText(for: tool, locale: text.locale),
            title: text.text("job." + operation), detail: detail,
            elapsed: tool.elapsedMs.map { operation == "wait"
                ? text.text("job.wait.elapsed", formatElapsed($0)) : formatElapsed($0) },
            changeSummary: nil, outputKind: .text
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

    private static func sessionPresentation(for tool: ToolNodePayload) -> ToolTranscriptPresentation? {
        let name = tool.toolName.lowercased()
        guard ["list_sessions", "create_session", "send_to_session", "wait_sessions", "read_session"].contains(name) else {
            return nil
        }
        let args: [String: JSONValue] = {
            if case .object(let dict)? = tool.args { return dict }
            return [:]
        }()
        let title: String
        let detail: String?
        switch name {
        case "list_sessions":
            title = "List sessions"
            detail = sessionListDetail(args)
        case "create_session":
            title = "Create session"
            detail = firstNonEmptyString(args, keys: ["name", "workspace_path"]).map(shortDisplayName)
        case "send_to_session":
            title = "Send to session"
            detail = sessionSendDetail(args)
        case "wait_sessions":
            title = "Wait for sessions"
            detail = waitTargetsDetail(args)
        case "read_session":
            title = "Read session"
            detail = firstNonEmptyString(args, keys: ["id"]).map(shortSessionID)
        default:
            return nil
        }
        return ToolTranscriptPresentation(
            callID: tool.callID,
            family: .session,
            statusTone: statusTone(for: tool),
            statusText: statusText(for: tool),
            title: title,
            detail: detail,
            elapsed: tool.elapsedMs.map(formatElapsed),
            changeSummary: nil,
            outputKind: .json
        )
    }

    private static func sessionListDetail(_ args: [String: JSONValue]) -> String? {
        var parts: [String] = []
        if let project = args["project"]?.stringValue.nilIfEmpty {
            parts.append(shortDisplayName(project))
        }
        if let status = args["status"]?.stringValue.nilIfEmpty {
            parts.append(status)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    private static func sessionSendDetail(_ args: [String: JSONValue]) -> String? {
        let id = firstNonEmptyString(args, keys: ["id"]).map(shortSessionID)
        let message = firstNonEmptyString(args, keys: ["message"]).map(firstLineSnippet)
        switch (id, message) {
        case (.some(let id), .some(let message)):
            return "\(id): \(message)"
        case (.some(let id), nil):
            return id
        case (nil, .some(let message)):
            return message
        case (nil, nil):
            return nil
        }
    }

    private static func waitTargetsDetail(_ args: [String: JSONValue]) -> String? {
        guard case .array(let targets)? = args["targets"], !targets.isEmpty else {
            return nil
        }
        if targets.count == 1,
           case .object(let target) = targets[0],
           let id = target["id"]?.stringValue.nilIfEmpty {
            return shortSessionID(id)
        }
        return "\(targets.count) targets"
    }

    private static func firstNonEmptyString(_ args: [String: JSONValue], keys: [String]) -> String? {
        keys.lazy.compactMap { args[$0]?.stringValue.nilIfEmpty }.first
    }

    private static func firstLineSnippet(_ text: String) -> String {
        let firstLine = text.components(separatedBy: "\n").first ?? text
        return firstLine.count > 60 ? String(firstLine.prefix(57)) + "..." : firstLine
    }

    private static func shortSessionID(_ id: String) -> String {
        id.count > 16 ? String(id.prefix(13)) + "..." : id
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
        if family == .todo {
            return "Todo: Write todos"
        }
        if family == .plan {
            return tool.toolName == "enter_plan_mode"
                ? "Plan: Enter plan mode"
                : "Plan: Propose plan"
        }
        if family == .workflow {
            if let target, !target.isEmpty {
                return "Workflow: \(target)"
            }
            return "Workflow"
        }
        if family == .terminal { return ToolTranscriptText().text("run") }
        // download_file — show filename not URL.
        if tool.toolName == "download_file" {
            if let target, !target.isEmpty {
                return "Download \(shortDisplayName(target))"
            }
            return "Download file"
        }
        if let target, !target.isEmpty {
            return "\(verb(for: family)) \(target)"
        }
        return verb(for: family, fallback: titleize(tool.toolName))
    }

    private static func detail(for family: ToolTranscriptFamily, target: String?, tool: ToolNodePayload) -> String? {
        switch family {
        case .terminal, .git, .skill, .plan, .todo, .workflow:
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

    private static func legacyFamily(for toolName: String) -> ToolTranscriptFamily? {
        let name = toolName.lowercased()
        if TodoToolPayload.isTodoWriteTool(name) { return .todo }
        switch name {
        case "download_file": return .read
        case "enter_plan_mode", "propose_plan": return .plan
        case "plan_workflow": return .workflow
        case "load_skill": return .skill
        case "git_status", "git_diff", "git_log", "git_show", "git_branch", "git_commit", "git_add", "git_checkout", "git_fetch", "git_pull", "git_push": return .git
        case "web_search", "web_fetch", "web_open", "web_browse", "web.search", "web.fetch": return .web
        default: return nil
        }
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
        if tool.isAutoApproved, tool.status != .running, tool.status != .failed { return .autoApproved }
        switch tool.status {
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .autoApproved: return .autoApproved
        }
    }

    private static func statusText(for tool: ToolNodePayload, locale: String? = nil) -> String? {
        let text = ToolTranscriptText(locale: locale)
        if tool.isAutoApproved, tool.status != .running, tool.status != .failed { return text.text("auto") }
        switch tool.status {
        case .running:
            return text.text("running")
        case .completed:
            return nil
        case .failed:
            if let exitCode = tool.exitCode {
                return text.text("failed.code", exitCode)
            }
            return text.text("failed")
        case .autoApproved:
            return text.text("auto")
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
        case .todo: return "Todo"
        case .plan: return "Plan"
        case .workflow: return "Workflow"
        case .session: return "Coordinate"
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
        case .todo: return count == 1 ? "item" : "items"
        case .plan: return count == 1 ? "plan" : "plans"
        case .workflow: return count == 1 ? "workflow" : "workflows"
        case .session: return count == 1 ? "session action" : "session actions"
        case .other: return count == 1 ? "tool" : "tools"
        }
    }

    private static func activitySummary(for group: ToolGroup, tools: [ToolTranscriptPresentation], text: ToolTranscriptText) -> String {
        var labels: [String] = []
        for (tool, presentation) in zip(group.tools, tools) {
            let key: String?
            switch presentation.family {
            case .read: key = "read"
            case .list: key = "list"
            case .search: key = "search"
            case .create: key = tool.toolName == "write_file" ? "write" : "create"
            case .edit: key = "edit"
            case .terminal: key = "run"
            default: key = nil
            }
            let isCommand = ["run_command", "exec_command", "bash", "shell", "terminal"].contains(tool.toolName.lowercased())
            let jobOperation = BackgroundJobPresentation.operation(tool.toolName)
            let label = jobOperation.map { text.text("job." + $0) } ?? (isCommand ? text.text("activity.run")
                : key.map { text.text("activity." + $0) } ?? ToolTranscriptText.bounded(tool.toolName))
            if !labels.contains(label) { labels.append(label) }
        }
        let repeatedWaits = group.entries.count == tools.count && tools.count > 1
            && BackgroundJobPresentation.waitRuns(in: group.entries).count == 1
            && group.tools.allSatisfy { BackgroundJobPresentation.operation($0.toolName) == "wait"
                && BackgroundJobPresentation.jobID(for: $0) != nil }
        var parts = repeatedWaits ? [text.text("job.wait.count", tools.count)]
            : [labels.joined(separator: text.text("activity.separator")), text.text(tools.count == 1 ? "calls.one" : "calls.many", tools.count)]
        let running = group.tools.filter { $0.status == .running }.count
        let failed = group.tools.filter { $0.status == .failed }.count
        if running > 0 { parts.append(text.text("count.running", running)) }
        if group.isThinking { parts.append(text.text("activity.thinking")) }
        if failed > 0 { parts.append(text.text("count.failed", failed)) }
        return parts.joined(separator: " · ")
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
        case .todo:
            return count == 1 ? "wrote todos" : "wrote \(count) todo lists"
        case .plan:
            return count == 1 ? "entered plan mode" : "made \(count) plans"
        case .workflow:
            return count == 1 ? "ran a workflow" : "ran \(count) workflows"
        case .session:
            return count == 1 ? "coordinated a session" : "coordinated \(count) sessions"
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
        guard tool.status == .completed || tool.status == .autoApproved else { return nil }
        if let artifact = tool.artifact,
           case .diff(let payload) = artifact.content {
            return diffSummary(added: payload.addedLines, removed: payload.removedLines)
        }

        // 只有真 diff 才逐行统计 — markdown 列表（"- item"）会被 +/- 前缀误判，
        // 曾把 task observation 里的 13 行列表渲染成 "+0 -13"。
        guard tool.output.contains("@@ -"),
              tool.output.range(of: #"(?m)^@@ -[0-9]+(?:,[0-9]+)? \+[0-9]+(?:,[0-9]+)? @@"#,
                                options: .regularExpression) != nil else { return nil }
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
