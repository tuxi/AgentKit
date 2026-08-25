//
//  AutomationModels.swift
//  AgentKit
//
//  自动化（Automation / 定时任务）领域模型。
//
//  ⚠️ 契约来源：code-agent `internal/server/automations.go` + `internal/automation/types.go`。
//  ⚠️ 时间字段（scheduled_at / last_run_at / next_run_at / created_at / updated_at /
//     read_at）在服务端序列化为 RFC3339 字符串。AgentKit 的 `JSONDecoder()` 未配置
//     dateDecodingStrategy，因此这里统一建模为 `String`，由展示层按需解析本地时区。
//  ⚠️ `AutomationRun` 字段是 **PascalCase**（Go 默认 JSON，`automation.Run` 无 json tag），
//     与 Automation 的 snake_case 不同，CodingKeys 必须精确匹配否则静默解码失败。
//

import Foundation

// MARK: - Automation Status / Type

public enum AutomationStatus: String, Codable, Sendable, CaseIterable {
    case active = "ACTIVE"
    case paused = "PAUSED"
    case completed = "COMPLETED"
}

public enum AutomationScheduleType: String, Codable, Sendable {
    case once
    case recurring
}

public enum AutomationRunMode: String, Codable, Sendable {
    case standalone
    case chat
}

public enum AutomationRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case skipped
}

// MARK: - Automation (definition)

/// 一条自动化任务定义（对齐 `automationDTO`）。
public struct Automation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var prompt: String
    public var status: AutomationStatus
    public var scheduleType: AutomationScheduleType
    public var rrule: String?
    public var scheduledAt: String?
    public var timezone: String
    public var modeExec: AutomationRunMode
    public var sessionID: String?
    public var cwds: [String]?
    public var modelID: String?
    public var skills: [String]?
    public var connectors: [String]?
    public var permissionMode: String?
    public var createdFromWorkspace: String?
    public var lastRunAt: String?
    public var nextRunAt: String?
    public var runCount: Int64
    public var lastStatus: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        prompt: String,
        status: AutomationStatus,
        scheduleType: AutomationScheduleType,
        rrule: String? = nil,
        scheduledAt: String? = nil,
        timezone: String,
        modeExec: AutomationRunMode,
        sessionID: String? = nil,
        cwds: [String] = [],
        modelID: String? = nil,
        skills: [String] = [],
        connectors: [String] = [],
        permissionMode: String? = nil,
        createdFromWorkspace: String? = nil,
        lastRunAt: String? = nil,
        nextRunAt: String? = nil,
        runCount: Int64 = 0,
        lastStatus: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.status = status
        self.scheduleType = scheduleType
        self.rrule = rrule
        self.scheduledAt = scheduledAt
        self.timezone = timezone
        self.modeExec = modeExec
        self.sessionID = sessionID
        self.cwds = cwds
        self.modelID = modelID
        self.skills = skills
        self.connectors = connectors
        self.permissionMode = permissionMode
        self.createdFromWorkspace = createdFromWorkspace
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.runCount = runCount
        self.lastStatus = lastStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case status
        case scheduleType = "schedule_type"
        case rrule
        case scheduledAt = "scheduled_at"
        case timezone
        case modeExec = "mode_exec"
        case sessionID = "session_id"
        case cwds
        case modelID = "model_id"
        case skills
        case connectors
        case permissionMode = "permission_mode"
        case createdFromWorkspace = "created_from_workspace"
        case lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at"
        case runCount = "run_count"
        case lastStatus = "last_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - AutomationRun

/// 一次运行记录（对齐 `GET /{id}/runs` 返回的 `automation.Run`）。
/// ⚠️ **PascalCase 键**（Go 默认 JSON）。
public struct AutomationRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let automationID: String
    /// standalone=本次触发新建的会话 id；chat=该次投递的 turn id。
    public let sessionID: String
    public let status: AutomationRunStatus
    /// RFC3339；零值 = `0001-01-01T00:00:00Z`，即未读。
    public let readAt: String
    public let threadTitle: String
    public let sourceCWD: String
    public let resultSuccess: Bool
    public let resultSummary: String
    public let createdAt: String

    public init(
        id: String,
        automationID: String,
        sessionID: String,
        status: AutomationRunStatus,
        readAt: String = "",
        threadTitle: String = "",
        sourceCWD: String = "",
        resultSuccess: Bool = false,
        resultSummary: String = "",
        createdAt: String
    ) {
        self.id = id
        self.automationID = automationID
        self.sessionID = sessionID
        self.status = status
        self.readAt = readAt
        self.threadTitle = threadTitle
        self.sourceCWD = sourceCWD
        self.resultSuccess = resultSuccess
        self.resultSummary = resultSummary
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case automationID = "AutomationID"
        case sessionID = "SessionID"
        case status = "Status"
        case readAt = "ReadAt"
        case threadTitle = "ThreadTitle"
        case sourceCWD = "SourceCWD"
        case resultSuccess = "ResultSuccess"
        case resultSummary = "ResultSummary"
        case createdAt = "CreatedAt"
    }

    /// 未读判定：`ReadAt` 为零值（`0001-01-01T00:00:00Z`）即未读。
    public var isUnread: Bool {
        guard !readAt.isEmpty else { return true }
        return readAt == "0001-01-01T00:00:00Z"
    }
}

