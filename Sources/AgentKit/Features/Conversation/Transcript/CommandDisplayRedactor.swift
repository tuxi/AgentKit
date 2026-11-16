import Foundation

/// Display-only shell tokenization. Never evaluates expansions or rewrites the
/// execution record. Ranges refer to the original UTF-16 string, including for
/// quoted values, so paths, spacing and command structure remain recognizable.
enum CommandDisplayRedactor {
    static let mask = "••••••"
    private struct Token { let range: NSRange; let value: String; let group: Int }

    static func redact(_ command: String) -> String {
        let source = command as NSString
        let tokens = tokenize(command)
        var ranges: [NSRange] = []
        func isReference(_ value: String) -> Bool {
            value.range(of: #"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$"#, options: .regularExpression) != nil
        }
        func add(_ range: NSRange, value: String? = nil, closingQuote: Bool = false) {
            if let value, isReference(value) { return }
            var start = range.location, end = NSMaxRange(range)
            guard start < end else { return }
            let first = source.character(at: start), last = source.character(at: end - 1)
            if (first == 34 || first == 39), first == last, end - start >= 2 { start += 1; end -= 1 }
            else if closingQuote, last == 34 || last == 39 { end -= 1 }
            if start < end { ranges.append(NSRange(location: start, length: end - start)) }
        }
        func matches(_ pattern: String, capture: Int = 1) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: command, range: NSRange(location: 0, length: source.length)) {
                let range = match.range(at: capture)
                if range.location != NSNotFound { add(range, value: source.substring(with: range)) }
            }
        }
        func isQuoted(_ position: Int, in token: Token) -> Bool {
            var index = token.range.location
            var quote: UInt16?
            while index < position {
                let c = source.character(at: index)
                if c == 92, quote != 39 { index += 2; continue }
                if let current = quote { if c == current { quote = nil } }
                else if c == 34 || c == 39 { quote = c }
                index += 1
            }
            return quote != nil
        }
        let options: Set<String> = ["--token", "--access-token", "--auth-token", "--api-key", "--apikey", "--password", "--passwd", "--secret", "--client-secret", "--credential", "--credentials", "--cookie", "--key", "--private-key", "--access-key", "--secret-key"]
        let sensitiveName = #"(?i)(?:^|_)(?:password|passwd|token|secret|api_key|access_key|secret_access_key|private_key|cookie|credentials?)$"#
        var currentGroup = -1, first = "", onlyAssignments = true, hasHTTP = false
        for (index, token) in tokens.enumerated() {
            if token.group != currentGroup { currentGroup = token.group; first = token.value; onlyAssignments = true; hasHTTP = false }
            defer {
                onlyAssignments = onlyAssignments && token.value.contains("=")
                hasHTTP = hasHTTP || ["curl", "wget", "http", "https"].contains((token.value as NSString).lastPathComponent)
            }
            let value = token.value
            let key = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
            let quote = source.character(at: token.range.location)
            let assignmentPosition = onlyAssignments
                || ["env", "export", "declare", "local", "readonly", "typeset"].contains(first)
            let sensitiveAssignment = value.contains("=") && assignmentPosition && quote != 34 && quote != 39
                && key.range(of: sensitiveName, options: .regularExpression) != nil
            let httpUser = hasHTTP && ["-u", "--user", "--proxy-user"].contains(key.lowercased())
            if value.contains("="), options.contains(key.lowercased()) || sensitiveAssignment || httpUser {
                let equals = source.range(of: "=", range: token.range)
                if equals.location != NSNotFound {
                    let part = String(value.dropFirst(key.count + 1))
                    add(NSRange(location: NSMaxRange(equals), length: NSMaxRange(token.range) - NSMaxRange(equals)), value: part, closingQuote: isQuoted(NSMaxRange(equals), in: token))
                }
            }
            if !value.contains("="), options.contains(value.lowercased()) || httpUser {
                if index + 1 < tokens.count, tokens[index + 1].group == token.group {
                    let next = tokens[index + 1]
                    add(next.range, value: next.value)
                }
            }
            if hasHTTP, value.hasPrefix("-u"), value.count > 2, !value.hasPrefix("--") {
                add(NSRange(location: token.range.location + 2, length: token.range.length - 2), value: String(value.dropFirst(2)))
            }
            if value.hasPrefix("{") || value.hasPrefix("[") {
                let jsonKeys: Set<String> = ["password", "passwd", "token", "api_key", "apikey", "access_token", "accesstoken", "refresh_token", "refreshtoken", "client_secret", "clientsecret", "secret", "authorization", "cookie"]
                func containsCredential(_ object: Any) -> Bool {
                    if let dictionary = object as? [String: Any] {
                        return dictionary.contains { key, item in
                            (jsonKeys.contains(key.lowercased()) && (item as? String).map { !$0.isEmpty && !isReference($0) } == true)
                                || containsCredential(item)
                        }
                    }
                    if let array = object as? [Any] { return array.contains(where: containsCredential) }
                    return false
                }
                if let json = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: json), containsCredential(object) {
                    let pattern = #"(?i)"(?:password|passwd|token|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|authorization|cookie)"\s*:\s*("(?:\\.|[^"\\])*")"#
                    let regex = try? NSRegularExpression(pattern: pattern)
                    let matches = regex?.matches(in: command, range: token.range) ?? []
                    if matches.isEmpty { add(token.range) }
                    else { for match in matches { add(match.range(at: 1)) } }
                }
            }
            // Header values can contain spaces and semicolons inside quotes.
            let header = value.hasPrefix("--header=") ? String(value.dropFirst(9)) : value.hasPrefix("-H") ? String(value.dropFirst(2)) : value
            if let colon = header.firstIndex(of: ":"), ["authorization", "proxy-authorization", "cookie", "x-api-key", "x-auth-token"].contains(header[..<colon].lowercased()) {
                let rawColon = source.range(of: ":", range: token.range)
                var start = NSMaxRange(rawColon)
                while start < NSMaxRange(token.range), [32, 9].contains(source.character(at: start)) { start += 1 }
                let suffix = source.substring(with: NSRange(location: start, length: NSMaxRange(token.range) - start))
                let scheme = suffix.range(of: #"(?i)^(?:Bearer|Basic)\s+"#, options: .regularExpression)
                if let scheme { start += (String(suffix[scheme]) as NSString).length }
                let literal = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"(?i)^(Bearer|Basic)\s+"#, with: "", options: .regularExpression)
                add(NSRange(location: start, length: NSMaxRange(token.range) - start), value: literal, closingQuote: isQuoted(start, in: token))
            }
        }
        matches(#"(?i)://([^\s/\"'@]+)@"#)
        matches(#"(?i)[?&](?:api[_-]?key|access_token|auth_token|token|password|client_secret|signature|sig|auth|key)=([^&#\s\"'<>]+)"#)
        matches(#"\b(sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9_]{10,}|github_pat_[A-Za-z0-9_]{10,})"#)
        // Merge overlaps before replacing in reverse source order.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, range) }
            else { merged.append(range) }
        }
        let result = NSMutableString(string: command)
        for range in merged.reversed() { result.replaceCharacters(in: range, with: mask) }
        return result as String
    }

    private static func tokenize(_ command: String) -> [Token] {
        let input = Array(command.utf16)
        var result: [Token] = [], index = 0, group = 0
        while index < input.count {
            if [10, 13, 59, 124, 38].contains(input[index]) { group += 1; index += 1; continue }
            if [32, 9, 60, 62].contains(input[index]) { index += 1; continue }
            let start = index
            var quote: UInt16?, value: [UInt16] = []
            while index < input.count {
                let c = input[index]
                if c == 92, quote != 39, index + 1 < input.count { value.append(input[index + 1]); index += 2; continue }
                if let current = quote {
                    if c == current { quote = nil } else { value.append(c) }
                } else if c == 34 || c == 39 { quote = c }
                else if [32, 9, 10, 13, 59, 124, 38, 60, 62].contains(c) { break }
                else { value.append(c) }
                index += 1
            }
            result.append(.init(range: NSRange(location: start, length: index - start), value: String(decoding: value, as: UTF16.self), group: group))
        }
        return result
    }
}
