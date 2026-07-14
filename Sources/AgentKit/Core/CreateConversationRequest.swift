//
//  CreateConversationRequest.swift
//  AgentKit
//
//  Workspace execution intent for a server-owned conversation.
//

import Foundation

public enum WorkspaceExecutionPolicy: String, Codable, Sendable, Equatable {
    /// Turns sharing the same workspace are protected by a whole-turn lease.
    case sharedWorkspace = "shared_workspace"
    /// The supplied path already points at a separately provisioned worktree.
    case isolatedWorktree = "isolated_worktree"
    /// Currently remains conservatively leased by Code-Agent Runtime.
    case readOnly = "read_only"
}

public struct CreateConversationRequest: Codable, Sendable, Equatable {
    public let clientRequestID: String?
    public let workspacePath: String
    public let workspaceExtID: String?
    public let executionPolicy: WorkspaceExecutionPolicy?
    public let workspaceID: String?
    public let baseWorkspaceID: String?
    public let worktree: ManagedWorktreeCreateRequest?

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case workspacePath = "workspace_path"
        case workspaceExtID = "workspace_ext_id"
        case executionPolicy = "execution_policy"
        case workspaceID = "workspace_id"
        case baseWorkspaceID = "base_workspace_id"
        case worktree
    }

    public init(
        clientRequestID: String? = nil,
        workspacePath: String,
        workspaceExtID: String? = nil,
        executionPolicy: WorkspaceExecutionPolicy? = nil,
        workspaceID: String? = nil,
        baseWorkspaceID: String? = nil,
        worktree: ManagedWorktreeCreateRequest? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.workspacePath = workspacePath
        self.workspaceExtID = workspaceExtID
        self.executionPolicy = executionPolicy
        self.workspaceID = workspaceID
        self.baseWorkspaceID = baseWorkspaceID
        self.worktree = worktree
    }
}
