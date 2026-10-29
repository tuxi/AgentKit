import Foundation
import Observation

public enum CodingTaskReadError: LocalizedError {
    case protocolMismatch, identityChanged, artifactMismatch
    public var errorDescription: String? {
        switch self {
        case .protocolMismatch: "任务数据或事件游标不一致，请刷新。"
        case .identityChanged: "Runtime 或 Store 已切换，正在重新读取任务。"
        case .artifactMismatch: "冻结产物与选中的审查版本不匹配。"
        }
    }
}

/// Exact comparison for arbitrary-size unsigned decimal wire cursors.
public enum CodingTaskSequence {
    public static func valid(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) } }
    public static func less(_ a: String, _ b: String) -> Bool {
        let x = String(a.drop(while: { $0 == "0" })), y = String(b.drop(while: { $0 == "0" }))
        return x.count == y.count ? x < y : x.count < y.count
    }
}

public struct CodingTaskHistory: Sendable {
    public private(set) var events: [CodingTaskEvent] = []
    public private(set) var cursor = "0"
    public init() {}
    public mutating func append(_ page: CodingTaskEventPage, taskID: String) throws {
        guard page.task_id == taskID, page.after == cursor, !page.resync_required,
              CodingTaskSequence.valid(page.next_cursor), !CodingTaskSequence.less(page.next_cursor, cursor),
              !page.has_more || CodingTaskSequence.less(cursor, page.next_cursor),
              page.events.allSatisfy({ $0.task_id == taskID && CodingTaskSequence.valid($0.task_seq)
                  && CodingTaskSequence.valid($0.task_revision) && !CodingTaskSequence.less(page.next_cursor, $0.task_seq) })
        else { throw CodingTaskReadError.protocolMismatch }
        var byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for event in page.events { byID[event.id] = event }
        events = byID.values.sorted { CodingTaskSequence.less($0.task_seq, $1.task_seq) }
        cursor = page.next_cursor
    }
}

/// View-scoped: a new client/auth context gets a new Store. Nothing is written to Runtime.
@MainActor @Observable
public final class CodingTaskStore {
    public private(set) var capabilities: CodingTaskCapabilities?
    public private(set) var tasks: [CodingTaskSummary] = []
    public private(set) var selectedID: String?
    public private(set) var snapshot: CodingTaskSnapshot?
    public private(set) var history = CodingTaskHistory()
    public private(set) var historyLoaded = false
    public private(set) var errorMessage: String?
    public private(set) var loading = false
    private let reader: (any CodingTaskReading)?
    private var generation = UUID()

    public init(reader: (any CodingTaskReading)?) { self.reader = reader }

    public func select(_ id: String?) {
        guard id != selectedID else { return }
        generation = UUID(); selectedID = id; snapshot = nil
        history = CodingTaskHistory(); historyLoaded = false; errorMessage = nil
    }

