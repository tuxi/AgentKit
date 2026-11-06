import Foundation

/// Deliberately accepts a small, literal subset of shell syntax. It is a
/// display parser, never a shell evaluator. Anything uncertain stays a command.
enum ToolCommandPresentation {
    struct Summary {
        let family: ToolTranscriptFamily
        let title: String
        let detail: String?
    }

    static func preview(_ command: String, text: ToolTranscriptText) -> String {
        hasSensitiveArguments(command) ? text.text("hidden") : ToolTranscriptText.bounded(command, limit: 160)
    }

    static func hasSensitiveArguments(_ command: String) -> Bool {
        let sample = String(command.prefix(8192)).lowercased()
        let markers = ["password", "passwd", "token", "secret", "api_key", "api-key", "authorization", "bearer ",
                       "credential", "private-key", "access-key", "cookie", "sk-", "ghp_", "github_pat_", "--key", "--auth", "x-auth"]
        if markers.contains(where: sample.contains) { return true }
        // Credentials in URLs or environment assignments are not suitable for a
        // compact preview. Hide the whole preview instead of guessing value bounds.
        return sample.range(of: #"://[^\s/]*@|(^|[\s;])[a-z_][a-z0-9_]*=|(^|\s)(-u|--user)(\s|=)|[?&](?:key|auth|api_key|access_token)="#, options: .regularExpression) != nil
    }

    static func summarize(_ command: String, text: ToolTranscriptText) -> Summary? {
        guard !hasSensitiveArguments(command), let words = literalWords(command), let executable = words.first else { return nil }
        switch executable {
        case "grep", "rg", "/usr/bin/grep": return search(Array(words.dropFirst()), ripgrep: executable == "rg", text: text)
        case "sed", "/usr/bin/sed":
            guard words.count == 4, words[1] == "-n", let range = lineRange(words[2]), validPath(words[3]) else { return nil }
            return Summary(family: .read, title: text.text("view.lines", basename(words[3]), range.0, range.1), detail: bounded(words[3]))
        case "find", "/usr/bin/find": return find(Array(words.dropFirst()), text: text)
        case "xxd", "/usr/bin/xxd": return hex(Array(words.dropFirst()), text: text)
        default: return nil
        }
    }

    /// Single/double quotes may delimit literal arguments and paths with spaces.
    /// No interpolation, escape processing, globs, comments, pipelines or scripts.
    static func literalWords(_ command: String) -> [String]? {
        guard command.utf8.count <= 4096 else { return nil }
        var words: [String] = [], word = ""
        var quote: Character?, started = false, closedQuote = false
        for character in command {
            if character.isNewline || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) { return nil }
            if let current = quote {
                if character == current { quote = nil; closedQuote = true }
                else {
                    if current == "\"", "$`\\".contains(character) { return nil }
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                // Concatenated quoted/unquoted fragments are intentionally outside
                // this small grammar, including quoted executable names.
                guard !started else { return nil }
                quote = character
                started = true
            } else if character == " " || character == "\t" {
                if started { words.append(word); word = ""; started = false; closedQuote = false }
            } else {
                guard !";&|<>$()`\\*?[]{}~#!".contains(character) else { return nil }
                // Reject a token suffix after a closed quoted fragment.
                if closedQuote { return nil }
                word.append(character)
                started = true
            }
            if word.utf8.count > 512 || words.count > 64 { return nil }
        }
        guard quote == nil else { return nil }
        if started { words.append(word) }
        return words.isEmpty ? nil : words
    }

    private static func search(_ words: [String], ripgrep: Bool, text: ToolTranscriptText) -> Summary? {
        var pattern: String?, operands: [String] = [], index = 0, options = true
        let commonFlags: Set<String> = ["--line-number", "--ignore-case", "--fixed-strings", "--files-with-matches"]
        let flags = ripgrep ? commonFlags.union(["--hidden", "--no-heading"]) : commonFlags
        let shortOptions = ripgrep ? "niIlHswFc" : "nirRlHhsIwFEc"
        while index < words.count {
            let word = words[index]
            if options && word == "--" { options = false }
            else if options && ["-e", "--regexp", "-g", "--glob"].contains(word) {
                guard index + 1 < words.count, ripgrep || (word != "-g" && word != "--glob") else { return nil }
                index += 1
                if word == "-e" || word == "--regexp" {
                    guard pattern == nil else { return nil }
                    pattern = words[index]
                }
            } else if options && word.hasPrefix("-") {
                let shortFlags = word.hasPrefix("-") && !word.hasPrefix("--") && word.count > 1
                    && word.dropFirst().allSatisfy { shortOptions.contains($0) }
                guard flags.contains(word) || shortFlags else { return nil }
            } else { operands.append(word) }
            index += 1
        }
        if pattern == nil, !operands.isEmpty { pattern = operands.removeFirst() }
        guard let pattern, !pattern.isEmpty, operands.count <= 4, operands.allSatisfy(validPath) else { return nil }
        let scope = operands.isEmpty ? nil : text.text("scope", bounded(operands.joined(separator: ", ")))
        return Summary(family: .search, title: text.text("search", bounded(pattern)), detail: scope)
    }

    private static func find(_ words: [String], text: ToolTranscriptText) -> Summary? {
        guard let path = words.first, validPath(path) else { return nil }
        var index = 1, filesOnly = false, pattern: String?
        while index < words.count {
            let option = words[index]
            if option == "-print" { guard index == words.count - 1 else { return nil }; break }
            guard index + 1 < words.count else { return nil }
            let value = words[index + 1]
            switch option {
            case "-type": guard value == "f" else { return nil }; filesOnly = true
            case "-name", "-iname": guard pattern == nil else { return nil }; pattern = value
            case "-maxdepth", "-mindepth": guard number(value) != nil else { return nil }
            default: return nil // -exec, -delete, expressions and other side effects
            }
            index += 2
        }
        return Summary(family: .search, title: text.text(filesOnly ? "find.files" : "find", bounded(path)), detail: pattern.map(bounded))
    }

    private static func hex(_ words: [String], text: ToolTranscriptText) -> Summary? {
        var index = 0, length: Int?, offset = 0
        while index < words.count - 1 {
            let option = words[index]
            if option == "-p" || option == "-u" { index += 1; continue }
            guard ["-l", "-s", "-g", "-c"].contains(option), index + 1 < words.count - 1,
                  let value = number(words[index + 1]) else { return nil }
            if option == "-l" { guard length == nil, value > 0 else { return nil }; length = value }
            if option == "-s" { offset = value }
            index += 2
        }
        guard index == words.count - 1, let path = words.last, validPath(path) else { return nil }
        return Summary(family: .read, title: text.text(length != nil && offset == 0 ? "hex.head" : "hex", basename(path)), detail: bounded(path))
    }

    private static func lineRange(_ script: String) -> (Int, Int)? {
        guard script.hasSuffix("p") else { return nil }
        let values = script.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(values.count), let first = number(String(values[0])), first > 0,
              let last = values.count == 2 ? number(String(values[1])) : first, last >= first else { return nil }
        return (first, last)
    }
    private static func number(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), number <= 10_000_000 else { return nil }
        return number
    }
    private static func validPath(_ value: String) -> Bool { !value.isEmpty && value != "-" && !value.hasPrefix("-") }
    private static func basename(_ value: String) -> String { bounded((value as NSString).lastPathComponent) }
    private static func bounded(_ value: String) -> String { ToolTranscriptText.bounded(value) }
}
