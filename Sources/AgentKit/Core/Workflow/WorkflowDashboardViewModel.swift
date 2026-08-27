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

    /// 跨 workspace 的目录条目（每个已知 workspace 一次 list 调用）。
    public private(set) var catalog: [WorkflowCatalogEntry] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    /// workspace path → 该 workspace 查询失败的原因（如无 workflow DB，404）。
    /// 单 workspace 失败不阻塞整个面板，仅在对应分组头部提示。
    public private(set) var workspaceErrors: [String: String] = [:]

    /// 待枚举的 workspace 绝对路径列表（App 已知 workspace，不去服务端枚举）。
    public let workspacePaths: [String]

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

    // MARK: - Load

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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard !workspacePaths.isEmpty else {
            hasLoaded = true
            catalog = []
            errorMessage = "暂无可用的工作区。请先在 Code 侧打开或新建一个工作区，再发起 plan_workflow。"
            return
        }

        var entries: [WorkflowCatalogEntry] = []
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, Result<[WorkflowSummary], Error>).self) { group in
            for path in workspacePaths {
                group.addTask { [client] in
                    do {
                        let items = try await client.listWorkspaceWorkflows(workspacePath: path)
                        return (path, .success(items))
                    } catch {
                        return (path, .failure(error))
                    }
                }
            }
            for await (path, result) in group {
                let name = URL(fileURLWithPath: path).lastPathComponent
                switch result {
                case .success(let items):
                    entries.append(contentsOf: items.map {
                        WorkflowCatalogEntry(workspacePath: path, workspaceName: name, summary: $0)
                    })
                case .failure(let error):
                    errors[path] = Self.message(for: error) ?? "查询失败"
                }
            }
        }

        // 稳定排序：workspace 名 → workflow id
        entries.sort { a, b in
            if a.workspaceName != b.workspaceName { return a.workspaceName < b.workspaceName }
            return a.summary.id < b.summary.id
        }

        catalog = entries
        workspaceErrors = errors
        hasLoaded = true
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

    // MARK: - Error

    private static func message(for error: Error) -> String? {
        (error as? LocalizedError)?.errorDescription
    }
}
