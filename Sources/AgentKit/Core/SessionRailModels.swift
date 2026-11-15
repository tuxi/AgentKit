import Foundation
import ClientToolProtocol

public struct SessionRailSnapshot: Decodable, Sendable {
    public let schema: String
    public let serverID: String
    public let runtimeInstanceID: String
    public let conversationID: String
    public let workspaceID: String
    public let snapshotID: String
    public let generatedAt: String
    public let sections: SessionRailSections
    enum CodingKeys: String, CodingKey {
        case schema = "schema"
        case serverID = "server_id"
        case runtimeInstanceID = "runtime_instance_id"
        case conversationID = "conversation_id"
        case workspaceID = "workspace_id"
        case snapshotID = "snapshot_id"
        case generatedAt = "generated_at"
        case sections = "sections"
    }
}

public struct SessionRailSections: Decodable, Sendable {
    public let environment: SessionRailSection<SessionRailEnvironment>
    public let context: SessionRailSection<SessionRailContext>
    public let connectors: SessionRailSection<SessionRailConnectors>
    public let outputs: SessionRailSection<SessionRailOutputs>
    public let changes: SessionRailSection<SessionRailChanges>
    public let backgroundTasks: SessionRailSection<SessionRailJobs>
    enum CodingKeys: String, CodingKey {
        case environment = "environment"
        case context = "context"
        case connectors = "connectors"
        case outputs = "outputs"
        case changes = "changes"
        case backgroundTasks = "background_tasks"
    }
}

public struct SessionRailEnvironment: Decodable, Sendable {
    public let runtime: SessionRailRuntime
    public let workspace: SessionRailWorkspace?
    public let executionPolicy: String
    public let needsRebind: Bool
    public let worktree: SessionRailWorktree?
    public let head: SessionRailHead?
    enum CodingKeys: String, CodingKey {
        case runtime = "runtime"
        case workspace = "workspace"
        case executionPolicy = "execution_policy"
        case needsRebind = "needs_rebind"
        case worktree = "worktree"
        case head = "head"
    }
}

public struct SessionRailRuntime: Decodable, Sendable {
    public let serverID: String
    public let displayName: String
    public let runtimeVersion: String
    public let runtimeProfile: String
    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case displayName = "display_name"
        case runtimeVersion = "runtime_version"
        case runtimeProfile = "runtime_profile"
    }
}

public struct SessionRailWorkspace: Decodable, Sendable {
    public let id: String
    public let name: String?
    public let rootPath: String
    public let runtimeCWD: String?
    public let displayPath: String?
    public let kind: String
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
        case rootPath = "root_path"
        case runtimeCWD = "runtime_cwd"
        case displayPath = "display_path"
        case kind = "kind"
    }
}

public struct SessionRailWorktree: Decodable, Sendable {
    public let managed: Bool
    public let name: String?
    public let branch: String?
    public let baseRef: String?
    public let state: String
    public let needsRebind: Bool?
    enum CodingKeys: String, CodingKey {
        case managed = "managed"
        case name = "name"
        case branch = "branch"
        case baseRef = "base_ref"
        case state = "state"
        case needsRebind = "needs_rebind"
    }
}

public struct SessionRailHead: Decodable, Sendable {
    public let kind: String
    public let name: String?
    public let commit: String?
    enum CodingKeys: String, CodingKey {
        case kind = "kind"
        case name = "name"
        case commit = "commit"
    }
}

public struct SessionRailContext: Decodable, Sendable {
    public let snapshot: ConversationContextSnapshot
    public let request: SessionRailRequest?
    public let measurementState: String
    public let promptTokens: Int?
    public let measuredAt: String?
    public let measurementModel: String?
    public let measurementWindow: Int?
    public let measurementSnapshotID: String?
    public let latestRequestSnapshotID: String?
    public let historyState: String?
    public let breakdownState: String
    public let windowSource: String
    enum CodingKeys: String, CodingKey {
        case snapshot = "snapshot"
        case request = "request"
        case measurementState = "measurement_state"
        case promptTokens = "prompt_tokens"
        case measuredAt = "measured_at"
        case measurementModel = "measurement_model"
        case measurementWindow = "measurement_window"
        case measurementSnapshotID = "measurement_snapshot_id"
        case latestRequestSnapshotID = "latest_request_snapshot_id"
        case historyState = "history_state"
        case breakdownState = "breakdown_state"
        case windowSource = "window_source"
    }
}

