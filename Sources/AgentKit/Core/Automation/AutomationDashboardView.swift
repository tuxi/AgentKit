//
// AutomationDashboardView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/8/25.
//

import SwiftUI

public struct AutomationDashboardView: View {

    @Environment(WorkspaceStore.self) private var store
    @Environment(ModelSettingsStore.self) private var modelSettings
    @Environment(AgentRouter.self) private var router

    @State private var viewModel: AutomationDashboardViewModel?
    @State private var selectedAutomation: Automation?
    @State private var isCreatePresented = false

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                viewModel = AutomationDashboardViewModel(client: store.client)
            }
            await viewModel?.load()
        }
        .sheet(item: $selectedAutomation) { automation in
            AutomationEditView(
                automation: automation,
                workspaceStore: store,
                modelSettings: modelSettings
            ) { updated in
                Task {
                    if let vm = viewModel {
                        _ = try? await vm.update(
                            id: updated.id,
                            patch: AutomationPatchRequest(
                                name: updated.name,
                                prompt: updated.prompt,
                                scheduleType: updated.scheduleType,
                                rrule: updated.rrule,
                                scheduledAt: updated.scheduledAt,
                                timezone: updated.timezone,
                                modeExec: updated.modeExec,
                                sessionID: updated.sessionID,
                                cwds: updated.cwds,
                                modelID: updated.modelID,
                                skills: updated.skills,
                                connectors: updated.connectors,
                                permissionMode: updated.permissionMode
                            )
                        )
                    }
                }
            } onDelete: { automation in
                Task {
                    if let vm = viewModel {
                        try? await vm.delete(id: automation.id)
                    }
                }
            }
#if os(macOS)
            .frame(minWidth: 280, maxWidth: 600, alignment: .leading)
#endif
        }
        .sheet(isPresented: $isCreatePresented) {
            AutomationCreateView(workspaceStore: store, modelSettings: modelSettings) { request in
                Task {
                    if let vm = viewModel {
                        _ = try? await vm.create(request)
                    }
                    isCreatePresented = false
                }
            }
#if os(macOS)
            .frame(minWidth: 280, maxWidth: 600, alignment: .leading)
#endif
        }
    }

    @ViewBuilder
    private func content(vm: AutomationDashboardViewModel) -> some View {
        VStack(spacing: 0) {
            if vm.hasRunningAutomation {
                runningBanner
            }

            listHeader(vm: vm)

            if vm.isLoading && !vm.hasLoaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if let err = vm.errorMessage, vm.automations.isEmpty {
                errorView(message: err, vm: vm)
            } else if vm.filteredAutomations.isEmpty {
                emptyView(vm: vm)
            } else {
                list(vm: vm)
            }
        }
#if os(iOS)
        .navigationTitle("自动化")
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: - Banners / list header

    private var runningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.orange)
            Text("自动化运行中，请勿关机或退出客户端")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }

    private func listHeader(vm: AutomationDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(AutomationDashboardTab.allCases) { tab in
                    tabButton(tab, vm: vm)
                }
                Spacer()
                Button {
                    isCreatePresented = true
                } label: {
                    Label("创建", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("共 \(vm.automations.count) 个自动化任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
#if os(iOS)
        .padding(.top, 0)
#endif
    }

    private func tabButton(_ tab: AutomationDashboardTab, vm: AutomationDashboardViewModel) -> some View {
        let isSelected = vm.selectedTab == tab
        return Button {
            vm.selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue)
                    .font(.callout)
                countBadge(for: tab, vm: vm)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func countBadge(for tab: AutomationDashboardTab, vm: AutomationDashboardViewModel) -> some View {
        if count(for: tab, vm: vm) > 0 {
            Text("\(count(for: tab, vm: vm))")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private func count(for tab: AutomationDashboardTab, vm: AutomationDashboardViewModel) -> Int {
        switch tab {
        case .all: return vm.automations.count
        case .active: return vm.activeCount
        case .paused: return vm.pausedCount
        case .completed: return vm.completedCount
        }
    }

    // MARK: - List

    private func list(vm: AutomationDashboardViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(vm.filteredAutomations) { automation in
                    AutomationTaskCard(
                        automation: automation,
                        onOpen: { selectedAutomation = automation },
                        onToggleEnabled: { enabled in
                            Task { _ = try? await vm.setEnabled(id: automation.id, enabled: enabled) }
                        },
                        onDelete: {
                            Task { try? await vm.delete(id: automation.id) }
                        }
                    )
                }
            }
            .padding(14)
        }
    }

    // MARK: - Empty / Error

    @ViewBuilder
    private func emptyView(vm: AutomationDashboardViewModel) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(vm.automations.isEmpty ? "还没有自动化任务" : "该分类下暂无任务")
                .font(.headline)
            Text("让 Agent 定时为你处理重复工作，例如每天下午整理行业行情。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isCreatePresented = true
            } label: {
                Label("创建第一个自动化", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func errorView(message: String, vm: AutomationDashboardViewModel) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await vm.load(force: true) }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AutomationTaskCard

private struct AutomationTaskCard: View {
    let automation: Automation
    let onOpen: () -> Void
    let onToggleEnabled: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(automation.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    statusBadge
                }

                HStack {
                    Text(AutomationScheduleFormatter.nextRunText(for: automation))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    menu
                }
            }
            .padding(12)
#if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
#else
            .background(Color(.systemBackground))
#endif
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(AutomationScheduleFormatter.describe(automation))
        if let cwd = automation.cwds?.first {
            parts.append(cwd)
        }
        return parts.joined(separator: " · ")
    }

    private var statusBadge: some View {
        let color: Color
        let text: String
        switch automation.status {
        case .active:
            color = .green
            text = "进行中"
        case .paused:
            color = .orange
            text = "已暂停"
        case .completed:
            color = .gray
            text = "已完成"
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var menu: some View {
        Menu {
            Button("查看", action: onOpen)
            if automation.status == .active {
                Button("暂停") { onToggleEnabled(false) }
            } else if automation.status == .paused {
                Button("启用") { onToggleEnabled(true) }
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - AutomationCreateView

private struct AutomationCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let workspaceStore: WorkspaceStore
    let modelSettings: ModelSettingsStore
    let onCreate: (AutomationCreateRequest) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var scheduleType: AutomationScheduleType = .recurring
    @State private var rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
    @State private var scheduledAt: Date = Date()
    @State private var timezone = TimeZone.current.identifier
    @State private var modeExec: AutomationRunMode = .standalone
    @State private var sessionID = ""
    @State private var cwd = ""
    @State private var permissionMode = ""
    @State private var connectors: [String] = []
    @State private var modelID = ""
    @State private var workspace: Workspace?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack {
                        Text("名称")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("", text: $name)
                    }
                    VStack {
                        Text("Prompt")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PromptComposerPanel(
                            placeholder: "描述这个自动化任务要做的事，例如：每天下午 4 点整理科技股行业行情，输出到 reports/。",
                            text: $prompt,
                            modelID: $modelID,
                            workspace: $workspace
                        )
                        .environment(modelSettings)
                        .environment(workspaceStore)
                    }
                } header: {
                    Text("基本信息")
                }

                Section {
                    Picker("类型", selection: $scheduleType) {
                        Text("循环")
                            .tag(AutomationScheduleType.recurring)
                        Text("一次性")
                            .tag(AutomationScheduleType.once)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 100)

                    if scheduleType == .recurring {
                        TextField("规则（RFC5545）", text: $rrule)
                        Text("如 FREQ=DAILY;BYHOUR=9;BYMINUTE=0，或 FREQ=WEEKLY;BYDAY=MO;BYHOUR=9")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else {
                        DatePicker("执行时间", selection: $scheduledAt)
#if os(iOS)
                            .datePickerStyle(.compact)
#else
                            .datePickerStyle(.field)
#endif
                        Text("选择该自动化任务首次执行的时间点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("时区（IANA）", text: $timezone)
                } header: {
                    Text("调度")
                }

                Section {
                    VStack {
                        Text("模式")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("", selection: $modeExec) {
                            Text("独立对话").tag(AutomationRunMode.standalone)
                            Text("回到会话").tag(AutomationRunMode.chat)
                        }
                        .pickerStyle(.segmented)
                        if modeExec == .chat {
                            HStack {
                                AutomationSessionPicker(workspace: workspace, sessionID: $sessionID)
                                    .environment(workspaceStore)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("运行方式")
                }
                
                Section {
                    Picker("权限级别", selection: $permissionMode) {
                        Text("默认权限").tag("")
                        Text("Full access").tag("full_access")
                    }
                    Text("连接器免确认：\(connectors.isEmpty ? "无" : connectors.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("权限")
                }
                
                Section {
                    Button {
                        // 工作区：优先用面板选中的 workspace；否则回退到手动填写的 cwd。
                        var cwds: [String] = []
                        if let ws = workspace {
                            cwds = [ws.url.path]
                        } else if !cwd.isEmpty {
                            cwds = [cwd]
                        }
                        // 模型：把 App 侧 modelID 映射为 runtime wire model id。
                        let wireModelID = modelID.isEmpty ? nil : (modelSettings.getWireModelID(for: modelID) ?? modelID)
                        let request = AutomationCreateRequest(
                            name: name,
                            prompt: prompt,
                            scheduleType: scheduleType,
                            rrule: scheduleType == .recurring ? rrule : nil,
                            scheduledAt: scheduleType == .once ? AutomationScheduleFormatter.rfc3339(scheduledAt) : nil,
                            timezone: timezone,
                            modeExec: modeExec,
                            sessionID: modeExec == .chat ? sessionID : nil,
                            cwds: cwds,
                            modelID: wireModelID,
                            skills: [],
                            connectors: connectors,
                            permissionMode: permissionMode.isEmpty ? nil : permissionMode,
                            enabled: true
                        )
                        onCreate(request)
                    } label: {
                        Text("创建")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新建自动化")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - AutomationEditView

private struct AutomationEditView: View {
    let automation: Automation
    let workspaceStore: WorkspaceStore
    let modelSettings: ModelSettingsStore
    let onSave: (Automation) -> Void
    let onDelete: (Automation) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var prompt: String
    @State private var scheduleType: AutomationScheduleType
    @State private var rrule: String
    @State private var scheduledAt: Date
    @State private var timezone: String
    @State private var modeExec: AutomationRunMode
    @State private var sessionID: String
    @State private var cwd: String
    @State private var permissionMode: String
    @State private var connectors: [String]
    @State private var isEnabled: Bool
    @State private var modelID: String
    @State private var workspace: Workspace?
    @State private var confirmDelete = false

    init(
        automation: Automation,
        workspaceStore: WorkspaceStore,
        modelSettings: ModelSettingsStore,
        onSave: @escaping (Automation) -> Void,
        onDelete: @escaping (Automation) -> Void
    ) {
        self.automation = automation
        self.workspaceStore = workspaceStore
        self.modelSettings = modelSettings
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: automation.name)
        _prompt = State(initialValue: automation.prompt)
        _scheduleType = State(initialValue: automation.scheduleType)
        _rrule = State(initialValue: automation.rrule ?? "")
        _scheduledAt = State(initialValue: AutomationScheduleFormatter.parseRFC3339(automation.scheduledAt ?? "") ?? Date())
        _timezone = State(initialValue: automation.timezone)
        _modeExec = State(initialValue: automation.modeExec)
        _sessionID = State(initialValue: automation.sessionID ?? "")
        _cwd = State(initialValue: automation.cwds?.first ?? "")
        _permissionMode = State(initialValue: automation.permissionMode ?? "")
        _connectors = State(initialValue: automation.connectors ?? [])
        _isEnabled = State(initialValue: automation.status == .active)
        _modelID = State(initialValue: automation.modelID ?? "")
        _workspace = State(initialValue: Self.resolveWorkspace(automation: automation, store: workspaceStore))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack {
                        Text("名称")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("", text: $name)
                    }
                    VStack {
                        Text("Prompt")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PromptComposerPanel(
                            placeholder: "描述这个自动化任务要做的事，例如：每天下午 4 点整理科技股行业行情，输出到 reports/。",
                            text: $prompt,
                            modelID: $modelID,
                            workspace: $workspace
                        )
                        .environment(modelSettings)
                        .environment(workspaceStore)
                    }
                } header: {
                    Text("基本信息")
                }

                Section {
                    Picker("类型", selection: $scheduleType) {
                        Text("循环")
                            .tag(AutomationScheduleType.recurring)
                        Text("一次性")
                            .tag(AutomationScheduleType.once)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 100)

                    if scheduleType == .recurring {
                        TextField("规则（RFC5545）", text: $rrule)
                        Text("如 FREQ=DAILY;BYHOUR=9;BYMINUTE=0，或 FREQ=WEEKLY;BYDAY=MO;BYHOUR=9")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else {
                        DatePicker("执行时间", selection: $scheduledAt)
#if os(iOS)
                            .datePickerStyle(.compact)
#else
                            .datePickerStyle(.field)
#endif
                        Text("选择该自动化任务首次执行的时间点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("时区（IANA）", text: $timezone)
                } header: {
                    Text("调度")
                }

                Section {
                    VStack {
                        Text("模式")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("", selection: $modeExec) {
                            Text("独立对话").tag(AutomationRunMode.standalone)
                            Text("回到会话").tag(AutomationRunMode.chat)
                        }
                        .pickerStyle(.segmented)
                        if modeExec == .chat {
                            HStack {
                                AutomationSessionPicker(workspace: workspace, sessionID: $sessionID)
                                    .environment(workspaceStore)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("运行方式")
                }

                Section {
                    Picker("权限级别", selection: $permissionMode) {
                        Text("默认权限").tag("")
                        Text("Full access").tag("full_access")
                    }
                    Text("连接器免确认：\(connectors.isEmpty ? "无" : connectors.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("权限")
                }

                Section {
                    Toggle("启用（暂停/恢复）", isOn: $isEnabled)
                }

                Section {
                    Button("删除任务", role: .destructive) {
                        confirmDelete = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(automation.name)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "确定删除这个自动化任务吗？",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    onDelete(automation)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
#if os(macOS)
        .frame(minWidth: 280, maxWidth: 600, alignment: .leading)
#endif
        .onAppear {
            if workspace != nil {
                return
            }
            if let ws = workspaceStore.draft?.workspace {
                workspace = ws
            } else {
                if let selectedConversation = workspaceStore.selectedConversation, let url = URL(string: selectedConversation.workspacePath) {
                    workspace = Workspace(url: url, branch: nil)
                }
            }
        }
    }

    private func save() {
        var updated = automation
        updated.name = name
        updated.prompt = prompt
        updated.scheduleType = scheduleType
        updated.rrule = scheduleType == .recurring ? rrule : nil
        updated.scheduledAt = scheduleType == .once ? AutomationScheduleFormatter.rfc3339(scheduledAt) : nil
        updated.timezone = timezone
        updated.modeExec = modeExec
        updated.sessionID = modeExec == .chat ? sessionID : nil

        // 工作区：优先用面板选中的 workspace；否则保留已保存的 cwds。
        var cwds: [String] = []
        if let ws = workspace {
            cwds = [ws.url.path]
        } else if !cwd.isEmpty {
            cwds = [cwd]
        } else {
            cwds = automation.cwds ?? []
        }
        updated.cwds = cwds

        // 模型：把 App 侧 modelID 映射为 runtime wire model id。
        let wireModelID = modelID.isEmpty ? nil : (modelSettings.getWireModelID(for: modelID) ?? modelID)
        updated.modelID = wireModelID

        updated.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        updated.connectors = connectors
        updated.status = isEnabled ? .active : .paused
        onSave(updated)
        dismiss()
    }

    /// 根据已保存的 automation 解析出对应的 Workspace（供面板预选）。
    private static func resolveWorkspace(automation: Automation, store: WorkspaceStore) -> Workspace? {
        guard let path = automation.cwds?.first, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return Workspace(url: url)
    }
}