/// 零值 `time.Time` 的 RFC3339 序列化结果（Go `time.Time{}.Format(RFC3339)`）。
public let automationZeroTimeRFC3339 = "0001-01-01T00:00:00Z"

// MARK: - Create / Patch request bodies

/// `POST /v1/automations` body（对齐 `automationCreateRequest`）。
public struct AutomationCreateRequest: Codable, Sendable, Equatable {
    public var name: String
    public var prompt: String
    public var scheduleType: AutomationScheduleType
    public var rrule: String?
    public var scheduledAt: String?
    public var timezone: String
    public var modeExec: AutomationRunMode
    public var sessionID: String?
    public var cwds: [String]
    public var modelID: String?
    public var skills: [String]
    public var connectors: [String]
    public var permissionMode: String?
    public var enabled: Bool?

    public init(
        name: String,
        prompt: String,
        scheduleType: AutomationScheduleType,
        rrule: String? = nil,
        scheduledAt: String? = nil,
        timezone: String,
        modeExec: AutomationRunMode = .standalone,
        sessionID: String? = nil,
        cwds: [String] = [],
        modelID: String? = nil,
        skills: [String] = [],
        connectors: [String] = [],
        permissionMode: String? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.prompt = prompt
        self.scheduleType = scheduleType
        self.rrule = rrule
        self.scheduledAt = scheduledAt
        self.timezone = timezone
        self.modeExec = modeExec
        self.sessionID = sessionID
        self.cwds = cwds
        self.modelID = modelID
        self.skills = skills
        self.connectors = connectors
        self.permissionMode = permissionMode
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case name
        case prompt
        case scheduleType = "schedule_type"
        case rrule
        case scheduledAt = "scheduled_at"
        case timezone
        case modeExec = "mode_exec"
        case sessionID = "session_id"
        case cwds
        case modelID = "model_id"
        case skills
        case connectors
        case permissionMode = "permission_mode"
        case enabled
    }
}

/// `PATCH /v1/automations/{id}` body（对齐 `automationPatchRequest`）。
/// `enabled`（Bool）→ 服务端映射为 `status`（true=ACTIVE，false=PAUSED）。
public struct AutomationPatchRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var prompt: String?
    public var scheduleType: AutomationScheduleType?
    public var rrule: String?
    public var scheduledAt: String?
    public var timezone: String?
    public var modeExec: AutomationRunMode?
    public var sessionID: String?
    public var cwds: [String]?
    public var modelID: String?
    public var skills: [String]?
    public var connectors: [String]?
    public var permissionMode: String?
    public var enabled: Bool?

    public init(
        name: String? = nil,
        prompt: String? = nil,
        scheduleType: AutomationScheduleType? = nil,
        rrule: String? = nil,
        scheduledAt: String? = nil,
        timezone: String? = nil,
        modeExec: AutomationRunMode? = nil,
        sessionID: String? = nil,
        cwds: [String]? = nil,
        modelID: String? = nil,
        skills: [String]? = nil,
        connectors: [String]? = nil,
        permissionMode: String? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.prompt = prompt
        self.scheduleType = scheduleType
        self.rrule = rrule
        self.scheduledAt = scheduledAt
        self.timezone = timezone
        self.modeExec = modeExec
        self.sessionID = sessionID
        self.cwds = cwds
        self.modelID = modelID
        self.skills = skills
        self.connectors = connectors
        self.permissionMode = permissionMode
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case name
        case prompt
        case scheduleType = "schedule_type"
        case rrule
        case scheduledAt = "scheduled_at"
        case timezone
        case modeExec = "mode_exec"
        case sessionID = "session_id"
        case cwds
        case modelID = "model_id"
        case skills
        case connectors
        case permissionMode = "permission_mode"
        case enabled
    }
}

// MARK: - Payloads

/// `GET /v1/automations/{id}/runs` 的 `data` 是裸数组，无需包一层。
/// `GET /v1/automations` 的 `data` 也是裸数组。
