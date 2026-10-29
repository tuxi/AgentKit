import SwiftUI

struct CodingTaskCreateView: View {
    let sessions: [ConversationRef]
    let onComplete: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var actions: CodingTaskActions
    @State private var sessionID: String
    @State private var goal = ""
    @State private var acceptance = ""

    init(sessions: [ConversationRef], reader: any CodingTaskReading, writer: any CodingTaskWriting,
         identity: CodingTaskIdentity, onComplete: @escaping (String) -> Void) {
        self.sessions = sessions; self.onComplete = onComplete
        _actions = State(initialValue: CodingTaskActions(reader: reader, writer: writer, identity: identity))
        _sessionID = State(initialValue: sessions.first?.id ?? "")
    }
    var body: some View {
        Form {
            Section("创建协作任务") {
                Text("创建任务并关联现有 Code-Agent 会话，不发送消息或启动模型。计划和 Reviewer 可随后通过 MCP 关联。")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("执行会话", selection: $sessionID) {
                    ForEach(sessions) { ref in Text(ref.name ?? ref.id).tag(ref.id) }
                }
                TextField("任务目标", text: $goal, axis: .vertical).lineLimit(3...6)
                TextField("验收条件（每行一项）", text: $acceptance, axis: .vertical).lineLimit(3...8)
            }.disabled(actions.createRequest != nil)
            if let id = actions.createdTaskID { LabeledContent("已创建 Task", value: id).textSelection(.enabled) }
            if let request = actions.createRequest { Text("请求：\(request.request_id)").font(.caption.monospaced()).textSelection(.enabled) }
            if let error = actions.errorMessage { Text(error).foregroundStyle(.red) }
            Button(actions.createRequest == nil ? "创建并关联" : "重试原请求") {
                Task {
                    await actions.create(sessionID: sessionID, goal: goal, acceptance: lines(acceptance))
                    if actions.completed, let id = actions.createdTaskID { onComplete(id); dismiss() }
                }
            }.disabled(actions.busy || sessionID.isEmpty || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if actions.busy { ProgressView() }
        }
        .formStyle(.grouped)
        .navigationTitle("新建协作任务")
        .toolbar { ToolbarItem { Button("关闭") { dismiss() }.disabled(actions.busy) } }
        .interactiveDismissDisabled(actions.busy)
    }
}

struct CodingTaskStartView: View {
    let snapshot: CodingTaskSnapshot
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var actions: CodingTaskActions
    @State private var planID: String
    @State private var executorID: String
    @State private var reviewerID: String
    @State private var iterations = 2
    @State private var files = ""
    @State private var commands = ""
    @State private var confirm = false
    @State private var executorModel = ""
    @State private var catalog: RuntimeServerModelCatalog?
    @State private var supportsModelSelection = false
    @State private var catalogError: String?
    private let reader: any CodingTaskReading
    private let identity: CodingTaskIdentity
    private let requestID = "task-start-ui-\(UUID().uuidString)"

