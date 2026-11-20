#if os(macOS)
import SwiftUI

struct MacUserQueuePanel: View {
    let conversation: ConversationViewModel
    let vm: DraftComposerPanelViewModel
    let sessionID: String
    let serverID: String
    let page: UserQueuePage?
    let updatePage: (UserQueuePage) -> Void
    @State private var moreItems: [UserQueueReceipt] = []
    @State private var next: UserQueuePage.Cursor?
    @State private var loading = false
    @State private var issue: String?
    @State private var pendingRemoval: UserQueueChange?
    @State private var pendingResume: UserQueueChange?
    @State private var pendingPriority: UserQueueChange?

    private var canControl: Bool { page?.controls == true && !conversation.isArchived }

    private var items: [UserQueueReceipt] { (page?.items ?? []) + moreItems }

    private func canPrioritize(_ item: UserQueueReceipt) -> Bool {
        page?.prioritizeSupported == true && page?.state == "enabled"
            && item.state == "queued" && pendingPriority == nil
            && items.first(where: { $0.state == "queued" })?.input.requestID != item.input.requestID
    }

    private var pauseDescription: String {
        switch page?.pauseReason {
        case "cancelled": "上次任务已取消，队列已暂停。"
        case "failed": "上次任务失败，队列已暂停。"
        case "execution_context_changed": "模型、推理强度、权限或工作区已变化。请恢复排队时的设置后继续，或移除消息重新提交。"
        case "execution_interrupted": "任务执行中断，后续消息已保留。请先核对已执行的操作，再继续中断任务。"
        case "resume_validation_failed": "上次恢复未能通过执行校验，请检查模型、权限与工作区后重试。"
        case "resume_requested": "恢复请求已接收，正在等待执行环境校验与调度。"
        case "execution_validation_failed": "无法验证执行环境。请检查模型连接、凭据与工作区权限后继续。"
        default: "队列暂停原因暂未识别，请刷新状态。"
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            if let pendingPriority {
                Button("重试排序") { Task { await change(pendingPriority) } }
                    .help("使用原操作编号确认结果")
            }
            if let record = vm.pendingQueueTakeBack, record.serverID == serverID {
                if record.confirmed {
                    Button("保存取回的草稿") { vm.applyTakenBackQueueDraft(serverID: serverID) }
                } else {
                    Button("重试取回") { Task { await takeBack() } }
                        .help("使用原操作编号再次确认取回结果")
                }
            }
            if let interrupted = page?.interrupted {
                Text("中断任务").font(.caption).foregroundStyle(.secondary)
                Text(interrupted.input.text).font(.callout).lineLimit(3)
                if page?.resumeSupported != true {
                    Text("这项任务带有后台续接状态，需要先处理后台任务的恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if canControl, let page, page.resumeSupported == true, ["execution_interrupted", "resume_validation_failed"].contains(page.pauseReason ?? "") {
                    if let pendingResume {
                        Text("将从已保存的对话继续。中断前的外部操作可能已经完成，请先核对执行结果。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("取消") { self.pendingResume = nil }
                            Button("确认继续") {
                                self.pendingResume = nil
                                Task { await change(pendingResume) }
                            }
                        }
                    } else {
                        Button("继续中断任务") {
                            pendingResume = .init(revision: page.revision, action: .resumeInterrupted,
                                requestID: interrupted.input.requestID)
                        }
                    }
                }
                Divider()
            }
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
                                    if canPrioritize(item) {
                                        Button {
                                            let priority = UserQueueChange(revision: revision, action: .prioritize,
                                                requestID: item.input.requestID, operationID: UUID().uuidString)
                                            Task { await change(priority) }
                                        } label: {
                                            Image(systemName: "arrow.up.to.line")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("下一条执行").accessibilityLabel("下一条执行")
                                        .accessibilityIdentifier("userQueue.prioritize.\(item.input.requestID)")
                                    }
                                    if page?.takeBackSupported == true, item.state == "queued", vm.pendingQueueTakeBack == nil {
                                        Button {
                                            Task { await takeBack(item, revision: revision) }
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("取回草稿").accessibilityLabel("取回草稿")
                                    }
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
            if canControl, let page, page.state == "paused", ["cancelled", "failed", "execution_context_changed", "execution_validation_failed"].contains(page.pauseReason ?? "") {
                Button("继续队列") { Task { await change(.init(revision: page.revision, action: .resume)) } }
            }
        }
        .padding(14)
        .frame(width: 320)
        .disabled(loading)
        .task { await load() }
        .task(id: page?.pauseReason) {
            guard page?.pauseReason == "resume_requested" else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    let current = try await conversation.queuePage(serverID: serverID, expectedSessionID: sessionID)
                    guard !Task.isCancelled else { return }
                    updatePage(current)
                    if current.pauseReason != "resume_requested" { return }
                } catch is CancellationError {
                    return
                } catch {
                    issue = "暂时无法确认恢复进度，请刷新后核对。"
                    return
                }
            }
        }
        .onChange(of: page?.revision, initial: true) { _, _ in
            pendingResume = nil
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

    private func takeBack(_ item: UserQueueReceipt? = nil, revision: Int64? = nil) async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        do {
            if let item, let revision {
                try await vm.takeBackQueueItem(item, revision: revision, serverID: serverID)
            } else {
                try await vm.recoverQueueTakeBack(serverID: serverID, retry: true)
            }
        } catch {
            issue = vm.pendingQueueTakeBack == nil
                ? "无法取回这条消息，它可能已进入执行。请查看最新队列。"
                : "取回状态待确认，可以重试原操作。"
        }
        if let current = try? await conversation.queuePage(serverID: serverID, expectedSessionID: sessionID) {
            updatePage(current)
        }
    }

    private func change(_ change: UserQueueChange) async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        let prioritizing = change.action == .prioritize
        if prioritizing { pendingPriority = change }
        var priorityConfirmed = false
        do {
            try await conversation.controlUserQueue(sessionID: sessionID, change: change, serverID: serverID)
            if prioritizing {
                pendingPriority = nil
                priorityConfirmed = true
            }
        } catch RuntimeHTTPError.unexpectedStatus(let status, let body) {
            if prioritizing, status < 500 { pendingPriority = nil }
            let code = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])?["code"]
            switch code {
            case "queue_revision_changed": issue = "队列已更新，请查看最新列表后重试。"
            case "queue_unavailable": issue = "消息可能已进入执行流程，或队列暂时无法继续。请查看最新状态。"
            case "queue_unauthorized": issue = "当前连接无权管理此队列，请检查执行环境与凭据。"
            case "queue_unsupported": issue = "当前执行环境尚不支持队列管理。"
            default: issue = status >= 500 ? "服务端暂时无法确认操作结果，请刷新后核对。" : "操作未完成，请刷新队列后核对。"
            }
        } catch {
            issue = "连接中断，操作结果尚未确认。请刷新队列后核对。"
        }
        if let current = try? await conversation.queuePage(serverID: serverID, expectedSessionID: sessionID), !Task.isCancelled {
            updatePage(current)
        } else if priorityConfirmed {
            issue = "顺序已更新，暂时无法刷新队列。"
        }
    }
}
#endif
