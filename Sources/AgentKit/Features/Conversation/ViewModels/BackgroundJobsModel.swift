import Foundation
import Observation

struct BackgroundJobOperations: Sendable {
    var identity: @Sendable () async throws -> String
    var capabilities: @Sendable () async throws -> RuntimeCapabilitySnapshot
    var list: @Sendable (String, String) async throws -> [BackgroundJobSnapshot]
    var cancel: @Sendable (String, BackgroundJobOwner, String) async throws -> BackgroundJobSnapshot
    init(client: any RuntimeClient) {
        identity = { try await client.backgroundJobRuntimeIdentity() }
        capabilities = { try await client.runtimeCapabilities() }
        list = { try await client.listBackgroundJobs(conversationID: $0, runtimeIdentity: $1) }
        cancel = { try await client.cancelBackgroundJob(conversationID: $0, owner: $1, runtimeIdentity: $2) }
    }
    init(identity: @escaping @Sendable () async throws -> String,
         capabilities: @escaping @Sendable () async throws -> RuntimeCapabilitySnapshot,
         list: @escaping @Sendable (String, String) async throws -> [BackgroundJobSnapshot],
         cancel: @escaping @Sendable (String, BackgroundJobOwner, String) async throws -> BackgroundJobSnapshot) {
        self.identity = identity; self.capabilities = capabilities; self.list = list; self.cancel = cancel
    }
}

/// Registry state is scoped to a conversation AND Runtime origin. No Turn owns
/// this model; neither ending a Turn nor closing its stream cancels a process.
@MainActor @Observable
final class BackgroundJobsModel {
    enum Support { case checking, supported, unsupported }
    private(set) var jobs: [BackgroundJobSnapshot] = []
    private(set) var support: Support = .checking
    private(set) var isStale = true
    private(set) var isRefreshing = false
    private(set) var error: String?
    private(set) var stopErrors: [BackgroundJobOwner: String] = [:]
    private(set) var stopping: Set<BackgroundJobOwner> = []
    private(set) var conversationID: String?
    private(set) var runtimeIdentity: String?
    var hasHistoricalJobs = false
    var onSnapshot: (@MainActor ([BackgroundJobSnapshot]?) async -> Void)?
    private let pollInterval: Duration
    private let operations: BackgroundJobOperations
    private var generation = UUID()
    private var request = UUID()
    private var mutation = 0
    private var visible = false
    private var poll: Task<Void, Never>?
    var runningCount: Int { jobs.filter { $0.status == .running }.count }
    var shouldShow: Bool { !jobs.isEmpty || hasHistoricalJobs || error != nil }
    var canControl: Bool { support == .supported && !isStale }
    init(operations: BackgroundJobOperations, pollInterval: Duration = .seconds(3)) { self.operations = operations; self.pollInterval = pollInterval }
    convenience init(client: any RuntimeClient) { self.init(operations: .init(client: client)) }

    func select(_ id: String?) {
        guard conversationID != id else { return }
        generation = UUID(); request = UUID(); conversationID = id; runtimeIdentity = nil
        jobs = []; stopping = []; stopErrors = [:]; support = .checking
        isStale = true; error = nil; isRefreshing = false; hasHistoricalJobs = false
        poll?.cancel(); poll = nil
    }
    func setVisible(_ value: Bool) {
        visible = value
        if !value { poll?.cancel(); poll = nil } else { schedulePoll() }
    }
    func refresh(rediscover: Bool = false) async {
        guard let conversationID else { return }
        poll?.cancel(); poll = nil
        let token = UUID(); request = token
        let scope = generation; let version = mutation
        isRefreshing = true
        defer { if generation == scope && request == token { isRefreshing = false; schedulePoll() } }
        do {
            let origin = try await operations.identity()
            guard generation == scope, request == token else { return }
            if runtimeIdentity != origin {
                runtimeIdentity = origin; jobs = []; stopping = []; stopErrors = [:]
                support = .checking; isStale = true
                await onSnapshot?(nil)
            }
            if support != .supported || rediscover {
                let capabilities = try await operations.capabilities()
                guard generation == scope, request == token else { return }
                guard try await operations.identity() == origin else { throw BackgroundJobControlError.runtimeChanged }
                guard capabilities.flags.contains(.backgroundJobControl) else {
                    support = .unsupported; isStale = true; error = nil
                    await onSnapshot?(nil); return
                }
                support = .supported
            }
            let result = try await operations.list(conversationID, origin)
            guard generation == scope, request == token, version == mutation else { return }
            guard try await operations.identity() == origin else { throw BackgroundJobControlError.runtimeChanged }
            guard result.allSatisfy({ $0.sessionID == conversationID }) else { throw BackgroundJobControlError.invalidSnapshot }
            // Terminal observations are absorbing for one registry owner, even
            // when a list read races the final cancel response.
            jobs = result.map { incoming in
                if let old = jobs.first(where: { $0.owner == incoming.owner }), old.status.isTerminal,
                   !incoming.status.isTerminal { return old }
                return incoming
            }
            isStale = false; error = nil
            await onSnapshot?(jobs)
        } catch {
            guard generation == scope, request == token else { return }
            isStale = true
            if let http = error as? RuntimeHTTPError, case .unsupported = http { support = .unsupported; self.error = nil }
            else if let http = error as? RuntimeHTTPError, case .notFound = http { support = .unsupported; self.error = nil }
            else { self.error = ToolTranscriptText().text("jobs.refreshFailed") }
            await onSnapshot?(nil)
        }
    }
    func stop(_ owner: BackgroundJobOwner) async {
        guard canControl, let conversationID, let origin = runtimeIdentity,
              jobs.contains(where: { $0.owner == owner && $0.status == .running && !$0.cancelRequested }),
              !stopping.contains(owner) else { return }
        let scope = generation
        mutation += 1; request = UUID(); isRefreshing = false
        stopping.insert(owner); stopErrors[owner] = nil
        poll?.cancel(); poll = nil
        do {
            guard try await operations.identity() == origin else { throw BackgroundJobControlError.runtimeChanged }
            let result = try await operations.cancel(conversationID, owner, origin)
            guard generation == scope, runtimeIdentity == origin else { return }
            guard try await operations.identity() == origin else { throw BackgroundJobControlError.runtimeChanged }
            guard result.owner == owner, result.sessionID == conversationID else { throw BackgroundJobControlError.invalidSnapshot }
            if let index = jobs.firstIndex(where: { $0.owner == owner }), !jobs[index].status.isTerminal {
                jobs[index] = result
            }
            mutation += 1
            stopping.remove(owner)
            await onSnapshot?(jobs)
            if stopping.isEmpty { await refresh() }
        } catch {
            guard generation == scope else { return }
            stopping.remove(owner)
            stopErrors[owner] = ToolTranscriptText().text("jobs.stopFailed")
            // A control failure says nothing about process termination. Require
            // an explicit refresh before offering another control request.
            isStale = true
            await onSnapshot?(nil)
        }
    }
    private func schedulePoll() {
        guard visible, canControl, runningCount > 0, !isRefreshing, stopping.isEmpty, poll == nil else { return }
        let interval = pollInterval
        poll = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.poll = nil
            await self.refresh()
        }
    }
}
