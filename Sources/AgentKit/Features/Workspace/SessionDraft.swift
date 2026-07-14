//
//  SessionDraft.swift
//  AgentKit
//
//  P5.0 — 延迟创建的本地占位会话。
//  点击「+」不调用任何 API，只创建 SessionDraft；用户选定 Workspace 并发送
//  第一条消息时才真正创建 Session（见 WorkspaceStore.commitDraft）。
//
//  状态机：
//    drafting ──选 workspace──▶ ready ──发首条消息──▶ committing ──▶ (真实 session)
//        ▲                                                 │
//        └──────────────── failed（可重试）◀───────────────┘
//

import Foundation

/// UI 本地占位会话（尚未创建真实 Session）。Composer 内容以 `id` 为键
/// 持久化到 ConversationLocalStateStore，创建成功后原子迁移到 session ID。
public struct SessionDraft: Equatable, Sendable {

    /// Stable local identity across view reconstruction and App restarts.
    public let id: UUID

    public enum State: Equatable, Sendable {
        /// 尚未选择 workspace，无法发送。
        case drafting
        /// 已选择 workspace，可发送首条消息。
        case ready
        /// 正在创建真实 Session。
        case committing
        /// 创建失败（携带原因），可重试。
        case failed(String)
    }

    /// 绑定的工作区（选定后，发送首条消息时锁定）。
    public var workspace: Workspace?

    /// Stable idempotency key reused when managed provisioning is retried.
    public let clientRequestID: String

    /// Explicit opt-in. False is the product and protocol default.
    public var usesManagedWorktree: Bool

    /// The committed ref used to create an opted-in worktree.
    public var managedWorktreeBaseRef: ManagedWorktreeBaseRef

    /// Stable for this draft and deliberately unrelated to the user prompt.
    /// Runtime will sanitize it and append its reservation-derived short ID.
    public let managedWorktreeSuggestedName: String

    /// 当前草稿状态。
    public var state: State

    public init(
        id: UUID = UUID(),
        workspace: Workspace? = nil,
        clientRequestID: String = "create_\(UUID().uuidString)",
        usesManagedWorktree: Bool = false,
        managedWorktreeBaseRef: ManagedWorktreeBaseRef = .head,
        managedWorktreeSuggestedName: String? = nil
    ) {
        self.id = id
        self.workspace = workspace
        self.clientRequestID = clientRequestID
        self.usesManagedWorktree = usesManagedWorktree
        self.managedWorktreeBaseRef = managedWorktreeBaseRef
        self.managedWorktreeSuggestedName = managedWorktreeSuggestedName
            ?? ManagedWorktreeSuggestedNameGenerator.make()
        self.state = workspace == nil ? .drafting : .ready
    }

    /// 是否可以提交（发送首条消息）。
    public var canCommit: Bool {
        if case .committing = state { return false }
        return workspace != nil
    }
}
