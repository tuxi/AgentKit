import SwiftUI

/// The entry lives beside the shared native composer on macOS and iOS.
/// Log streams are opened only by the explicit full-log action.
struct BackgroundJobsEntry: View {
    let model: BackgroundJobsModel
    let onLogs: (BackgroundJobSnapshot) -> Void
    @State private var presented = false
    @Environment(\.scenePhase) private var scenePhase
    private let text = ToolTranscriptText()
    var body: some View {
        Group {
            if model.shouldShow {
                Button { presented = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "terminal")
                        Text(model.canControl && model.runningCount > 0
                             ? text.text("jobs.runningCount", model.runningCount)
                             : text.text(model.isStale ? "jobs.unavailable" : "jobs.title"))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up").font(.caption2)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("background-jobs-entry")
            }
        }
        .task(id: model.conversationID) {
            model.setVisible(scenePhase == .active)
            await model.refresh()
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            model.setVisible(phase == .active)
            if phase == .active { Task { await model.refresh() } }
        }
        .onChange(of: model.conversationID) { _, _ in presented = false }
        #if os(macOS)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            panel.frame(width: 520, height: 440)
        }
        #else
        .sheet(isPresented: $presented) {
            panel
        }
        #endif
    }
    private var panel: some View {
        BackgroundJobsPanel(model: model, onLogs: { job in
            presented = false
            onLogs(job)
        })
    }
}

struct BackgroundJobsPanel: View {
    let model: BackgroundJobsModel
    let onLogs: (BackgroundJobSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    private let text = ToolTranscriptText()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(text.text("jobs.title")).font(.headline)
                Spacer()
                Button { Task { await model.refresh(rediscover: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(model.isRefreshing).help(text.text("jobs.retry"))
                Button(text.text("jobs.done")) { dismiss() }
            }.padding(16)
            Divider()
            if model.support == .unsupported || model.isStale {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.support == .unsupported ? text.text("jobs.unsupported")
                         : model.error ?? text.text("jobs.unavailable"))
                    Text(text.text("jobs.noConfirmation")).foregroundStyle(.secondary)
                    Button(text.text("jobs.retry")) { Task { await model.refresh(rediscover: true) } }
                        .disabled(model.isRefreshing)
                }.font(.callout).padding(16)
            }
            if model.isRefreshing { ProgressView().controlSize(.small).padding(12) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.jobs.isEmpty && !model.isStale {
                        Text(text.text("jobs.empty")).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(model.jobs) { job in jobRow(job) }
                }.padding(16)
            }
        }
        .frame(idealWidth: 520, idealHeight: 440)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
    private func jobRow(_ job: BackgroundJobSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(BackgroundJobPresentation.summary(job.command, text: .init())).font(.system(size: 13, weight: .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(status(job)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(text.text("job.elapsed", String(format: "%.1fs", Double(job.durationMs) / 1000)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            if !job.outputTail.isEmpty {
                Text(String(job.outputTail.suffix(2000))).font(.system(size: 12, design: .monospaced))
                    .lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(text.text("jobs.logs")) { onLogs(job) }
                    .disabled(model.isStale || model.support != .supported)
                Spacer()
                if job.status == .running {
                    Button(text.text(job.cancelRequested || model.stopping.contains(job.owner) ? "jobs.stopping" : "jobs.stop")) {
                        Task { await model.stop(job.owner) }
                    }.disabled(!model.canControl || job.cancelRequested || model.stopping.contains(job.owner))
                }
            }.font(.system(size: 12))
            if let error = model.stopErrors[job.owner] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
    private func status(_ job: BackgroundJobSnapshot) -> String {
        if model.isStale { return text.text("jobs.unavailable") }
        if job.cancelRequested && job.status == .running { return text.text("jobs.stopping") }
        return text.text("jobs.status.\(job.status.rawValue)")
    }
}
