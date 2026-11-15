import Foundation

enum SessionRailJobPresentation {
    static func status(snapshot: BackgroundJobStatus, registry: BackgroundJobStatus?) -> BackgroundJobStatus {
        snapshot.isTerminal ? snapshot : registry ?? snapshot
    }

    static func elapsed(status: BackgroundJobStatus, recorded: Int64?, startedAt: String?, now: Date) -> TimeInterval? {
        let duration = recorded.map { max(0, Double($0) / 1000) }
        guard status == .running, let startedAt else { return duration }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt)
        guard let start else { return duration }
        return max(duration ?? 0, max(0, now.timeIntervalSince(start)))
    }
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
