//
//  AutomationWorkflowTargetView.swift
//  AgentKit
//
//  P3 — 自动化「工作流模板」执行目标：模板选择 + 触发参数表单 + 重叠策略。
//  定时触发时直接跑模板（0 LLM token），prompt 被忽略。
//
//  数据源：
//  - 模板列表：所选 workspace 的 workflow（is_template=true）
//  - 参数表单：从所选模板 manifest 的 inputs[] 生成（tool_sequence 声明式 schema），
//    无 inputs 时降级为原始 JSON 编辑器
//

import SwiftUI
import ClientToolProtocol

/// 自动化的「执行目标」：对话任务（Prompt）或工作流模板。
enum AutomationExecutionMode: String, CaseIterable, Identifiable {
    case conversation = "对话任务"
    case workflow = "工作流模板"
    var id: String { rawValue }
}

/// 工作流模板执行目标视图。绑定三个产物值：
/// - `workflowRef`："workspace_path#workflow_name"（选中模板时写入）
/// - `workflowInput`：触发参数 JSON 对象
/// - `overlapPolicy`：skip | allow_all
struct AutomationWorkflowTargetView: View {
    let workspace: Workspace?
    let workspaceStore: WorkspaceStore

    @Binding var workflowRef: String
    @Binding var workflowInput: JSONValue?
    @Binding var overlapPolicy: String

    @State private var templates: [WorkflowSummary] = []
    @State private var isLoadingTemplates = false
    @State private var selectedName = ""
    @State private var manifest: WorkflowManifest?
    @State private var inputTexts: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var rawInputJSON = ""

    private var workspacePath: String? { workspace?.url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            templatePicker

            if !selectedName.isEmpty {
                Divider()
                paramForm
                Divider()
                overlapPicker
            }
        }
        .task(id: workspace?.url.path) { await loadTemplates() }
    }

    // MARK: - 模板选择

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模板")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Menu {
                if workspace == nil {
                    Text("请先选择工作区")
                } else if isLoadingTemplates {
                    Text("加载中…")
                } else if templates.isEmpty {
                    Text("该工作区没有可用模板")
                } else {
                    ForEach(templates) { template in
                        Button {
                            select(template: template)
                        } label: {
                            HStack {
                                Text(template.name)
                                if template.name == selectedName {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "flowchart")
                        .font(.system(size: 11, weight: .medium))
                    Text(selectedName.isEmpty ? "选择工作流模板" : selectedName)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .foregroundStyle(Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(workspace == nil || isLoadingTemplates)
        }
    }

    // MARK: - 参数表单

    @ViewBuilder
    private var paramForm: some View {
        if let inputs = manifest?.inputs, !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("触发参数")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(inputs) { input in
                    inputField(input)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("触发参数（JSON）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $rawInputJSON)
                    .font(.caption.monospaced())
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .onChange(of: rawInputJSON) { _, _ in parseRawJSON() }
            }
        }
    }

    @ViewBuilder
    private func inputField(_ input: WorkflowManifestInput) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(input.name)
                    .font(.caption.weight(.medium))
                if input.required == true {
                    Text("*")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if input.type == "boolean" {
                let isOn = Binding<Bool>(
                    get: { boolValues[input.name] ?? false },
                    set: { newValue in
                        boolValues[input.name] = newValue
                        inputTexts[input.name] = newValue ? "true" : "false"
                        rebuildInput()
                    }
                )
                Toggle(input.name, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            } else {
                let value = Binding<String>(
                    get: { inputTexts[input.name] ?? "" },
                    set: { newValue in
                        inputTexts[input.name] = newValue
                        rebuildInput()
                    }
                )
                TextField(input.description ?? input.type ?? "值", text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
            }

            if let description = input.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 重叠策略

    private var overlapPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("重叠策略")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("重叠策略", selection: $overlapPolicy) {
                Text("跳过（有活跃 run 则跳过本次）").tag("skip")
                Text("无条件触发").tag("allow_all")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 数据加载

    private func loadTemplates() async {
        guard let path = workspace?.url.path else {
            templates = []
            selectedName = ""
            workflowRef = ""
            return
        }
        isLoadingTemplates = true
        defer { isLoadingTemplates = false }
        do {
            let all = try await workspaceStore.client.listWorkspaceWorkflows(workspacePath: path)
            templates = all.filter { $0.isTemplate }.sorted { $0.name < $1.name }
            // workspace 变化后清空已选模板（模板属于原 workspace）
            if selectedName != "", !templates.contains(where: { $0.name == selectedName }) {
                selectedName = ""
                workflowRef = ""
                manifest = nil
                inputTexts = [:]
                workflowInput = nil
            }
        } catch {
            templates = []
        }
    }

    private func select(template: WorkflowSummary) {
        selectedName = template.name
        workflowRef = [workspacePath, template.name].compactMap { $0 }.joined(separator: "#")
        workflowInput = nil
        manifest = nil
        inputTexts = [:]
        boolValues = [:]
        rawInputJSON = ""
        Task { await loadManifest(template: template) }
    }

    private func loadManifest(template: WorkflowSummary) async {
        guard let path = workspacePath else { return }
        do {
            let detail = try await workspaceStore.client.getWorkspaceWorkflowDetail(
                workspacePath: path, name: template.name
            )
            let m = WorkflowManifest.fromJSONValue(detail.manifest)
            manifest = m
            if let inputs = m?.inputs {
                inputTexts = Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, "") })
            }
        } catch {
            manifest = nil
        }
    }

    // MARK: - 构建 workflowInput

    /// 从 inputs 表单字段构建 JSON 对象；全部为空则 nil。
    private func rebuildInput() {
        var dict: [String: JSONValue] = [:]
        for (key, value) in inputTexts where !value.isEmpty {
            dict[key] = .string(value)
        }
        workflowInput = dict.isEmpty ? nil : .object(dict)
    }

    private func parseRawJSON() {
        let trimmed = rawInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            workflowInput = nil
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = JSONValue.from(any: obj) else {
            workflowInput = nil
            return
        }
        workflowInput = value
    }
}
