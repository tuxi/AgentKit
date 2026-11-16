import Foundation

/// Desktop timeline policy. Kept separate from the iOS presentation until the
/// macOS interaction has been accepted. No execution records are rewritten.
enum MacToolPresentation {
    /// Inspector identity must include the owning turn: a restarted backend
    /// can reuse a call_id while graph node IDs remain unique.
    static func inspectorNodeID(callID: String, turn: ConversationTurn, timeline: [ExecutionNode]) -> String {
        guard let start = timeline.firstIndex(where: { $0.id == turn.id }) else { return callID }
        let end = timeline.indices.dropFirst(start + 1).first { index in
            if case .message(let message) = timeline[index].kind { return message.role == .user }
            return false
        } ?? timeline.endIndex
        return timeline[start..<end].first { node in
            if case .tool(let tool) = node.kind { return tool.callID == callID }
            return false
        }?.id ?? callID
    }

    /// The redactor scans the complete command with its quoting context.
    static func shouldRedactCommand(_ command: String) -> Bool {
        CommandDisplayRedactor.redact(command) != command
    }

    /// Row labels describe the action; the full command belongs to the input
    /// panel. A transport description wins even when a shell command has a
    /// recognized file/search meaning.
    static func rowTitle(_ tool: ToolNodePayload, text: ToolTranscriptText = .init()) -> String {
        let base = ToolTranscriptPresenter.presentation(for: tool, locale: text.locale)
        guard let command = ToolTranscriptPresenter.commandValue(for: tool) else { return singleLine(base.title) }
        if case .string(let description)? = tool.args?["description"] {
            let title = singleLine(CommandDisplayRedactor.redact(description))
            if !title.isEmpty { return title }
        }
        if base.family != .terminal { return singleLine(base.title) }
        guard !shouldRedactCommand(command),
              let token = command.split(whereSeparator: \.isWhitespace).first,
              token.count <= 512,
              token.range(of: #"^[A-Za-z0-9_./+\-]+$"#, options: .regularExpression) != nil else { return text.text("run") }
        let executable = (String(token) as NSString).lastPathComponent
        guard !executable.isEmpty else { return text.text("run") }
        var name = executable
        // Only a fully literal command can contribute a subcommand. Never
        // summarize a pipeline/script as if it were a single inferred action.
        if let words = ToolCommandPresentation.literalWords(command) {
            var arguments = Array(words.dropFirst())
            if executable == "git" {
                while arguments.count >= 2, ["-C", "--git-dir", "--work-tree"].contains(arguments[0]) {
                    arguments.removeFirst(2)
                }
            }
            let subcommands: [String: Set<String>] = [
                "git": ["status", "diff", "log", "show", "branch", "add", "commit", "checkout", "fetch", "pull", "push", "clone", "init"],
                "swift": ["test", "build", "run", "package"],
                "npm": ["run", "test", "install", "ci"], "pnpm": ["run", "test", "build", "install"],
                "yarn": ["run", "test", "build", "install"]]
            if let subcommand = arguments.first, subcommands[executable]?.contains(subcommand) == true {
                name += " " + subcommand
            }
        }
        return text.text("desktop.runNamed", singleLine(name))
    }

    private static func singleLine(_ value: String) -> String {
        ToolTranscriptText.bounded(value.split(whereSeparator: \.isWhitespace).joined(separator: " "), limit: 120)
    }

    static func rowPresentation(_ tool: ToolNodePayload) -> ToolTranscriptPresentation {
        let base = ToolTranscriptPresenter.presentation(for: tool)
        return .init(callID: base.callID, family: base.family, statusTone: base.statusTone,
            statusText: base.statusText, title: rowTitle(tool), detail: nil, elapsed: base.elapsed,
            changeSummary: base.changeSummary, outputKind: base.outputKind)
    }

    static func isFailed(_ tool: ToolNodePayload) -> Bool {
        tool.status == .failed || (tool.exitCode.map { $0 != 0 } ?? false)
    }

    static func isFailed(_ job: ChildStreamNodePayload) -> Bool {
        job.status != .canceled && (job.status == .failed || (job.exitCode.map { $0 != 0 } ?? false))
    }

    static func failureCount(_ group: ToolGroup) -> Int {
        group.tools.filter(isFailed).count + group.backgroundJobs.filter(isFailed).count
    }

    static func backgroundJobTitle(_ job: ChildStreamNodePayload, text: ToolTranscriptText = .init()) -> String {
        let tool = ToolNodePayload(callID: job.childID, toolName: "run_command",
                                  args: .object(["command": .string(job.title)]), status: .completed)
        return text.text("desktop.backgroundNamed", rowTitle(tool, text: text))
    }

    static func backgroundJobStatus(_ job: ChildStreamNodePayload, text: ToolTranscriptText = .init()) -> String? {
        switch job.status {
        case .running: return text.text("running")
        case .failed: return text.text("failed")
        case .canceled: return text.text("desktop.canceled")
        case .unavailable: return text.text("jobs.unavailable")
        case .completed: return isFailed(job) ? text.text("failed") : nil
        }
    }

    static func isRunning(_ group: ToolGroup) -> Bool {
        group.isCollecting || group.isThinking || group.tools.contains { $0.status == .running } || group.backgroundJobs.contains { $0.status == .running }
    }

    static func countSummary(_ group: ToolGroup, text: ToolTranscriptText = .init()) -> String {
        // Classify before counting: unrelated families must never become several
        // indistinguishable “other” buckets. Shell calls count once, regardless
        // of how many commands their scripts contain.
        let priority: [SummaryFamily] = [.terminal, .edit, .create, .read, .search, .list,
            .git, .web, .skill, .task, .session, .jobs, .projectGraph, .todo, .plan, .workflow, .memory, .preMutation, .other]
        var counts: [SummaryFamily: Int] = [:]
        for tool in group.tools { counts[summaryFamily(tool), default: 0] += 1 }
        if !group.backgroundJobs.isEmpty { counts[.terminal, default: 0] += group.backgroundJobs.count }
        let checks = group.entries.filter { if case .preMutation = $0 { return true }; return false }.count
        if checks > 0 { counts[.preMutation] = checks }
        let families = priority.filter { counts[$0] != nil }
        if families.isEmpty { return text.thinkingTitle(streaming: group.isThinking || group.isCollecting) }
        if families == [.other] { return text.text("desktop.count.tools", group.tools.count) }
        let visible = families.count > 3 ? Array(families.prefix(2)) : families
        var parts = visible.map { family -> String in
            let count = counts[family]!
            let key: String = switch family {
            case .terminal: "commands"
            case .read: "reads"
            case .search: "searches"
            case .edit: "edits"
            case .create: "creates"
            case .list: "lists"
            case .git: "git"
            case .web: "web"
            case .skill: "skills"
            case .session: "sessions"
            case .projectGraph: "project"
            case .todo: "todos"
            case .plan: "plans"
            case .workflow: "workflows"
            case .jobs: "jobs"
            case .task: "tasks"
            case .memory: "memory"
            case .preMutation: "preMutation"
            case .other: "additional"
            }
            if family == .read, count == 1,
               let tool = group.tools.first(where: { summaryFamily($0) == .read }),
               let path = ["file_path", "path", "file"].compactMap({ key -> String? in
                   guard case .string(let value)? = tool.args?[key], !value.isEmpty else { return nil }
                   return value
               }).first {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty { return text.text("desktop.readNamed", ToolTranscriptText.bounded(name, limit: 64)) }
            }
            return text.text("desktop.count." + key + (count == 1 ? ".one" : ""), count)
        }
        let remainder = families.dropFirst(visible.count).reduce(0) { $0 + counts[$1]! }
        if remainder > 0 { parts.append(text.text("desktop.count.additional", remainder)) }
        return parts.joined(separator: " · ")
    }

    private enum SummaryFamily: Hashable {
        case terminal, read, list, search, edit, create, git, web, skill, task, session, jobs
        case projectGraph, todo, plan, workflow, memory, preMutation, other
    }

    private static func summaryFamily(_ tool: ToolNodePayload) -> SummaryFamily {
        let name = tool.toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        switch name {
        case "run_command", "exec_command", "bash", "shell", "terminal": return .terminal
        case "insert_file": return .edit
        case "task": return .task
        case "job_wait", "job_status", "job_logs", "job_cancel": return .jobs
        case "create_memory", "update_memory", "delete_memory", "list_memories", "recall_memory": return .memory
        case "git_init", "git_clone": return .git
        default:
            // Explicit presenter families remain the source of semantic truth.
            switch ToolTranscriptPresenter.presentation(for: tool).family {
            case .terminal: return .terminal
            case .read: return .read
            case .list: return .list
            case .search: return .search
            case .edit: return .edit
            case .create: return .create
            case .git: return .git
            case .web: return .web
            case .skill: return .skill
            case .session: return .session
            case .projectGraph: return .projectGraph
            case .todo: return .todo
            case .plan: return .plan
            case .workflow: return .workflow
            case .other: return .other
            }
        }
    }

    static func currentSummary(_ group: ToolGroup, text: ToolTranscriptText = .init()) -> String {
        let activeTitles = group.entries.compactMap { entry -> String? in
            switch entry {
            case .tool(let tool): return tool.status == .running ? rowTitle(tool, text: text) : nil
            case .backgroundJob(_, let job): return job.status == .running ? backgroundJobTitle(job, text: text) : nil
            case .thinking, .preMutation: return nil
            }
        }
        if let title = activeTitles.first {
            return text.text("active.running", title)
                + (activeTitles.count > 1 ? " · " + text.text("desktop.parallel", activeTitles.count - 1) : "")
        }
        if group.isThinking { return text.text("thinking") }
        if group.isCollecting { return text.text("active.processing") }
        return countSummary(group, text: text)
    }

    static func expandedSummary(_ group: ToolGroup, text: ToolTranscriptText = .init()) -> String {
        countSummary(group, text: text)
    }

    /// Semantic input is immediately visible, without opening transport JSON.
    static func input(for tool: ToolNodePayload) -> String? {
        if let command = ToolTranscriptPresenter.commandValue(for: tool) { return command }
        guard case .object(let args)? = tool.args else { return tool.args?.prettyJSONString }
        func string(_ keys: [String]) -> String? {
            keys.lazy.compactMap { key -> String? in
                guard case .string(let value)? = args[key], !value.isEmpty else { return nil }
                return value
            }.first
        }
        let name = tool.toolName.lowercased().replacingOccurrences(of: "-", with: "_")
        let path = string(["file_path", "path", "file", "directory"])
        if ["read_file", "read_files", "view_file", "edit_file", "apply_patch", "patch_file", "replace_in_file", "write_file", "create_file", "list_files", "list_directory", "list_dir"].contains(name), let path {
            var value = path
            if let start = args["start_line"], let end = args["end_line"] {
                value += "\n\(start.stringValue)–\(end.stringValue)"
            }
            return value
        }
        if ["grep", "rg", "search_code", "search_files", "file_search"].contains(name), let query = string(["pattern", "query", "search_term", "regex"]) {
            return [query, path].compactMap { $0 }.joined(separator: "\n")
        }
        return tool.args?.prettyJSONString
    }

    static func labels(text: ToolTranscriptText = .init()) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ["noOutput", "failedNoOutput", "copyCommand", "copyInput", "viewFullOutput", "viewFullCommand", "preview", "sensitiveValuesHidden", "waitingChecks", "rawRecords"].map {
            ($0, text.text("desktop." + ($0 == "waitingChecks" ? "waitingChecksLabel" : $0)))
        })
    }
}
