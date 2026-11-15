#if os(macOS)
import SwiftUI

struct SessionRailJobDuration: View {
    let job: SessionRailJob
    let status: BackgroundJobStatus
    let liveDuration: Int64?
    let ticks: Bool
    var body: some View {
        Group {
            if ticks { TimelineView(.periodic(from: .now, by: 1)) { label(at: $0.date) } }
            else { label(at: .now) }
        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
    }
    private func label(at now: Date) -> some View {
        let recorded = [liveDuration, job.durationMs].compactMap { $0 }.max()
        let elapsed = SessionRailJobPresentation.elapsed(status: status, recorded: recorded, startedAt: job.startedAt, now: now)
        return Text(elapsed.map(SessionRailJobPresentation.format) ?? "—").accessibilityLabel("运行时长 " + (elapsed.map(SessionRailJobPresentation.format) ?? "未知"))
    }
}
#endif
