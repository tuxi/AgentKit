import Foundation

struct ContextMaintenancePresentation: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable { let label: String; let value: String }
    let title: String
    let summary: String
    let status: String
    let steps: [Step]
    let note: String?

    static let kinds: Set<SystemNodeKind> = [.contextEdited, .contextPruned, .contextCompact]
    private struct Legacy: Codable { let kind: String; let text: String; let metadata: [String: String] }

    /// Historical events have no transaction identity. Only adjacent legacy
    /// records can share a disclosure, never across narration or thinking.
    static func mergeLegacyBlocks(_ blocks: [TurnBlock]) -> [TurnBlock] {
        var result: [TurnBlock] = []
        for block in blocks {
            if case .system(_, let next) = block, kinds.contains(next.kind), next.metadata["maintenance"] == nil,
               case .system(let id, let previous)? = result.last, kinds.contains(previous.kind), previous.metadata["maintenance"] == nil {
                var records = legacyRecords(previous)
                records.append(contentsOf: legacyRecords(next))
                var metadata = previous.metadata
                if let data = try? JSONEncoder().encode(records), let json = String(data: data, encoding: .utf8) {
                    metadata["legacyMaintenance"] = json
                    result[result.count - 1] = .system(id: id, .init(kind: previous.kind, text: previous.text, metadata: metadata))
                    continue
                }
            }
            result.append(block)
        }
        return result
    }

    private static func legacyRecords(_ payload: SystemNodePayload) -> [Legacy] {
        if let value = payload.metadata["legacyMaintenance"], let data = value.data(using: .utf8),
           let records = try? JSONDecoder().decode([Legacy].self, from: data) { return records }
        return [.init(kind: payload.kind.rawValue, text: payload.text, metadata: payload.metadata)]
    }

    static func make(_ payload: SystemNodePayload, live: Bool, text: ToolTranscriptText = .init()) -> Self? {
        guard kinds.contains(payload.kind) else { return nil }
        func t(_ key: String) -> String { text.text("context." + key) }
        func integer(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: text.locale ?? Locale.current.identifier))) }
        func short(_ value: Int) -> String { value >= 1000 ? String(format: "%.1fK", locale: Locale(identifier: "en"), Double(value) / 1000) : integer(value) }
        func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        var steps: [Step] = []
        var status = "completed"
        var summary = t("recorded")
        var note: String?
        if let raw = payload.metadata["maintenance"], let data = raw.data(using: .utf8),
           let value = try? JSONDecoder().decode(ContextMaintenance.self, from: data) {
            status = value.status
            if status == "running" && !live { status = "interrupted" }
            let terminalFailure = ["failed", "canceled", "interrupted"].contains(status)
            if value.clearedResults > 0 { steps.append(.init(label: t("clear"), value: text.text("context.resultCount", value.clearedResults))) }
            if let saved = nonnegative(value.estimatedSavedTokens), saved > 0 { steps.append(.init(label: t("prune"), value: text.text("context.estimatedSaving", integer(saved)))) }
            if value.summaryGenerated { steps.append(.init(label: t("summarize"), value: t("done"))) }
            switch status {
            case "running": summary = t(value.phase == "summarizing" ? "summarizing" : "preparing")
            case "pending": summary = t(value.summaryGenerated ? "awaitingMeasurement" : "unknownMeasurement")
            case "failed": summary = t("failed")
            case "canceled": summary = t("canceled")
            case "interrupted": summary = t("interrupted")
            case "limited": summary = t("limited"); note = t("limitedNote")
            default:
                if value.committed, value.measurementSource == "measured", let before = nonnegative(value.beforeTokens), let after = nonnegative(value.afterTokens) {
                    summary = "\(short(before)) → \(short(after)) tokens"
                } else if value.committed, value.summaryGenerated { summary = t("awaitingMeasurement") }
                else if value.committed, (value.estimatedSavedTokens ?? 0) > 0 { summary = t("pruned") }
                else if value.committed, value.clearedResults > 0 { summary = text.text("context.cleared", value.clearedResults) }
                else { summary = t("noChange") }
            }
            if value.committed, value.measurementSource == "measured", let before = nonnegative(value.beforeTokens), let after = nonnegative(value.afterTokens) {
                steps.append(.init(label: t("usage"), value: "\(integer(before)) → \(integer(after)) tokens"))
            } else if !terminalFailure, value.summaryGenerated { steps.append(.init(label: t("usage"), value: t("unknownMeasurement"))) }
            if terminalFailure, !value.committed { note = t(status == "interrupted" ? "interruptedNote" : "rollbackNote") }
            if let error = value.error, !error.isEmpty, terminalFailure {
                let redacted = error.replacingOccurrences(of: #"(?i)Bearer\s+[^\s,;]+|sk-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9_]+"#, with: "[redacted]", options: .regularExpression)
                let safe = ToolTranscriptText.bounded(redacted, limit: 400)
                steps.append(.init(label: t("reason"), value: safe))
            }
        } else {
            // These are observations from old runtimes, not commit receipts.
            for record in legacyRecords(payload) {
                if record.kind == SystemNodeKind.contextEdited.rawValue {
                    let regex = try? NSRegularExpression(pattern: #"^cleared ([0-9]+) stale tool results$"#)
                    let source = record.text as NSString
                    let match = regex?.firstMatch(in: record.text, range: NSRange(location: 0, length: source.length))
                    let count = match.flatMap { Int(source.substring(with: $0.range(at: 1))) }
                    steps.append(.init(label: t("clear"), value: count.map { text.text("context.resultCount", $0) } ?? t("recorded")))
                    summary = t("clear")
                } else if record.kind == SystemNodeKind.contextPruned.rawValue {
                    let saved = nonnegative(record.metadata["savedTokens"].flatMap(Int.init))
                    steps.append(.init(label: t("prune"), value: saved.map { text.text("context.estimatedSaving", integer($0)) } ?? t("recorded")))
                    summary = t("pruned")
                } else {
                    let before = nonnegative(record.metadata["beforeTokens"].flatMap(Int.init))
                    let after = nonnegative(record.metadata["afterTokens"].flatMap(Int.init)).flatMap { $0 > 0 ? $0 : nil }
                    summary = t("awaitingMeasurement")
                    if let before, let after {
                        steps.append(.init(label: t("usage"), value: "\(integer(before)) → \(integer(after)) tokens"))
                        summary = "\(short(before)) → \(short(after)) tokens"
                    }
                    if record.metadata["ineffective"] == "true" { status = "limited"; summary = t("limited"); note = t("limitedNote") }
                }
            }
            if note == nil { note = t("legacyNote") }
        }
        if let raw = payload.metadata["maintenanceAttempts"]?.data(using: .utf8),
           let attempts = try? JSONDecoder().decode([ContextMaintenance].self, from: raw) {
            if attempts.count == 20 { note = [note, t("attemptLimit")].compactMap { $0 }.joined(separator: " ") }
            for attempt in attempts {
                let reason = (attempt.error ?? t(attempt.status == "canceled" ? "canceled" : "failed"))
                    .replacingOccurrences(of: #"(?i)Bearer\s+[^\s,;]+|sk-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9_]+"#, with: "[redacted]", options: .regularExpression)
                steps.append(.init(label: t("earlierAttempt"), value: ToolTranscriptText.bounded(reason, limit: 400)))
            }
        }
        return .init(title: t("title"), summary: summary, status: status, steps: steps, note: note)
    }
}
