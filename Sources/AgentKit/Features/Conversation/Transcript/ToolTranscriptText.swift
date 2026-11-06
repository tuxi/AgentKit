import Foundation

/// Tool UI strings come from the same package/host string catalog as the rest
/// of AgentKit. Explicit locales allow deterministic tests without global state.
struct ToolTranscriptText {
    var locale: String? = nil

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let fullKey = "transcript.tool.\(key)"
        let host = AgentKitLocalized.bundle
        let selected: Bundle
        if let locale {
            let path = host.path(forResource: locale, ofType: "lproj")
                ?? Bundle.module.path(forResource: "en", ofType: "lproj")
            selected = path.flatMap(Bundle.init(path:)) ?? host
        } else { selected = host }
        var format = NSLocalizedString(fullKey, bundle: selected, value: fullKey, comment: "")
        if format == fullKey, let path = Bundle.module.path(forResource: "en", ofType: "lproj"),
           let english = Bundle(path: path) {
            format = NSLocalizedString(fullKey, bundle: english, value: fullKey, comment: "")
        }
        return String(format: format, locale: Locale(identifier: locale ?? Locale.current.identifier), arguments: arguments)
    }

    func thinkingTitle(streaming: Bool) -> String { text(streaming ? "thinking" : "thought") }

    static func bounded(_ value: String, limit: Int = 120) -> String {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(clean))
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
