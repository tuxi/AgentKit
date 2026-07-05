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

    /// 列表内容版本号。`ConversationRef` 的 identity 只看 `id`，用版本号显式驱动列表刷新。
    public private(set) var revision = 0

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
        revision += 1
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

        var didAttemptRecover = false // -1004 反应式恢复只做一次，防重启风暴
        let maxAttempts = 30          // ≈ 30 × 150ms = 4.5s，覆盖冷启动 start() 的延迟
        for attempt in 1...maxAttempts {
            do {
                conversations = try await client.listConversations()
                revision += 1
                errorMessage = nil
                #if os(iOS)
                RuntimeConnectionMonitor.shared.markConnected()
                #endif
                return
            } catch {
                if let httpError = error as? RuntimeHTTPError,
                   case .runtimeNotStarted = httpError,
                   attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue            // runtime 尚未 start → 等端口就绪重试
                }
                #if os(iOS)
                // listener 被 iOS 挂起回收 → -1004。探活+重启一次，成功则重试本次拉取。
                if Self.isCannotConnect(error), !didAttemptRecover {
                    didAttemptRecover = true
                    if await RuntimeConnectionMonitor.shared.ensureHealthy() {
                        continue
                    }
                }
                #endif
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    #if os(iOS)
    /// 判断是否「连不上端口」类错误（回环 listener 已死），用于触发 runtime 重启恢复。
    private static func isCannotConnect(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorCannotConnectToHost,   // -1004
             NSURLErrorCannotFindHost,        // -1003
             NSURLErrorNetworkConnectionLost, // -1005
             NSURLErrorTimedOut:              // -1001
            return true
        default:
            return false
        }
    }
    #endif

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
            revision += 1
            isLoading = false
            return ref
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return nil
        }
    }

    /// 重命名会话。
    @discardableResult
    public func renameConversation(_ ref: ConversationRef, name: String) async -> ConversationRef? {
        do {
            let updated = try await client.renameConversation(id: ref.id, name: name)
            // 整体赋回新数组，让 SwiftUI Observation / List diff 明确看到元素内容变化。
            conversations = conversations.map { $0.id == ref.id ? updated : $0 }
            revision += 1
            return updated
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
