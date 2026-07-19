//
//  AgentCapabilityFlags.swift
//  AgentKit
//
//  Backend runtime capability declaration.
//  UI reads this to adapt rendering — no hardcoded backend assumptions.
//
//  Protocol: AgentKit Runtime Protocol v1.1 §AgentCapabilityFlags
//

import Foundation

// MARK: - AgentCapabilityFlags

/// Backend runtime 能力声明。
///
/// 用 `OptionSet` 而非固定 struct：未来新增能力只需加 `static let`，
/// 不破坏 API 兼容性。
///
/// ```swift
/// let caps = await transport.capabilities()
/// if caps.contains(.toolStreaming) { showLiveStdout() }
/// ```
public struct AgentCapabilityFlags: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: - Capabilities

    /// 支持 `token_delta` 实时流式推送。
    public static let streaming = AgentCapabilityFlags(rawValue: 1 << 0)
    /// 支持 `thinking` 完整推理快照事件（持久化、REPLACE 语义）。
    public static let thinking = AgentCapabilityFlags(rawValue: 1 << 1)
    /// 支持 `tool_stdout` / `tool_stderr` 实时 IO。
    public static let toolStreaming = AgentCapabilityFlags(rawValue: 1 << 2)
    /// 支持 `AgentInput` 携带 image。
    public static let imageInput = AgentCapabilityFlags(rawValue: 1 << 3)
    /// 支持 `plan_approval_request`。
    public static let planMode = AgentCapabilityFlags(rawValue: 1 << 4)
    /// 支持 `task_started` / `task_finished` 子 agent 事件。
    public static let subagents = AgentCapabilityFlags(rawValue: 1 << 5)
    /// 支持 wire-level session resume。
    public static let sessionResume = AgentCapabilityFlags(rawValue: 1 << 6)
    /// 支持客户端工具执行（tool_started executor: "client" + tool_result 回传）。
    public static let clientToolExecution = AgentCapabilityFlags(rawValue: 1 << 7)
    /// Runtime guarantees safe execution of turns from multiple sessions.
    public static let multiSessionExecution = AgentCapabilityFlags(rawValue: 1 << 8)
    /// Pending client-tool requests survive socket replacement and are session scoped.
    public static let sessionScopedClientTools = AgentCapabilityFlags(rawValue: 1 << 9)
    /// Runtime exposes an ownership-filtered activity snapshot.
    public static let activitySnapshot = AgentCapabilityFlags(rawValue: 1 << 10)
    /// Runtime enforces a declared workspace/worktree execution policy.
    public static let workspaceExecutionPolicy = AgentCapabilityFlags(rawValue: 1 << 11)
    /// Runtime activity includes durable terminal sequence and broker attention.
    public static let sessionAttentionSnapshot = AgentCapabilityFlags(rawValue: 1 << 12)
    /// Runtime supports cursor-based incremental session attention snapshots.
    public static let sessionAttentionDelta = AgentCapabilityFlags(rawValue: 1 << 13)
    /// Runtime can explicitly provision, recover and safely remove Git worktrees.
    public static let managedWorktree = AgentCapabilityFlags(rawValue: 1 << 14)
    /// Runtime persistently partitions conversations into active and archived lists.
    public static let conversationArchive = AgentCapabilityFlags(rawValue: 1 << 15)
    /// Runtime can safely clone unauthenticated public HTTPS Git repositories.
    public static let publicGitClone = AgentCapabilityFlags(rawValue: 1 << 16)
    /// 支持 `reasoning_delta` 实时推理流式推送。
    public static let reasoningStreaming = AgentCapabilityFlags(rawValue: 1 << 17)

    // MARK: - Presets

    /// CodeAgent v1 默认能力集。
    public static let `default`: AgentCapabilityFlags = [.streaming, .thinking, .reasoningStreaming]
}