public struct SessionRailRequest: Decodable, Sendable {
    public let snapshotID: String
    public let model: String
    public let contextWindow: Int
    public let historyRevision: String
    public let estimationMethod: String
    public let sourceCoverage: String
    public let categories: [String: Int]
    public let totalEstimatedTokens: Int
    public let multimodalUnestimated: Bool
    public let sources: [SessionRailSource]?
    public let tools: [SessionRailTool]?
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case model = "model"
        case contextWindow = "context_window"
        case historyRevision = "history_revision"
        case estimationMethod = "estimation_method"
        case sourceCoverage = "source_coverage"
        case categories = "categories"
        case totalEstimatedTokens = "total_estimated_tokens"
        case multimodalUnestimated = "multimodal_unestimated"
        case sources = "sources"
        case tools = "tools"
    }
}

public struct SessionRailSource: Decodable, Sendable {
    public let sourceID: String
    public let kind: String
    public let label: String
    public let displayPath: String?
    public let scope: String?
    public let version: String?
    public let sha256: String
    public let estimatedTokens: Int
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case kind = "kind"
        case label = "label"
        case displayPath = "display_path"
        case scope = "scope"
        case version = "version"
        case sha256 = "sha256"
        case estimatedTokens = "estimated_tokens"
    }
}

public struct SessionRailSourceContent: Decodable, Sendable {
    public let sourceID: String
    public let kind: String
    public let label: String
    public let displayPath: String?
    public let scope: String?
    public let version: String?
    public let sha256: String
    public let content: String
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case kind = "kind"
        case label = "label"
        case displayPath = "display_path"
        case scope = "scope"
        case version = "version"
        case sha256 = "sha256"
        case content = "content"
    }
}

public struct SessionRailTool: Decodable, Sendable {
    public let name: String
    public let origin: String
    public let connectorID: String?
    public let executor: String
    public let sourceID: String
    public let estimatedTokens: Int
    enum CodingKeys: String, CodingKey {
        case name = "name"
        case origin = "origin"
        case connectorID = "connector_id"
        case executor = "executor"
        case sourceID = "source_id"
        case estimatedTokens = "estimated_tokens"
    }
}

public struct SessionRailConnectors: Decodable, Sendable {
    public let state: String
    public let diagnostics: [String]
    public let items: [SessionRailConnector]
    public let clientCapabilitiesState: String
    enum CodingKeys: String, CodingKey {
        case state = "state"
        case diagnostics = "diagnostics"
        case items = "items"
        case clientCapabilitiesState = "client_capabilities_state"
    }
}

public struct SessionRailConnector: Decodable, Sendable {
    public let connectorID: String
    public let kind: String
    public let displayName: String
    public let source: String
    public let status: String
    public let reason: String?
    public let lastCheckedAt: String?
    public let health: String
    public let discoveredToolCount: Int?
    public let registeredToolCount: Int?
    public let availableToolCount: Int?
    public let catalogVisibleToolCount: Int?
    public let exposedToolCount: Int?
    public let exposureSnapshotID: String?
    public let tools: [SessionRailConnectorTool]?
    enum CodingKeys: String, CodingKey {
        case connectorID = "connector_id"
        case kind = "kind"
        case displayName = "display_name"
        case source = "source"
        case status = "status"
        case reason = "reason"
        case lastCheckedAt = "last_checked_at"
        case health = "health"
        case discoveredToolCount = "discovered_tool_count"
        case registeredToolCount = "registered_tool_count"
        case availableToolCount = "available_tool_count"
        case catalogVisibleToolCount = "catalog_visible_tool_count"
        case exposedToolCount = "exposed_tool_count"
        case exposureSnapshotID = "exposure_snapshot_id"
        case tools = "tools"
    }
}

public struct SessionRailConnectorTool: Decodable, Sendable {
    public let name: String
    public let description: String
    public let registered: Bool
    public let catalogVisible: Bool?
    enum CodingKeys: String, CodingKey {
        case name = "name"
        case description = "description"
        case registered = "registered"
        case catalogVisible = "catalog_visible"
    }
}

public struct SessionRailOutputs: Decodable, Sendable {
    public let scope: String
    public let coverage: String
    public let revision: String
    public let totalCount: Int
    public let items: [SessionRailOutput]
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case scope = "scope"
        case coverage = "coverage"
        case revision = "revision"
        case totalCount = "total_count"
        case items = "items"
        case nextCursor = "next_cursor"
    }
}

public struct SessionRailOutput: Decodable, Sendable {
    public let outputID: String
    public let title: String
    public let kind: String
    public let relativePath: String?
    public let contentMode: String
    public let state: String
    public let availability: String
    public let latest: SessionRailOutputVersion
    public let versionCount: Int
    public let versions: [SessionRailOutputVersion]?
    enum CodingKeys: String, CodingKey {
        case outputID = "output_id"
        case title = "title"
        case kind = "kind"
        case relativePath = "relative_path"
        case contentMode = "content_mode"
        case state = "state"
        case availability = "availability"
        case latest = "latest"
        case versionCount = "version_count"
        case versions = "versions"
    }
}

