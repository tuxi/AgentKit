import SwiftUI

/// Shared Mac/iOS workspace. Writes require an explicit supported action and user interaction.
public struct CodingTasksView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CodingTaskStore
    @State private var artifact: CodingTaskArtifact?
    @State private var showCreate = false
    @State private var showStart = false
    private let reader: (any CodingTaskReading)?
    private let sessions: [ConversationRef]
    private let openSession: (String) async -> Void

    public init(reader: (any CodingTaskReading)?, sessions: [ConversationRef] = [], openSession: @escaping (String) async -> Void) {
        _store = State(initialValue: CodingTaskStore(reader: reader))
        self.reader = reader; self.sessions = sessions
        self.openSession = openSession
    }

    public var body: some View {
        Group {
            if let snapshot = store.snapshot {
                timeline(snapshot)
            } else {
                taskList
            }
        }
        .navigationTitle("协作任务")
        .toolbar {
            if reader is any CodingTaskWriting, store.capabilities?.capabilities.contains("task_links_v1") == true, !sessions.isEmpty {
                ToolbarItem { Button("新建任务", systemImage: "plus") { showCreate = true } }
            }
            if store.selectedID != nil {
                ToolbarItem { Button("任务列表", systemImage: "list.bullet") { store.select(nil) } }
            }
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading)
                    .accessibilityLabel("刷新协作任务")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = store.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .task(id: "\(scenePhase)-\(store.selectedID ?? "list")") {
            guard scenePhase == .active else { return }
            var failures = 0
            while !Task.isCancelled {
                await store.refresh()
                failures = store.errorMessage == nil ? 0 : min(failures + 1, 4)
                try? await Task.sleep(for: .seconds(store.selectedID == nil ? 10 : Double(2 << failures)))
            }
        }
        .sheet(item: $artifact) { ref in
            NavigationStack {
                FrozenTaskArtifactView(store: store, artifact: ref)
                    .toolbar { ToolbarItem { Button("关闭") { artifact = nil } } }
            }
            .frame(minWidth: 320, minHeight: 400)
        }
        .sheet(isPresented: $showCreate) {
            if let reader, let writer = reader as? any CodingTaskWriting, let identity = store.capabilities?.identity {
                NavigationStack {
                    CodingTaskCreateView(sessions: sessions, reader: reader, writer: writer, identity: identity) { id in
                        store.select(id)
                    }
                }.frame(minWidth: 320, minHeight: 480)
            }
        }
        .sheet(isPresented: $showStart, onDismiss: { Task { await store.refresh() } }) {
            if let reader, let writer = reader as? any CodingTaskWriting, let identity = store.capabilities?.identity, let task = store.snapshot {
                NavigationStack {
                    CodingTaskStartView(snapshot: task, reader: reader, writer: writer, identity: identity) {}
                }.frame(minWidth: 320, minHeight: 520)
            }
        }
    }

    private var taskList: some View {
        List {
            Section {
                Text("最近创建的任务，最多 200 条").font(.caption).foregroundStyle(.secondary)
                if store.loading { ProgressView("读取任务…") }
                if store.tasks.isEmpty && !store.loading && store.errorMessage == nil {
                    Text("暂无协作任务").foregroundStyle(.secondary)
                }
                ForEach(store.tasks) { task in
                    Button { store.select(task.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.goal).foregroundStyle(.primary)
                            Text("\(task.mode) · \(task.state) · \(task.phase) · \(task.task_acceptance)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(task.workspace_ref).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func timeline(_ task: CodingTaskSnapshot) -> some View {
        List {
            Section("任务") {
                Text(task.goal).font(.title3.bold()).textSelection(.enabled)
                LabeledContent("Task ID", value: task.task_id).font(.caption.monospaced()).textSelection(.enabled)
                LabeledContent("模式", value: task.mode)
                LabeledContent("状态 / 阶段", value: "\(task.state) / \(task.phase)")
                LabeledContent("验收", value: task.task_acceptance == "accepted" ? "验收通过 · accepted" : task.task_acceptance)
                LabeledContent("执行 / 返工", value: "\(task.executionRounds) 轮 / \(max(0, task.executionRounds - 1)) 次")
                if let run = task.managed_run {
                    LabeledContent("执行模型配置", value: run["executor_model"]?.text ?? "继承 Runtime 默认模型")
                }
                if let reason = task.wait_reason { Text(reason).foregroundStyle(.orange).textSelection(.enabled) }
                if task.managed_run?["state"]?.text == "reviewing" {
                    Text("等待 Reviewer 在其客户端审查冻结版本并通过 MCP 回报。Review PASS 仍需由服务端 Gate 和 Finalize 确认。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let reason = task.managed_run?["recovery_reason"]?.text, !reason.isEmpty {
                    Text("需人工核查：\(reason)").foregroundStyle(.orange)
                }
                if let caps = store.capabilities, reader is any CodingTaskWriting,
                   CodingTaskActionPolicy.canStart(task, capabilities: caps) {
                    Button("启动受管任务…", systemImage: "play.fill") { showStart = true }
                } else if task.managed_run == nil {
                    Text("受管启动需要已回报计划、本地 Executor 和 reported Reviewer；角色及计划可通过 MCP 关联。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(task.acceptance.enumerated()), id: \.offset) { _, value in Text(value) }
                LabeledContent("费用", value: task.cost_usd.map { "US$\($0)" } ?? "未知")
                if let usage = task.usage { DisclosureGroup("用量") { payload(usage) } }
                if let attention = task.pending_attention {
                    ForEach(Array(attention.enumerated()), id: \.offset) { _, item in payload(item) }
                } else { Text("审批聚合状态未知；审批请进入执行会话处理。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("参与者与执行") {
                ForEach(task.participations) { part in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(part.agent_id) · \(part.role)").font(.headline)
                        Text(part.observation_level).font(.caption).foregroundStyle(.secondary)
                        ForEach(task.attempts.filter { $0.participation_id == part.id }) { attempt in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Iteration \(attempt.iteration) · \(attempt.stage) · \(attempt.status)")
                                if let evidence = attempt.execution_evidence {
                                    DisclosureGroup("执行证据") { payload(evidence) }
                                }
                            }
                        }
                        if let identity = store.capabilities?.identity,
                           let session = part.session_ref.localSession(in: identity) {
                            Button("打开执行会话", systemImage: "bubble.left.and.bubble.right") {
                                Task { await openSession(session) }
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
            Section("协作时间线") {
                if !store.historyLoaded { ProgressView("补齐历史记录…") }
                ForEach(store.history.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eventTitle(event, task: task)).font(.headline)
                        Text("\(event.kind) · \(event.recorded_at)").font(.caption).foregroundStyle(.secondary)
                        if let review = event.payload["review"] {
                            if let verdict = review["verdict"]?.text { Text("审查结论：\(verdict)") }
                            if case .array(let findings) = review["findings"] {
                                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in payload(finding) }
                            }
                        }
                        if let action = event.payload["action"]?.text { Text("Gate：\(action)") }
                        // Review findings/plan content come from persisted events, including earlier iterations.
                        DisclosureGroup("查看记录") { payload(event.payload) }
                        if let binding = event.payload["review"]?["artifact"],
                           let ref = task.artifact_refs.first(where: {
                               $0.id == binding["artifact_id"]?.text && $0.version == binding["version"]?.text
                                   && $0.content_hash == binding["hash"]?.text
                           }) {
                            Button("查看此次审查的冻结版本") { artifact = ref }
                        }
                    }.padding(.vertical, 5)
                }
            }
            Section("产物与计划") {
                ForEach(task.artifact_refs) { ref in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(ref.kind) · v\(ref.version)").font(.headline)
                        Text("\(ref.capture_mode)\(ref.truncated ? " · 已截断" : "")").font(.caption).foregroundStyle(.secondary)
                        if let content = ref.content { payload(content["text"] ?? content) }
                        if ref.capture_mode == "immutable", ref.kind == "review_bundle" {
                            Button("查看冻结产物") { artifact = ref }
                        }
                    }
                }
            }
        }
    }

    private func eventTitle(_ event: CodingTaskEvent, task: CodingTaskSnapshot) -> String {
        if event.isSystem {
            if event.kind == "review.gate_consumed" { return "系统 · ReviewGate" }
            if event.kind == "task.accepted" { return "系统 · Finalize" }
            return "系统 · \(event.kind)"
        }
        if let part = task.participations.first(where: { $0.id == event.participation_id }) {
            return "\(part.agent_id) · \(part.role)"
        }
        return event.kind
    }

    private func payload(_ value: CodingTaskJSON) -> some View {
        Text(value.display).font(.callout.monospaced()).textSelection(.enabled)
    }
}

private struct FrozenTaskArtifactView: View {
    let store: CodingTaskStore
    let artifact: CodingTaskArtifact
    @State private var bundle: CodingTaskReviewBundle?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("冻结审查版本 · v\(artifact.version)").font(.title3.bold())
                Text(artifact.content_hash ?? "").font(.caption.monospaced()).textSelection(.enabled)
                if let error { Text(error).foregroundStyle(.red) }
                else if let bundle {
                    Text("Iteration \(bundle.iteration) · \(bundle.validation_status)")
                    Text("Attempt \(bundle.attempt_id)\nTurn \(bundle.turn_id)").font(.caption.monospaced())
                    Text("工作区 Diff").font(.headline)
                    DiffArtifactBody(filePath: nil, diffContent: bundle.patch, maxHeight: nil)
                    if !bundle.index_patch.isEmpty {
                        Text("暂存区 Diff").font(.headline)
                        DiffArtifactBody(filePath: nil, diffContent: bundle.index_patch, maxHeight: nil)
                    }
                    image("基线文件", bundle.baseline)
                    image("候选文件", bundle.candidate)
                } else { ProgressView("读取冻结产物…") }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: artifact.id) {
            do { bundle = try await store.bundle(for: artifact) }
            catch is CancellationError {} catch { self.error = CodingTaskStore.message(error) }
        }
    }

    private func image(_ title: String, _ image: CodingTaskWorkspaceImage) -> some View {
        DisclosureGroup(title) {
            Text("HEAD \(image.head)").font(.caption.monospaced())
            files(image.files ?? [], title: "文件")
            files(image.index ?? [], title: "索引")
        }
    }
    private func files(_ images: [CodingTaskFileImage], title: String) -> some View {
        ForEach(Array(images.enumerated()), id: \.offset) { _, file in
            DisclosureGroup("\(title) · \(file.path) · mode \(file.mode)") {
                if !file.exists { Text("此版本不存在该文件") }
                else if let text = file.text, !text.contains("\0") {
                    Text(text).font(.callout.monospaced()).textSelection(.enabled)
                } else { Text("二进制或未包含文本内容（\(file.data?.count ?? 0) bytes）") }
            }
        }
    }
}

/// Host entry point uses the same WorkspaceStore and existing Session selection path.
public struct CodingTasksWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var sessionError: String?
    public init() {}
    public var body: some View {
        CodingTasksView(reader: workspace.client as? any CodingTaskReading, sessions: availableSessions) { sessionID in
            do {
                guard let reader = workspace.client as? any CodingTaskReading else { throw RuntimeHTTPError.unsupported }
                let before = try await reader.codingTaskCapabilities()
                // Old/archived executors may be outside the first conversation-list page.
                let detail = try await workspace.client.getConversationDetail(id: sessionID)
                let after = try await reader.codingTaskCapabilities()
                guard before.identity == after.identity, detail.id == sessionID else { throw CodingTaskReadError.identityChanged }
                workspace.selectItem = .conversationDetail(conversation: try CodingTaskSessionNavigation.reference(detail))
                dismiss()
            } catch { sessionError = CodingTaskStore.message(error) }
        }
        .id(ObjectIdentifier(workspace))
        .alert("无法打开会话", isPresented: Binding(get: { sessionError != nil }, set: { if !$0 { sessionError = nil } })) {
            Button("好") { sessionError = nil }
        } message: { Text(sessionError ?? "") }
    }
    private var availableSessions: [ConversationRef] {
        var refs = workspace.listViewModel.conversations.filter { !$0.isArchived }
        if let selected = workspace.selectedConversation {
            refs.removeAll { $0.id == selected.id }; refs.insert(selected, at: 0)
        }
        return refs
    }
}

enum CodingTaskSessionNavigation {
    static func reference(_ detail: ConversationDetail) throws -> ConversationRef {
        guard let path = detail.workspacePath, !path.isEmpty else { throw RuntimeHTTPError.invalidResponse }
        return ConversationRef(
            id: detail.id, workspacePath: path, workspace: detail.workspace, name: detail.name,
            turnStatus: detail.turnStatus, pausedAt: detail.pausedAt, executionPolicy: detail.executionPolicy,
            workspaceID: detail.workspaceID, baseWorkspaceID: detail.baseWorkspaceID, worktree: detail.worktree,
            warnings: detail.warnings, archivedAt: detail.archivedAt
        )
    }
}

/// A navigation-only entry point; displaying the sheet sends GET requests only.
public struct CodingTasksButton: View {
    @State private var presented = false
    public init() {}
    public var body: some View {
        Button { presented = true } label: {
            Label("协作任务", systemImage: "person.3.sequence")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                CodingTasksWorkspaceView()
                    .toolbar { ToolbarItem { Button("关闭") { presented = false } } }
            }
            .frame(minWidth: 320, minHeight: 480)
            #if os(macOS)
            .frame(idealWidth: 840, idealHeight: 680)
            #endif
        }
    }
}
