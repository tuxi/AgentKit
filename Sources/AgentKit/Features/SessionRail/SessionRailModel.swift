import Foundation
import Observation

public enum SessionRailRoute: Hashable, Sendable {
    case environment, context, connectors, outputs, changes, jobs
    case composition(snapshotID: String, category: String)
    case tools(snapshotID: String, origin: String?)
    case source(snapshotID: String, sourceID: String, title: String)
    case connector(String), output(String)
    case patch(snapshotID: String, fileID: String, path: String)
    case job(String)
}

/// One owner for docked and floating presentations. Individual views hold a
/// visibility lease; an old disappearing view cannot stop its replacement.
@MainActor @Observable public final class SessionRailModel {
    public private(set) var conversationID: String?
    public private(set) var scope: SessionRailScope?
    public private(set) var snapshot: SessionRailSnapshot?
    public private(set) var isRefreshing = false
    public private(set) var error: String?
    public private(set) var unavailable = false
    public private(set) var path: [SessionRailRoute] = []
    public private(set) var detailLoading = false
    public private(set) var detailError: String?
    public private(set) var connector: SessionRailConnector?
    public private(set) var output: SessionRailOutput?
    public private(set) var outputs: SessionRailOutputs?
    public private(set) var changes: SessionRailChanges?
    public private(set) var jobs: SessionRailJobs?
    public private(set) var request: SessionRailRequest?
    public private(set) var source: SessionRailSourceContent?
    public private(set) var patch: SessionRailPatch?
    public private(set) var expanded: [String: Bool]
    public private(set) var previewHTML: String?
    public private(set) var skillInventory: RuntimeSkillInventory?
    public private(set) var skillInventoryError: String?
    public private(set) var skillInventoryLoading = false
    public private(set) var compactionMessage: String?
    public private(set) var compactingConversations: Set<String> = []
    public func isCompacting(_ conversationID: String?) -> Bool {
        conversationID.map { compactingConversations.contains($0) } ?? false
    }
    func beginCompaction(_ conversationID: String) -> Bool {
        compactingConversations.insert(conversationID).inserted
    }
    func endCompaction(_ conversationID: String) { compactingConversations.remove(conversationID) }