    /// One polling task per mounted view; cancelling it discards all in-flight results.
    public func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let token = generation
        do {
            guard let reader else { throw RuntimeHTTPError.unsupported }
            let caps = try await reader.codingTaskCapabilities()
            try Task.checkCancellation()
            guard token == generation else { return }
            guard caps.capabilities.contains("task_timeline_v1"), !caps.server_id.isEmpty, !caps.store_id.isEmpty else {
                throw RuntimeHTTPError.unsupported
            }
            if let old = capabilities, old.identity != caps.identity {
                throw CodingTaskReadError.identityChanged
            }
            capabilities = caps
            let list = try await reader.codingTasks()
            let id = selectedID
            var next: CodingTaskSnapshot?
            var nextHistory = history
            if let id {
                next = try await reader.codingTaskSnapshot(id: id)
                guard next?.task_id == id, next?.schema == "task-snapshot/v1",
                      CodingTaskSequence.valid(next!.revision), CodingTaskSequence.valid(next!.snapshot_task_seq)
                else { throw CodingTaskReadError.protocolMismatch }
                var more = true
                while more {
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    let page = try await reader.codingTaskEvents(id: id, after: nextHistory.cursor)
                    try nextHistory.append(page, taskID: id)
                    more = page.has_more
                }
                // Snapshot and historical projection have different purposes. Never reduce old events into current state.
                if CodingTaskSequence.less(next!.snapshot_task_seq, nextHistory.cursor) {
                    next = try await reader.codingTaskSnapshot(id: id)
                }
            }
            let confirmed = try await reader.codingTaskCapabilities()
            try Task.checkCancellation()
            guard token == generation else { return }
            guard confirmed.identity == caps.identity else { throw CodingTaskReadError.identityChanged }
            tasks = list
            if let next {
                guard next.task_id == selectedID, next.schema == "task-snapshot/v1",
                      CodingTaskSequence.valid(next.revision),
                      snapshot.map({ !CodingTaskSequence.less(next.revision, $0.revision) }) ?? true else {
                    throw CodingTaskReadError.protocolMismatch
                }
                snapshot = next; history = nextHistory; historyLoaded = true
            }
            errorMessage = nil
        } catch is CancellationError {
            // View left/backgrounded; the next mounted task can safely read again.
        } catch {
            guard token == generation else { return }
            // A cursor/protocol failure rebuilds history on the next read; no command is resubmitted.
            if error is CodingTaskReadError {
                history = CodingTaskHistory(); historyLoaded = false
                if case CodingTaskReadError.identityChanged = error {
                    generation = UUID()
                    capabilities = nil; tasks = []; snapshot = nil; selectedID = nil
                }
            }
            errorMessage = Self.message(error)
            if case RuntimeHTTPError.unexpectedStatus(let code, _) = error, code == 403 {
                tasks = []; snapshot = nil; history = CodingTaskHistory(); historyLoaded = false
            }
        }
    }

    public func bundle(for artifact: CodingTaskArtifact) async throws -> CodingTaskReviewBundle {
        guard let reader, let snapshot, let caps = capabilities,
              artifact.capture_mode == "immutable", artifact.kind == "review_bundle",
              artifact.content_hash?.isEmpty == false,
              snapshot.artifact_refs.contains(where: { $0.id == artifact.id && $0.version == artifact.version && $0.content_hash == artifact.content_hash })
        else { throw CodingTaskReadError.artifactMismatch }
        let token = generation
        guard try await reader.codingTaskCapabilities().identity == caps.identity else { throw CodingTaskReadError.identityChanged }
        let bundle = try await reader.codingTaskBundle(taskID: snapshot.task_id, artifactID: artifact.id)
        let current = try await reader.codingTaskCapabilities()
        try Task.checkCancellation()
        guard token == generation, current.identity == caps.identity,
              bundle.schema == "coding_review_bundle_v1",
              bundle.source["server_id"]?.text == caps.server_id, bundle.source["store_id"]?.text == caps.store_id,
              bundle.source["task_id"]?.text == snapshot.task_id,
              bundle.attempt_id == artifact.attempt_id, bundle.turn_id == artifact.source_ref["turn_id"]?.text,
              bundle.event_cursor == artifact.source_ref["seq"]?.text,
              let attempt = snapshot.attempts.first(where: { $0.id == artifact.attempt_id }), bundle.iteration == attempt.iteration
        else { throw CodingTaskReadError.artifactMismatch }
        guard snapshot.artifact_refs.contains(where: {
            $0.id == bundle.plan["artifact_id"]?.text && $0.version == bundle.plan["version"]?.text
                && $0.content_hash == bundle.plan["hash"]?.text
        }) else { throw CodingTaskReadError.artifactMismatch }
        if let review = history.events.compactMap({ $0.payload["review"] }).first(where: {
            $0["artifact"]?["artifact_id"]?.text == artifact.id
        }) {
            guard review["artifact"]?["version"]?.text == artifact.version,
                  review["artifact"]?["hash"]?.text == artifact.content_hash,
                  review["reviewed_attempt_id"]?.text == bundle.attempt_id,
                  review["run_id"]?.text == bundle.source["run_id"]?.text,
                  review["control_epoch"]?.text == bundle.source["control_epoch"]?.text,
                  review["plan"] == bundle.plan else { throw CodingTaskReadError.artifactMismatch }
        }
        // The authenticated server verifies the stored blob hash; re-encoding this DTO would change its bytes.
        return bundle
    }

    static func message(_ error: Error) -> String {
        switch error {
        case RuntimeHTTPError.unsupported, RuntimeHTTPError.notFound: "当前 Runtime 不支持协作任务，或该资源已不可用。"
        case RuntimeHTTPError.authenticationRequired, RuntimeHTTPError.authenticationInvalid: "Runtime 认证失效，请重新连接。"
        case RuntimeHTTPError.unexpectedStatus(let code, _) where code == 403: "当前连接无权读取协作任务，需要 Runtime owner 权限。"
        default: error.localizedDescription
        }
    }
}
