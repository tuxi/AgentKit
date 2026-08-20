import Foundation

public struct WorkspaceGitCheckout: Codable, Sendable, Equatable {
    public let kind: String
    public let name: String?
    public let commit: String?
    public init(kind: String, name: String? = nil, commit: String? = nil) { self.kind = kind; self.name = name; self.commit = commit }
    public var isBranch: Bool { kind == "branch" && name != nil }
}

public struct WorkspaceGitCheckoutState: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let isGitRepository: Bool
    public let head: WorkspaceGitCheckout
    public let isDirty: Bool
    public let modifiedFiles: Int
    public let untrackedFiles: Int
    public let activeWorktree: Bool
    enum CodingKeys: String, CodingKey {
        case workspacePath = "workspace_path", isGitRepository = "is_git_repository", head
        case isDirty = "is_dirty", modifiedFiles = "modified_files", untrackedFiles = "untracked_files", activeWorktree = "active_worktree"
    }
}

public struct WorkspaceGitBranch: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let commit: String
    public let isCurrent: Bool
    public let isCheckedOutElsewhere: Bool
    public let worktreePath: String?
    public var id: String { name }
    enum CodingKeys: String, CodingKey {
        case name, commit, isCurrent = "is_current", isCheckedOutElsewhere = "is_checked_out_elsewhere", worktreePath = "worktree_path"
    }
}

public struct WorkspaceGitBranchResult: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let checkout: WorkspaceGitCheckoutState
    public let branches: [WorkspaceGitBranch]
    enum CodingKeys: String, CodingKey { case workspacePath = "workspace_path", checkout, branches }
}

public struct WorkspaceGitBranchListRequest: Codable, Sendable, Equatable {
    public let workspacePath: String
    public init(workspacePath: String) { self.workspacePath = workspacePath }
    enum CodingKeys: String, CodingKey { case workspacePath = "workspace_path" }
}

public struct WorkspaceGitBranchCreateRequest: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let name: String
    public let startPoint: String?
    public let checkout: Bool
    public let clientRequestID: String?
    public init(workspacePath: String, name: String, startPoint: String? = nil, checkout: Bool = true, clientRequestID: String? = nil) {
        self.workspacePath = workspacePath; self.name = name; self.startPoint = startPoint; self.checkout = checkout; self.clientRequestID = clientRequestID
    }
    enum CodingKeys: String, CodingKey { case workspacePath = "workspace_path", name, startPoint = "start_point", checkout, clientRequestID = "client_request_id" }
}

public struct WorkspaceGitBranchCheckoutRequest: Codable, Sendable, Equatable {
    public let workspacePath: String
    public let name: String
    public let allowDirty: Bool
    public init(workspacePath: String, name: String, allowDirty: Bool = false) { self.workspacePath = workspacePath; self.name = name; self.allowDirty = allowDirty }
    enum CodingKeys: String, CodingKey { case workspacePath = "workspace_path", name, allowDirty = "allow_dirty" }
}

public struct WorkspaceGitBranchErrorPayload: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let workspacePath: String?
    public let checkout: WorkspaceGitCheckoutState?
    public let conflicts: [String]?
    public let baseWorkspacePath: String?
    enum CodingKeys: String, CodingKey { case code, message, checkout, conflicts, workspacePath = "workspace_path", baseWorkspacePath = "base_workspace_path" }
}
