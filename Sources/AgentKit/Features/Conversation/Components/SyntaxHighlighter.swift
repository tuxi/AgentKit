//
//  SyntaxHighlighter.swift
//  AgentKit
//
//  Lightweight regex-based syntax highlighter for code blocks.
//  Supports Swift, Python, Bash, JSON, YAML, JavaScript, TypeScript, Go.
//  Outputs AttributedString ready for SwiftUI Text rendering.
//

import SwiftUI

// MARK: - SyntaxHighlighter

public struct SyntaxHighlighter {

    /// Highlight source code for a given language.
    /// - Returns: AttributedString with syntax coloring applied.
    public static func highlight(_ code: String, language: String) -> AttributedString {
        let rules = rulesFor(language: language)
        var attributed = AttributedString(code)
        // Default monospace font
        attributed.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        attributed.foregroundColor = .labelColor

        // Apply each rule — later rules override earlier ones (higher priority)
        for rule in rules {
            apply(rule: rule, to: &attributed, in: code)
        }

        return attributed
    }

    /// Infer language from a lowercase identifier string.
    public static func inferLanguage(from identifier: String?) -> String {
        guard let id = identifier?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return "text"
        }
        let mapping: [String: String] = [
            "swift": "swift",
            "python": "python", "py": "python",
            "bash": "bash", "sh": "bash", "shell": "bash", "zsh": "bash",
            "json": "json",
            "yaml": "yaml", "yml": "yaml",
            "javascript": "javascript", "js": "javascript",
            "typescript": "typescript", "ts": "typescript",
            "go": "go", "golang": "go",
            "rust": "rust", "rs": "rust",
            "java": "java",
            "kotlin": "kotlin", "kt": "kotlin",
            "c": "c",
            "cpp": "cpp", "c++": "cpp",
            "sql": "sql",
            "html": "html",
            "css": "css",
            "markdown": "markdown", "md": "markdown",
            "ruby": "ruby", "rb": "ruby",
        ]
        return mapping[id] ?? "text"
    }
}

// MARK: - Highlight Rules

private struct HighlightRule: Sendable {
    let pattern: String
    let color: NSColor
    let isBold: Bool
    let isRegex: Bool
}

private extension SyntaxHighlighter {

    static func rulesFor(language: String) -> [HighlightRule] {
        var rules: [HighlightRule] = []

        // ── Universal rules (applied to all languages) ──
        // Numbers
        rules.append(HighlightRule(pattern: "\\b\\d+\\.?\\d*\\b", color: .systemOrange, isBold: false, isRegex: true))

        // ── Language-specific rules ──
        switch language.lowercased() {
        case "swift":
            rules.append(contentsOf: swiftRules)
        case "python", "py":
            rules.append(contentsOf: pythonRules)
        case "bash", "sh", "shell", "zsh":
            rules.append(contentsOf: bashRules)
        case "json":
            rules.append(contentsOf: jsonRules)
        case "yaml", "yml":
            rules.append(contentsOf: yamlRules)
        case "javascript", "js", "typescript", "ts":
            rules.append(contentsOf: jsRules)
        case "go", "golang":
            rules.append(contentsOf: goRules)
        default:
            rules.append(contentsOf: genericRules)
        }

        // ── Strings (highest priority, applied last) ──
        rules.append(HighlightRule(pattern: "\"[^\"]*\"", color: .systemRed, isBold: false, isRegex: true))
        rules.append(HighlightRule(pattern: "`[^`]*`", color: .systemRed, isBold: false, isRegex: true))
        // Single-line comments
        rules.append(HighlightRule(pattern: "//.*", color: .systemGreen, isBold: false, isRegex: true))
        rules.append(HighlightRule(pattern: "#.*", color: .systemGreen, isBold: false, isRegex: true))

        return rules
    }

    // MARK: - Language rule sets

