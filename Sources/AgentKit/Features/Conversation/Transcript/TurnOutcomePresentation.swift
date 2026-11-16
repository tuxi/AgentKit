import Foundation

/// A terminal turn outcome, separate from tool failures and live retry notices.
struct TurnOutcomePresentation: Codable, Equatable, Sendable {
    struct Fact: Codable, Equatable, Sendable { let label: String; let value: String }
    let kind: String
    let title: String
    let message: String?
    let facts: [Fact]
    let diagnostic: String
    let canManageContext: Bool
    let detailsLabel: String
    let rawLabel: String
    let copyLabel: String
    let contextLabel: String

    static func normalize(_ blocks: [TurnBlock]) -> [TurnBlock] {
        let outcomes = blocks.compactMap { block -> (String, SystemNodePayload)? in
            guard case .system(let id, let payload) = block, make(payload) != nil else { return nil }
            return (id, payload)
        }
        guard let first = outcomes.first, let last = outcomes.last else { return blocks }
        var result = blocks.filter { block in
            guard case .system(_, let payload) = block else { return true }
            return make(payload) == nil
        }
        result.append(.system(id: first.0, last.1))
        return result
    }

    static func make(_ payload: SystemNodePayload, text: ToolTranscriptText = .init()) -> Self? {
        let cancelled = payload.kind == .modelActivity && payload.metadata["type"] == "cancelled"
        guard cancelled || payload.kind == .error else { return nil }
        func t(_ key: String) -> String { text.text("outcome." + key) }
        let raw = sanitize(payload.text)
        var title = t("failed"), message: String? = t("failedMessage"), facts: [Fact] = []
        var context = false
        if cancelled {
            let reason = payload.metadata["reason"] ?? (payload.text == "已取消 — user_requested" ? "user_requested" : "")
            title = t(reason == "user_requested" ? "cancelled" : "interrupted")
            message = nil
        } else {
            let code = payload.metadata["code"]?.lowercased() ?? ""
            let pattern = #"maximum context length is ([\d,]+) tokens.*?requested ([\d,]+) output tokens.*?prompt contains at least ([\d,]+) input tokens"#
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            let match = regex?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
            if ["context_length_exceeded", "context_window_exceeded", "max_context_length_exceeded"].contains(code) || match != nil {
                context = true; title = t("contextExceeded"); message = t("contextMessage")
                if let match {
                    let values = (1...3).compactMap { i -> Int? in
                        guard let range = Range(match.range(at: i), in: raw) else { return nil }
                        return Int(raw[range].replacingOccurrences(of: ",", with: ""))
                    }
                    if values.count == 3 {
                        func fact(_ label: String, _ number: Int) -> Fact { .init(label: t(label), value: number.formatted(.number.locale(Locale(identifier: text.locale ?? Locale.current.identifier))) + (number == 1 ? " token" : " tokens")) }
                        facts = [fact("capacity", values[0]), fact("input", values[2]), fact("reserved", values[1])]
                        let sum = values[1].addingReportingOverflow(values[2])
                        if !sum.overflow { facts.append(fact("total", sum.partialValue)); if sum.partialValue > values[0] { facts.append(fact("excess", sum.partialValue - values[0])) } }
                    }
                }
            } else if ["invalid_api_key", "authentication_error", "authentication_failed"].contains(code) {
                title = t("authentication"); message = t("authenticationMessage")
            } else if ["timeout", "request_timeout", "deadline_exceeded"].contains(code) {
                title = t("timeout"); message = t("timeoutMessage")
            } else if ["network_error", "connection_error", "connection_failed"].contains(code) {
                title = t("network"); message = t("networkMessage")
            } else if ["rate_limit_exceeded", "rate_limit_error"].contains(code) {
                title = t("rateLimit"); message = t("rateLimitMessage")
            } else if code == "insufficient_quota" {
                title = t("quota"); message = t("quotaMessage")
            } else if ["permission_denied", "permission_error"].contains(code) {
                title = t("permission"); message = t("permissionMessage")
            } else if code == "invalid_request_error" || raw.contains("type=invalid_request_error") || raw.contains("status=400") {
                title = t("rejected"); message = t("rejectedMessage")
            }
            if let regex = try? NSRegularExpression(pattern: #"\bstatus=(\d{3})\b"#),
               let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let range = Range(match.range(at: 1), in: raw), let status = Int(raw[range]), (100...599).contains(status) {
                facts.append(.init(label: "HTTP", value: String(status)))
            }
            if let code = payload.metadata["code"], !code.isEmpty { facts.append(.init(label: t("code"), value: sanitize(code))) }
        }
        return .init(kind: cancelled ? "cancelled" : "error", title: title, message: message, facts: facts,
                     diagnostic: cancelled ? "" : raw, canManageContext: context,
                     detailsLabel: t("details"), rawLabel: t("raw"), copyLabel: t("copy"), contextLabel: t("manageContext"))
    }

    /// Sanitize presentation and clipboard together. Budget token counts remain intact.
    static func sanitize(_ input: String) -> String {
        // Match JSON strings as a whole, including escaped quotes, before shell
        // tokenization can interpret their quoting as command syntax.
        var result = input
        let jsonCredential = #"(?i)("(?:authorization|proxy-authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret|token|cookie)"\s*:\s*)"(?:\\.|[^"\\])*""#
        if let regex = try? NSRegularExpression(pattern: jsonCredential) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\"[REDACTED]\"")
        }
        result = CommandDisplayRedactor.redact(result)
        for pattern in [
            #"(?i)(authorization\s*[:=]\s*(?:bearer|basic)\s+)[^\s\"',}]+"#,
            #"(?i)((?:\"|')?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)(?:\"|')?\s*[:=]\s*[\"']?)[^\s\"',}]+"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[REDACTED]")
            }
        }
        return result
    }
}
