import Foundation

/// Public lifecycle facts, never an executable checkpoint or a new user turn.
public struct BackgroundContinuationStatus: Codable, Sendable, Equatable {
    public let turnID: String
    public let state: String
    public let revision: Int64
    public let jobIDs: [String]
    public let reason: String?

    public init(turnID: String, state: String, revision: Int64 = 0, jobIDs: [String] = [], reason: String? = nil) {
        self.turnID = turnID; self.state = state; self.revision = revision
        self.jobIDs = jobIDs; self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case turnID = "turn_id", state, revision, jobIDs = "job_ids", reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try c.decode(String.self, forKey: .turnID)
        state = try c.decode(String.self, forKey: .state)
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        jobIDs = try c.decodeIfPresent([String].self, forKey: .jobIDs) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    public var isWaiting: Bool { ["waiting", "ready", "needs_attention"].contains(state) }
    public var isTerminal: Bool { ["stopped", "finished"].contains(state) }
    var rank: Int {
        switch state { case "waiting", "ready": 0; case "resuming": 1; case "needs_attention": 2; case "stopped", "finished": 3; default: -1 }
    }
    public var title: String {
        switch state { case "waiting", "ready": "等待后台结果"; case "resuming": "正在继续本轮"; case "needs_attention": "本轮需要处理"; default: "后台任务" }
    }
}

/// Shared by the engine and lifecycle subscriber. Reconnect snapshots cannot
/// move a resumed turn back to waiting or revive an older/terminal turn.
struct BackgroundContinuationTracker: Sendable {
    private(set) var current: BackgroundContinuationStatus?
    private(set) var activeTurnID: String?
    private var retired: Set<String> = []

    @discardableResult mutating func reduce(_ event: AgentEvent) -> Bool {
        switch event {
        case .turnAccepted(let id, _, _), .turnStarted(let id, _, _, _):
            guard !id.isEmpty, !retired.contains(id) else { return false }
            if activeTurnID != id { if let old = activeTurnID { retired.insert(old) }; current = nil }
            activeTurnID = id
        case .turnFinished(let id, _, _, _): finish(id)
        case .turnFailed(let id, _, _, _, _), .turnCancelled(let id, _, _):
            if let id = id ?? activeTurnID { finish(id) }
        case .turnPaused(let id, _, _):
            if let old = current, id == nil || id == old.turnID {
                current = .init(turnID: old.turnID, state: "needs_attention", revision: old.revision, jobIDs: old.jobIDs, reason: old.reason)
            }
        case .backgroundContinuation(let incoming):
            guard !incoming.turnID.isEmpty, incoming.revision >= 0, incoming.rank >= 0,
                  !retired.contains(incoming.turnID), activeTurnID == nil || activeTurnID == incoming.turnID else { return false }
            if let old = current, old.turnID == incoming.turnID {
                guard incoming.revision > old.revision || incoming.revision == old.revision && incoming.rank >= old.rank else { return false }
            }
            if incoming.isTerminal { finish(incoming.turnID) }
            else { current = incoming; activeTurnID = incoming.turnID }
        default: break
        }
        return true
    }
    private mutating func finish(_ id: String) {
        retired.insert(id)
        if current?.turnID == id { current = nil }
        if activeTurnID == id { activeTurnID = nil }
    }
}