    private let client: any RuntimeClient
    private let preferences: UserDefaults
    private var lease = UUID()
    private var generation = UUID()
    private var refreshID = UUID()
    private var detailID = UUID()
    private var serverKey: String?
    public var route: SessionRailRoute? { path.last }
    public var stateID: UUID { generation }
    public init(client: any RuntimeClient, preferences: UserDefaults = .standard) {
        self.client = client; self.preferences = preferences
        expanded = preferences.dictionary(forKey: "sessionRail.expanded.v1") as? [String: Bool] ?? [:]
    }
    public func isExpanded(_ key: String) -> Bool { expanded[key] ?? (key != "connectors" && !key.hasPrefix("context.tools.")) }
    public func setExpanded(_ value: Bool, for key: String) {
        expanded[key] = value; preferences.set(expanded, forKey: "sessionRail.expanded.v1")
    }
    public func hasTaskSurface(for id: String?) -> Bool {
        conversationID == id && snapshot?.sections.backgroundTasks.isUsable == true
    }
    public func navigate(_ route: SessionRailRoute) {
        guard path.last != route else { return }
        path.append(route); invalidateDetail()
    }
    public func back() { if !path.isEmpty { path.removeLast() }; invalidateDetail() }
    private func invalidateDetail() {
        detailID = UUID(); detailLoading = false; detailError = nil
        connector = nil; output = nil; request = nil; source = nil; patch = nil; previewHTML = nil
        skillInventory = nil; skillInventoryError = nil; skillInventoryLoading = false
    }
    private func select(_ id: String) {
        guard conversationID != id else { return }
        conversationID = id; resetSource()
    }
    private func resetSource() {
        generation = UUID(); refreshID = UUID(); scope = nil; snapshot = nil; serverKey = nil
        compactionMessage = nil
        path = []; outputs = nil; changes = nil; jobs = nil; error = nil; unavailable = false
        invalidateDetail()
    }
    public func run(conversationID: String, isBusy: @escaping @MainActor () -> Bool) async {
        let owner = UUID(); lease = owner
        select(conversationID)
        defer { if lease == owner { isRefreshing = false } }
        while !Task.isCancelled, lease == owner {
            await refresh()
            do { try await Task.sleep(for: isBusy() ? .seconds(5) : .seconds(20)) } catch { return }
        }
    }
    public func refresh() async {
        guard let id = conversationID else { return }
        let token = UUID(); refreshID = token; let selected = generation
        isRefreshing = true
        defer { if refreshID == token { isRefreshing = false } }
        do {
            let origin = try await client.backgroundJobRuntimeIdentity()
            guard selected == generation, id == conversationID, refreshID == token, !Task.isCancelled else { return }
            if let old = scope, old.runtimeIdentity != origin {
                resetSource(); refreshID = token; isRefreshing = true
            }
            let current = SessionRailScope(conversationID: id, runtimeIdentity: origin)
            scope = current
            let value = try await client.sessionRail(scope: current)
            guard refreshID == token, conversationID == id, scope == current, !Task.isCancelled else { return }
            guard value.conversationID == id, value.schema == "session-rail/v1",
                  try await client.backgroundJobRuntimeIdentity() == origin else { throw SessionRailError.invalidIdentity }
            guard refreshID == token, conversationID == id, scope == current, !Task.isCancelled else { return }
            let key = value.serverID + ":" + value.runtimeInstanceID + ":" + value.workspaceID
            if let serverKey, serverKey != key {
                generation = UUID(); path = []; outputs = nil; jobs = nil; changes = nil; invalidateDetail()
            }
            serverKey = key; snapshot = value; unavailable = false; error = nil
        } catch {
            guard refreshID == token, conversationID == id, !error.isRequestCancelled else { return }
            if let http = error as? RuntimeHTTPError {
                switch http {
                case .notFound, .unsupported: unavailable = true; self.error = "当前 Runtime 尚未提供 Session rail，请更新 Runtime 后重试。"
                default: self.error = "刷新失败，已保留上次数据。"
                }
            } else { self.error = "刷新失败，已保留上次数据。" }
        }
    }
    public func loadDetail() async {
        guard let route, let current = scope else { return }
        let token = UUID(); detailID = token; let selected = generation
        detailLoading = true; detailError = nil
        defer { if detailID == token { detailLoading = false } }
        func valid() -> Bool { detailID == token && generation == selected && scope == current && self.route == route && !Task.isCancelled }
        do {
            switch route {
            case .connector(let id):
                let value = try await client.sessionRailConnector(scope: current, connectorID: id)
                guard valid() else { return }
                guard value.connectorID == id else { throw SessionRailError.invalidIdentity }; connector = value
            case .output(let id):
                let value = try await client.sessionRailOutput(scope: current, outputID: id)
                guard valid() else { return }
                guard value.outputID == id else { throw SessionRailError.invalidIdentity }; output = value
            case .outputs:
                let value = try await client.sessionRailOutputs(scope: current, cursor: nil)
                guard valid() else { return }; outputs = value
            case .changes:
                let value = try await client.sessionRailChanges(scope: current)
                guard valid() else { return }; changes = value
            case .jobs:
                let value = try await client.sessionRailJobs(scope: current, cursor: nil)
                guard valid() else { return }; jobs = value
            case .source(let snapshotID, let id, _):
                let value = try await client.sessionRailSource(scope: current, snapshotID: snapshotID, sourceID: id)
                guard valid() else { return }
                guard value.sourceID == id else { throw SessionRailError.invalidIdentity }; source = value
            case .tools(let snapshotID, _), .composition(let snapshotID, _):
                let value = try await client.sessionRailRequest(scope: current, snapshotID: snapshotID)
                guard valid() else { return }
                guard value.snapshotID == snapshotID else { throw SessionRailError.invalidIdentity }; request = value
            case .patch(let snapshotID, let id, _):
                let value = try await client.sessionRailPatch(scope: current, snapshotID: snapshotID, fileID: id)
                guard valid() else { return }
                guard value.snapshotID == snapshotID, value.fileID == id else { throw SessionRailError.invalidIdentity }; patch = value
            case .environment, .context, .connectors, .job:
                await refresh()
                if valid() { detailError = error }
            }
        } catch {
            guard valid(), !error.isRequestCancelled else { return }
            if let http = error as? RuntimeHTTPError {
                switch http {
                case .unexpectedStatus(let code, _) where code == 409: detailError = "这份快照已更新或过期。请返回列表刷新后重新打开。"
                case .unexpectedStatus(let code, _) where code == 410: detailError = "这份加载版本已不可用。当前磁盘内容不能替代它。"
                default: detailError = "暂时无法读取，请重试。"
                }
            } else { detailError = "暂时无法读取，请重试。" }
        }
    }
    /// Available inventory is loaded only on an explicit user request; it never
    /// stands in for bodies proven present in a request snapshot.
    public func loadSkillInventory() async {
        guard !skillInventoryLoading else { return }
        guard let current = scope, let manager = client as? any SkillPluginManaging else {
            skillInventoryError = "当前 Runtime 未提供可用技能目录。"; return
        }
        let selected = generation; let token = detailID
        skillInventoryLoading = true; skillInventoryError = nil
        defer { if generation == selected, detailID == token { skillInventoryLoading = false } }
        do {
            guard try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity else { throw SessionRailError.invalidIdentity }
            let value = try await manager.skillInventory(sessionID: current.conversationID)
            guard generation == selected, detailID == token, scope == current, !Task.isCancelled else { return }
            guard try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity,
                  value.scope.resolved, value.scope.sessionID == current.conversationID else { throw SessionRailError.invalidIdentity }
            // Skill inventory uses its own opaque workspace-ID namespace. Its
            // session-bound route resolves the workspace on the Runtime.
            guard generation == selected, detailID == token, scope == current, !Task.isCancelled else { return }
            skillInventory = value
        } catch {
            if generation == selected, detailID == token, !error.isRequestCancelled { skillInventoryError = "技能目录读取失败，请重试。" }
        }
    }
    public func compactContext(isBusy: @MainActor () -> Bool) async {
        guard let current = scope, !isBusy(), beginCompaction(current.conversationID) else { return }
        let selected = generation; compactionMessage = nil
        defer { endCompaction(current.conversationID) }
        do {
            guard try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity, !isBusy() else { throw SessionRailError.invalidIdentity }
            let result = try await client.compactSessionRailContext(scope: current)
            guard generation == selected, scope == current,
                  try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity else { return }
            await refresh()
            guard generation == selected, scope == current else { return }
            compactionMessage = result.status == "no_change" ? "当前上下文无需压缩。" : "压缩完成，等待下次请求测量；原始对话记录已保留。"
        } catch {
            guard generation == selected, scope == current else { return }
            if let http = error as? RuntimeHTTPError, case .unexpectedStatus(let code, _) = http, code == 409 {
                compactionMessage = "会话正在运行，空闲后才能压缩。"
            } else { compactionMessage = "压缩未确认完成，请刷新上下文后重试。" }
        }
    }
    public func loadMoreOutputs() async {
        guard let current = scope, let old = outputs, let cursor = old.nextCursor, !detailLoading else { return }
        let selected = generation; let token = detailID; detailLoading = true
        defer { if generation == selected, detailID == token { detailLoading = false } }
        do {
            let next = try await client.sessionRailOutputs(scope: current, cursor: cursor)
            guard generation == selected, detailID == token, !Task.isCancelled, scope == current, route == .outputs, outputs?.revision == old.revision else { return }
            guard next.revision == old.revision else { throw SessionRailError.staleResponse }
            outputs = SessionRailOutputs(scope: next.scope, coverage: next.coverage, revision: next.revision, totalCount: next.totalCount,
                                         items: old.items + next.items, nextCursor: next.nextCursor)
        } catch { if generation == selected, detailID == token, !Task.isCancelled { detailError = "目录已变化或读取失败，请刷新列表。" } }
    }
    public func loadMoreJobs() async {
        guard let current = scope, let old = jobs, let cursor = old.nextCursor, !detailLoading else { return }
        let selected = generation; let token = detailID; detailLoading = true
        defer { if generation == selected, detailID == token { detailLoading = false } }
        do {
            let next = try await client.sessionRailJobs(scope: current, cursor: cursor)
            guard generation == selected, detailID == token, !Task.isCancelled, scope == current, route == .jobs, jobs?.revision == old.revision else { return }
            guard next.revision == old.revision else { throw SessionRailError.staleResponse }
            jobs = SessionRailJobs(scope: next.scope, totalCount: next.totalCount, activeCount: next.activeCount, stoppingCount: next.stoppingCount,
                                  terminalCount: next.terminalCount, unknownCount: next.unknownCount, items: old.items + next.items,
                                  revision: next.revision, nextCursor: next.nextCursor)
        } catch { if generation == selected, detailID == token, !Task.isCancelled { detailError = "任务目录已变化或读取失败，请刷新列表。" } }
    }
    public func loadPreview(_ artifact: PreviewArtifact) async {
        guard let current = scope, artifact.sessionID == current.conversationID,
              let resolver = client.previewViewerResolver() else { return }
        let selected = generation; let token = detailID; detailLoading = true
        defer { if generation == selected, detailID == token { detailLoading = false } }
        do {
            guard try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity else { throw SessionRailError.invalidIdentity }
            let value = try await resolver.resolve(.init(sessionID: current.conversationID, artifactID: artifact.artifactID, revision: artifact.revision))
            let html = try ConversationWebPreviewSecurity.validateViewerDocument(value.data)
            guard generation == selected, detailID == token, scope == current,
                  try await client.backgroundJobRuntimeIdentity() == current.runtimeIdentity else { return }
            previewHTML = html
        } catch { if generation == selected, detailID == token { detailError = "预览暂时不可用。" } }
    }
}
