import Foundation

/// Display-only job metadata. A wait's status never changes the job's status.
enum BackgroundJobPresentation {
    static func operation(_ name: String) -> String? {
        switch name.lowercased() {
        case "job_wait": return "wait"
        case "job_status": return "status"
        case "job_logs": return "logs"
        case "job_cancel": return "cancel"
        default: return nil
        }
    }

    static func jobID(for tool: ToolNodePayload) -> String? {
        guard operation(tool.toolName) != nil,
              case .object(let args)? = tool.args,
              let id = args["job_id"]?.stringValue,
              !id.isEmpty else { return nil }
        return id
    }

    static func waitRuns(in entries: [ToolGroup.Entry]) -> [[ToolGroup.Entry]] {
        var runs: [[ToolGroup.Entry]] = []
        var previousJobID: String?
        for entry in entries {
            let id: String?
            if case .tool(let tool) = entry, operation(tool.toolName) == "wait" {
                id = jobID(for: tool)
            } else { id = nil }
            if let id, id == previousJobID { runs[runs.count - 1].append(entry) }
            else { runs.append([entry]) }
            previousJobID = id
        }
        return runs
    }

    static func summary(_ command: String, text: ToolTranscriptText) -> String {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let name = (executable as NSString).lastPathComponent
        // Interpreter identity is safe to show even when script arguments are
        // private. Never infer the script's purpose from its body or filenames.
        if name.range(of: #"^python(?:[0-9]+(?:\.[0-9]+)*)?$"#, options: .regularExpression) != nil,
           command.contains("<<") || command.contains("\n") || command.contains(" -c ") {
            return text.text("job.python")
        }
        if command.contains("\n") || command.contains("<<") { return text.text("job.script") }
        if command.isEmpty { return text.text("job.task") }
        return ToolCommandPresentation.preview(command, text: text)
    }

    static func title(_ payload: ChildStreamNodePayload, text: ToolTranscriptText = .init()) -> String {
        payload.kind == .job ? text.text("job.run", summary(payload.title, text: text)) : payload.title
    }
}
