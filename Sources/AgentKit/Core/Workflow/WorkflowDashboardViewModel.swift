//
//  WorkflowDashboardViewModel.swift
//  AgentKit
//
//  P18 R1/R2 — Workflow 控制面板 ViewModel：跨 workspace 枚举目录、
//  详情、以及 snapshot 观测数据的拉取。纯只读（P1 范围）。
//
//  镜像 AutomationDashboardViewModel 的结构与模式：
//  - 单一 @MainActor @Observable VM，持有 RuntimeClient
//  - load() 带 force 语义，loadTask 防重入
//  - workspace 枚举走 App 已知列表（recentWorkspaces + projects + 会话），
//    不调用服务端枚举端点；单个 workspace 失败不阻塞整个面板
//

import Foundation

// MARK: - WorkflowDashboardViewModel

@MainActor
@Observable
public final class WorkflowDashboardViewModel {

    // MARK: - State

    /// 当前选中 workspace 的目录条目（只加载选中的 workspace，按需请求）。
    public private(set) var catalog: [WorkflowCatalogEntry] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    /// workspace path → 该 workspace 查询失败的原因（如无 workflow DB，404）。
    /// 切换 workspace 时按当前选中项展示。
    public private(set) var workspaceErrors: [String: String] = [:]

    /// 待枚举的 workspace 绝对路径列表（App 已知 workspace，不去服务端枚举）。
    public let workspacePaths: [String]

    /// 当前选中的 workspace（nil = 尚无可用 workspace）。
    public private(set) var selectedWorkspacePath: String?

    @ObservationIgnored private let client: RuntimeClient
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public struct WorkflowCatalogEntry: Identifiable, Equatable {
        public let workspacePath: String
        public let workspaceName: String
        public let summary: WorkflowSummary
        public var id: String { "\(workspacePath)#\(summary.name)" }

        public init(workspacePath: String, workspaceName: String, summary: WorkflowSummary) {
            self.workspacePath = workspacePath
            self.workspaceName = workspaceName
            self.summary = summary
        }
    }

    // MARK: - Init

    public init(client: RuntimeClient, workspacePaths: [String]) {
        self.client = client
        self.workspacePaths = Self.deduplicatedPaths(workspacePaths)
    }

    /// 去重并剔除空路径，保持原顺序。
    private static func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !path.isEmpty else { return false }
            return seen.insert(path).inserted
        }
    }

    /// workspace 目录显示名（最后一段路径）。
    public static func workspaceDisplayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Selection & Load

    /// 初始加载：自动选中第一个 workspace；无可用 workspace 时设置空状态。
    public func loadInitialIfNeeded() async {
        if let first = workspacePaths.first {
            if selectedWorkspacePath == nil {
                await selectWorkspace(first)
            }
        } else {
            selectedWorkspacePath = nil
            catalog = []
            errorMessage = "暂无可用的工作区。请先在 Code 侧打开或新建一个工作区，再发起 plan_workflow。"
            hasLoaded = true
        }
    }

    /// 切换到指定 workspace 并加载其目录。显式点击 → 总是重新请求（force）。
    public func selectWorkspace(_ path: String) async {
        guard path != selectedWorkspacePath else { return }
        selectedWorkspacePath = path
        catalog = []
        errorMessage = nil
        await load(force: true)
    }

    public func load(force: Bool = false) async {
        if loadTask != nil && !force { return }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        guard let path = selectedWorkspacePath else {
            hasLoaded = true
            catalog = []
            errorMessage = "暂无可用的工作区。请先在 Code 侧打开或新建一个工作区，再发起 plan_workflow。"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let items = try await client.listWorkspaceWorkflows(workspacePath: path)
            let name = Self.workspaceDisplayName(path)
            catalog = items
                .map { WorkflowCatalogEntry(workspacePath: path, workspaceName: name, summary: $0) }
                .sorted { $0.summary.id < $1.summary.id }
            workspaceErrors[path] = nil
            hasLoaded = true
        } catch {
            catalog = []
            let message = Self.message(for: error) ?? "查询失败"
            workspaceErrors[path] = message
            errorMessage = message
            hasLoaded = true
        }
    }

    // MARK: - Detail / Snapshot

    public func loadDetail(workspacePath: String, name: String) async throws -> WorkflowDetail {
        try await client.getWorkspaceWorkflowDetail(workspacePath: workspacePath, name: name)
    }

    public func loadSnapshot(workspacePath: String, workflowName: String, taskID: Int64) async throws -> WorkflowSnapshot {
        try await client.getWorkspaceWorkflowSnapshot(
            workspacePath: workspacePath, workflowName: workflowName, taskID: taskID
        )
    }

    // MARK: - P2: save-as-template / trigger

    /// 把某次 run 保存为命名模板（R4）。成功返回服务端确认的模板名。
    @discardableResult
    public func saveTemplate(
        workspacePath: String,
        sourceTaskID: Int64,
        name: String,
        description: String?
    ) async throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkflowPanelError.invalidInput("模板名不能为空")
        }
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await client.saveWorkflowTemplate(
            workspacePath: workspacePath,
            name: trimmedName,
            request: WorkflowTemplateSaveRequest(
                sourceTaskID: sourceTaskID,
                description: (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil
            )
        )
    }

    /// 按名触发模板（R5），headless 异步执行。成功返回 task_id，调用方跳转 snapshot 观测页。
    @discardableResult
    public func triggerRun(
        workspacePath: String, name: String, request: WorkflowTriggerRequest
    ) async throws -> Int64 {
        guard !request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowPanelError.invalidInput("goal 不能为空")
        }
        guard !request.agents.isEmpty else {
            throw WorkflowPanelError.invalidInput("至少需要一个 agent")
        }
        for agent in request.agents {
            if agent.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || agent.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || agent.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WorkflowPanelError.invalidInput("每个 agent 的 role / session_id / message 均为必填")
            }
        }
        return try await client.triggerWorkflowRun(workspacePath: workspacePath, name: name, request: request)
    }

    /// 恢复 suspended/failed/canceled 的 run（R3 手工逃生口），后台异步执行。
    /// resume_from 不传 → 服务端自动收集失败根节点。
    @discardableResult
    public func resumeRun(workspacePath: String, workflowName: String, taskID: Int64) async throws -> Int64 {
        try await client.resumeWorkflowRun(
            workspacePath: workspacePath,
            workflowName: workflowName,
            taskID: taskID,
            request: WorkflowResumeRequest()
        )
    }

    // MARK: - Error

    private static func message(for error: Error) -> String? {
        (error as? LocalizedError)?.errorDescription
    }
}

// MARK: - WorkflowPanelError

/// 面板操作（保存模板 / 触发）的客户端校验错误。
public enum WorkflowPanelError: LocalizedError {
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        }
    }
}