    init(snapshot: CodingTaskSnapshot, reader: any CodingTaskReading, writer: any CodingTaskWriting,
         identity: CodingTaskIdentity, onComplete: @escaping () -> Void) {
        self.snapshot = snapshot; self.identity = identity; self.onComplete = onComplete
        self.reader = reader
        _actions = State(initialValue: CodingTaskActions(reader: reader, writer: writer, identity: identity))
        _planID = State(initialValue: CodingTaskActionPolicy.plans(snapshot).last?.id ?? "")
        _executorID = State(initialValue: snapshot.participations.first { $0.role == "executor" && $0.session_ref.localSession(in: identity) != nil }?.id ?? "")
        _reviewerID = State(initialValue: snapshot.participations.first { $0.role == "reviewer" && $0.observation_level == "reported" }?.id ?? "")
    }
    private var request: CodingTaskStartRequest {
        .init(request_id: requestID, plan_artifact_id: planID, executor_participation_id: executorID,
              reviewer_participation_id: reviewerID, max_iterations: iterations, files: lines(files), validation_commands: lines(commands),
              executor_model: executorModel.isEmpty ? nil : executorModel)
    }
    var body: some View {
        Form {
            Section("受管执行范围") {
                Text(snapshot.goal).font(.headline)
                Picker("计划版本", selection: $planID) {
                    ForEach(CodingTaskActionPolicy.plans(snapshot)) { ref in Text("v\(ref.version) · \(ref.id)").tag(ref.id) }
                }
                Picker("Executor", selection: $executorID) {
                    ForEach(snapshot.participations.filter { $0.role == "executor" && $0.session_ref.localSession(in: identity) != nil }) { part in
                        Text(part.agent_id).tag(part.id)
                    }
                }
                Picker("Reviewer（由对应客户端回报）", selection: $reviewerID) {
                    ForEach(snapshot.participations.filter { $0.role == "reviewer" && $0.observation_level == "reported" }) { part in
                        Text(part.session_ref.runtime_kind ?? part.agent_id).tag(part.id)
                    }
                }
                if supportsModelSelection {
                    Picker("执行模型", selection: $executorModel) {
                        Text("继承 Runtime 默认模型").tag("")
                        ForEach(catalog?.connections ?? []) { connection in
                            ForEach(connection.models.filter { $0.available && $0.id != nil }, id: \.id) { model in
                                Text(model.id ?? model.runtimeAlias).tag(model.id ?? "")
                            }
                        }
                    }
                    if let catalog { Text("当前默认：\(catalog.defaultRuntimeAlias)").font(.caption).foregroundStyle(.secondary) }
                } else { Text("执行模型：继承 Runtime 默认模型").foregroundStyle(.secondary) }
                if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.orange) }
                Stepper("最大执行轮数：\(iterations)（含首轮）", value: $iterations, in: 1...5)
                TextField("文件范围（工作区相对路径，每行一个，最多 64）", text: $files, axis: .vertical).lineLimit(3...8)
                TextField("验证命令（每行一条，最多 16）", text: $commands, axis: .vertical).lineLimit(3...8)
                Text("验证命令用于验收执行证据；命令由 Code-Agent 按自身工具和审批策略执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(actions.startRequest != nil)
            Text("显式选择的模型会用于本 Run 的每轮执行；省略则继承 Runtime 默认。模型参数和审批仍由 Runtime 管理，审查需 Reviewer 回报。")
                .foregroundStyle(.secondary)
            if let error = actions.errorMessage { Text(error).foregroundStyle(.red) }
            Button(actions.startRequest == nil ? "检查并启动受管任务…" : "重试原启动请求…") { confirm = true }
                .disabled(actions.busy || lines(files).isEmpty || lines(commands).isEmpty || planID.isEmpty || executorID.isEmpty || reviewerID.isEmpty)
            if actions.busy { ProgressView() }
            if let pending = actions.startRequest { Text("请求：\(pending.request_id)").font(.caption.monospaced()).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .navigationTitle("启动受管任务")
        .toolbar { ToolbarItem { Button("关闭") { dismiss() }.disabled(actions.busy) } }
        .interactiveDismissDisabled(actions.busy)
        .task {
            do {
                let before = try await reader.codingTaskCapabilities()
                guard before.identity == identity else { throw CodingTaskReadError.identityChanged }
                guard before.capabilities.contains("task_executor_model_v1"), let models = reader as? any CodingTaskModelReading else { return }
                let result = try await models.codingTaskModels()
                let after = try await reader.codingTaskCapabilities()
                guard after.identity == identity, result.hasSupportedSchema,
                      after.capabilities.contains("task_executor_model_v1") else { throw CodingTaskReadError.identityChanged }
                catalog = result; supportsModelSelection = true
            } catch { catalogError = "模型目录读取失败；可保留默认，启动时由 Runtime 重新校验。" }
        }
        .confirmationDialog("确认开始执行？", isPresented: $confirm, titleVisibility: .visible) {
            Button("按上述范围启动") {
                Task {
                    await actions.start(taskID: snapshot.task_id, request: actions.startRequest ?? request)
                    if actions.completed { onComplete(); dismiss() }
                }
            }
        } message: {
            Text("\(lines(files).count) 个文件，\(lines(commands).count) 条验证命令，最多 \(iterations) 轮。执行模型：\(executorModel.isEmpty ? "继承 Runtime 默认" : executorModel)。可能调用模型 API、产生费用并修改文件。")
        }
    }
}

private func lines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