public struct SessionRailOutputVersion: Decodable, Sendable {
    public let evidence: String
    public let turnID: String
    public let callID: String
    public let sequence: Int64
    public let updatedAt: String
    public let operation: String
    public let asset: AgentAssetRef?
    public let artifact: PreviewArtifact?
    enum CodingKeys: String, CodingKey {
        case evidence = "evidence"
        case turnID = "turn_id"
        case callID = "call_id"
        case sequence = "sequence"
        case updatedAt = "updated_at"
        case operation = "operation"
        case asset = "asset"
        case artifact = "artifact"
    }
}

public struct SessionRailChanges: Decodable, Sendable {
    public let snapshotID: String
    public let observedAt: String
    public let baseline: String
    public let head: SessionRailHead
    public let isGitRepository: Bool
    public let fileCount: Int
    public let addedLines: Int64
    public let removedLines: Int64
    public let uncountedFiles: Int
    public let files: [SessionRailChangedFile]
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case observedAt = "observed_at"
        case baseline = "baseline"
        case head = "head"
        case isGitRepository = "is_git_repository"
        case fileCount = "file_count"
        case addedLines = "added_lines"
        case removedLines = "removed_lines"
        case uncountedFiles = "uncounted_files"
        case files = "files"
    }
}

public struct SessionRailChangedFile: Decodable, Sendable {
    public let fileID: String
    public let path: String
    public let previousPath: String?
    public let status: String
    public let addedLines: Int64?
    public let removedLines: Int64?
    public let binary: Bool
    public let conflict: Bool
    public let submodule: Bool
    public let patchState: String
    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case path = "path"
        case previousPath = "previous_path"
        case status = "status"
        case addedLines = "added_lines"
        case removedLines = "removed_lines"
        case binary = "binary"
        case conflict = "conflict"
        case submodule = "submodule"
        case patchState = "patch_state"
    }
}

public struct SessionRailPatch: Decodable, Sendable {
    public let snapshotID: String
    public let fileID: String
    public let state: String
    public let patch: String
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case fileID = "file_id"
        case state = "state"
        case patch = "patch"
    }
}

public struct SessionRailJobs: Decodable, Sendable {
    public let scope: String
    public let totalCount: Int
    public let activeCount: Int?
    public let stoppingCount: Int?
    public let terminalCount: Int
    public let unknownCount: Int
    public let items: [SessionRailJob]
    public let revision: String?
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case scope = "scope"
        case totalCount = "total_count"
        case activeCount = "active_count"
        case stoppingCount = "stopping_count"
        case terminalCount = "terminal_count"
        case unknownCount = "unknown_count"
        case items = "items"
        case revision = "revision"
        case nextCursor = "next_cursor"
    }
}

public struct SessionRailJob: Decodable, Sendable {
    public let jobID: String
    public let turnID: String
    public let callID: String
    public let command: String
    public let status: BackgroundJobStatus
    public let liveState: String
    public let canControl: Bool
    public let cancelRequested: Bool
    public let startedAt: String?
    public let finishedAt: String?
    public let durationMs: Int64?
    public let exitCode: Int?
    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case turnID = "turn_id"
        case callID = "call_id"
        case command = "command"
        case status = "status"
        case liveState = "live_state"
        case canControl = "can_control"
        case cancelRequested = "cancel_requested"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationMs = "duration_ms"
        case exitCode = "exit_code"
    }
}

public struct SessionRailSection<Value: Decodable & Sendable>: Decodable, Sendable {
    public let state: String
    public let code: String?
    public let revision: String?
    public let observedAt: String?
    public let data: Value?
    public var isUsable: Bool { ["ready", "empty", "stale"].contains(state) && data != nil }
    enum CodingKeys: String, CodingKey { case state, code, revision, data; case observedAt = "observed_at" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .state)
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        observedAt = try c.decodeIfPresent(String.self, forKey: .observedAt)
        let decoded: Value?
        do { decoded = try c.decodeIfPresent(Value.self, forKey: .data) }
        catch { data = nil; state = "error"; code = "invalid_section_payload"; return }
        data = decoded
        if decoded == nil && ["ready", "empty", "stale"].contains(raw) {
            state = "error"; code = "invalid_section_payload"
        } else { state = raw; code = try c.decodeIfPresent(String.self, forKey: .code) }
    }
}

public struct SessionRailScope: Sendable, Hashable {
    public let conversationID: String
    public let runtimeIdentity: String
    public init(conversationID: String, runtimeIdentity: String) {
        self.conversationID = conversationID; self.runtimeIdentity = runtimeIdentity
    }
}

public enum SessionRailError: Error { case invalidScope, invalidIdentity, staleResponse }
