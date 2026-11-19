#if os(macOS)
import SwiftUI

struct MacUserQueuePanel: View {
    let conversation: ConversationViewModel
    let sessionID: String
    let serverID: String
    let page: UserQueuePage?
    let updatePage: (UserQueuePage) -> Void
    @State private var moreItems: [UserQueueReceipt] = []
    @State private var next: UserQueuePage.Cursor?
    @State private var loading = false
    @State private var issue: String?
    @State private var pendingRemoval: UserQueueChange?

    private var canControl: Bool { page?.controls == true && !conversation.isArchived }

    private var items: [UserQueueReceipt] { (page?.items ?? []) + moreItems }

    private var pauseDescription: String {
        switch page?.pauseReason {
        case "cancelled": "上次任务已取消，队列已暂停。"
        case "failed": "上次任务失败，队列已暂停。"
        case "execution_context_changed": "执行环境已变化。继续时将重新校验。"
        case "execution_interrupted": "上次执行被中断，队列需要先确认那轮的状态。"
        case "execution_validation_failed": "执行环境未通过校验，队列已暂停。"
        default: "队列已暂停。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("消息队列").font(.headline)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新队列").accessibilityLabel("刷新队列")
            }
            if page?.state == "paused" {
                Text(pauseDescription).font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            if items.isEmpty {
                Text(page == nil ? "正在读取队列…" : "没有待执行的消息")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.input.requestID) { item in
                            HStack(spacing: 8) {
                                Text(item.input.text).font(.callout).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if item.state == "claimed" {
                                    Text("准备执行").font(.caption).foregroundStyle(.secondary)
                                }
                                if canControl, let revision = page?.revision {
                                    Button {
                                        pendingRemoval = .init(revision: revision, action: .remove, requestID: item.input.requestID)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("移除这条消息").accessibilityLabel("移除这条消息")
                                }
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                        if let next {
                            Button("加载更多") { Task { await load(cursor: next) } }.padding(.top, 6)
                        }
                    }
                }
                .frame(height: min(238, CGFloat(items.count + (next == nil ? 0 : 1)) * 45))
            }
            if canControl, let page, page.state == "paused", page.pauseReason != "execution_interrupted" {
                Button("继续队列") { Task { await change(.init(revision: page.revision, action: .resume)) } }
            }
        }
        .padding(14)
        .frame(width: 320)
        .disabled(loading)
        .task { await load() }
        .onChange(of: page?.revision, initial: true) { _, _ in
            moreItems = []
            next = page?.next
        }
        .confirmationDialog("移除这条排队消息？", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { change in
            Button("移除", role: .destructive) { Task { await self.change(change) } }
        }
    }

    private func load(cursor: UserQueuePage.Cursor? = nil) async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        do {
            let result = try await conversation.queuePage(serverID: serverID, cursor: cursor, expectedSessionID: sessionID)
            guard !Task.isCancelled else { return }
            if cursor != nil, result.revision == page?.revision {
                moreItems.append(contentsOf: result.items)
                next = result.next
            } else if result.revision >= (page?.revision ?? 0) {
                updatePage(result)
            }
        } catch {
            if cursor != nil, let current = try? await conversation.queuePage(serverID: serverID, expectedSessionID: sessionID) {
                updatePage(current)
            }
            issue = "无法读取该页，请刷新队列。"
        }
    }

    private func change(_ change: UserQueueChange) async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        do {
            try await conversation.controlUserQueue(sessionID: sessionID, change: change, serverID: serverID)
        } catch RuntimeHTTPError.unexpectedStatus(409, _) {
            issue = "队列已变化，或消息已进入执行流程。请查看最新状态。"
        } catch {
            issue = "操作结果暂未确认，请查看最新队列。"
        }
        if let current = try? await conversation.queuePage(serverID: serverID, expectedSessionID: sessionID), !Task.isCancelled {
            updatePage(current)
        }
    }
}
#endif
