//
//  ConversationListViewModel.swift
//  AgentKit
//
//  侧栏会话列表的 ViewModel。管理会话创建、列表拉取、选中状态。
//

import SwiftUI

// MARK: - ConversationListViewModel

@MainActor
@Observable
public final class ConversationListViewModel {

    /// 从 Runtime 拉取的会话列表（仅含 `id`，v1 无 metadata）。
    public private(set) var conversations: [ConversationRef] = []

    /// 异步操作中的错误。
    public private(set) var errorMessage: String?

    /// 是否正在加载。
    public private(set) var isLoading = false

    private let client: RuntimeClient

    // MARK: - Init

    public init(client: RuntimeClient) {
        self.client = client
    }

    // MARK: - Public API

    /// 将一个新会话插入列表顶部（P5.0：commitDraft 创建后调用）。
    public func prepend(_ ref: ConversationRef) {
        guard !conversations.contains(where: { $0.id == ref.id }) else { return }
        conversations.insert(ref, at: 0)
    }

    /// 拉取会话列表。
    ///
    /// 进入 App 时 `.task` 可能早于 `AgentRuntime.start()`（scenePhase .active）执行，
    /// 此时内嵌 runtime 端口未分配 → `listConversations` 抛 `runtimeNotStarted`，且 start 之后
    /// 无人重新触发 → 列表恒空。故对该错误做**有界轮询重试**，等端口就绪后自然拉到。
    /// macOS（固定端口）`baseURL` 永不为 nil，不会进重试分支，行为不变。
    public func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let maxAttempts = 30          // ≈ 30 × 150ms = 4.5s，覆盖冷启动 start() 的延迟
        for attempt in 1...maxAttempts {
            do {
                conversations = try await client.listConversations()
                errorMessage = nil
                return
            } catch {
                if let httpError = error as? RuntimeHTTPError,
                   case .runtimeNotStarted = httpError,
                   attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue            // runtime 尚未 start → 等端口就绪重试
                }
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// 新建会话。
    /// - Parameter workspacePath: 工作区路径（v1 忽略，但协议要求写入）。
    /// - Returns: 新会话引用。
    @discardableResult
    public func createConversation(workspacePath: String = "") async -> ConversationRef? {
        isLoading = true
        errorMessage = nil
        do {
            let ref = try await client.createConversation(workspacePath: workspacePath)
            conversations.insert(ref, at: 0)
            isLoading = false
            return ref
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return nil
        }
    }

    /// 重命名会话。
    public func renameConversation(_ ref: ConversationRef, name: String) async {
        do {
            let updated = try await client.renameConversation(id: ref.id, name: name)
            // 原地替换列表中的旧引用
            if let idx = conversations.firstIndex(where: { $0.id == ref.id }) {
                conversations[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