    static var swiftRules: [HighlightRule] {
        let keywords = ["import", "struct", "class", "enum", "protocol", "extension",
                        "func", "var", "let", "mutating", "nonmutating", "inout",
                        "public", "private", "internal", "fileprivate", "open",
                        "static", "final", "override", "required", "convenience",
                        "init", "deinit", "self", "super", "guard", "if", "else",
                        "switch", "case", "default", "for", "while", "repeat",
                        "return", "throw", "throws", "try", "catch", "do", "where",
                        "async", "await", "actor", "nonisolated", "isolated",
                        "some", "any", "true", "false", "nil", "associatedtype",
                        "typealias", "get", "set", "willSet", "didSet", "weak", "unowned"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
            // Type annotations
            HighlightRule(pattern: ":\\s*\\b[A-Z][A-Za-z0-9]*\\b", color: .systemTeal, isBold: false, isRegex: true),
        ]
    }

    static var pythonRules: [HighlightRule] {
        let keywords = ["import", "from", "def", "class", "return", "if", "elif", "else",
                        "for", "while", "in", "with", "as", "try", "except", "finally",
                        "raise", "yield", "lambda", "pass", "break", "continue",
                        "and", "or", "not", "is", "None", "True", "False",
                        "async", "await", "self", "print"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
            // Decorators
            HighlightRule(pattern: "@\\w+", color: .systemPurple, isBold: false, isRegex: true),
        ]
    }

    static var bashRules: [HighlightRule] {
        let keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                        "case", "esac", "in", "function", "return", "exit", "export",
                        "local", "source", "echo", "cd", "ls", "cat", "grep", "sed", "awk"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
            // Variables
            HighlightRule(pattern: "\\$[A-Za-z_][A-Za-z0-9_]*", color: .systemMint, isBold: false, isRegex: true),
            HighlightRule(pattern: "\\$\\{[^}]+\\}", color: .systemMint, isBold: false, isRegex: true),
        ]
    }

    static var jsonRules: [HighlightRule] {
        return [
            // Keys
            HighlightRule(pattern: "\"[^\"]+\"\\s*:", color: .systemBlue, isBold: false, isRegex: true),
            // Booleans and null
            HighlightRule(pattern: "\\b(true|false|null)\\b", color: .systemOrange, isBold: true, isRegex: true),
        ]
    }

    static var yamlRules: [HighlightRule] {
        return [
            // Keys
            HighlightRule(pattern: "^\\s*[A-Za-z_][A-Za-z0-9_]*\\s*:", color: .systemBlue, isBold: false, isRegex: true),
            // Booleans
            HighlightRule(pattern: "\\b(true|false|null|yes|no)\\b", color: .systemOrange, isBold: true, isRegex: true),
        ]
    }

    static var jsRules: [HighlightRule] {
        let keywords = ["import", "export", "from", "const", "let", "var", "function",
                        "class", "extends", "return", "if", "else", "for", "while",
                        "switch", "case", "break", "continue", "new", "this", "super",
                        "try", "catch", "finally", "throw", "async", "await",
                        "true", "false", "null", "undefined", "typeof", "instanceof",
                        "interface", "type", "enum", "implements"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
            // Arrow functions
            HighlightRule(pattern: "=>", color: .systemPurple, isBold: false, isRegex: true),
        ]
    }

    static var goRules: [HighlightRule] {
        let keywords = ["package", "import", "func", "type", "struct", "interface",
                        "var", "const", "return", "if", "else", "for", "range",
                        "switch", "case", "default", "break", "continue", "go",
                        "defer", "chan", "select", "map", "make", "append", "len",
                        "nil", "true", "false", "error", "string", "int", "bool"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
        ]
    }

    static var genericRules: [HighlightRule] {
        let keywords = ["function", "return", "if", "else", "for", "while", "var", "let",
                        "const", "class", "import", "export", "true", "false", "null", "nil"]
        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return [
            HighlightRule(pattern: kwPattern, color: .systemPink, isBold: true, isRegex: true),
        ]
    }

    // MARK: - Apply rule to AttributedString

    static func apply(rule: HighlightRule, to attributed: inout AttributedString, in source: String) {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.dotMatchesLineSeparators]) else {
            return
        }

        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)

        for match in matches.reversed() {
            guard let attrRange = Range(match.range, in: attributed) else { continue }

            // Apply color
            attributed[attrRange].foregroundColor = rule.color

            // Apply bold weight if specified
            if rule.isBold {
                attributed[attrRange].font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            }
        }
    }
}
