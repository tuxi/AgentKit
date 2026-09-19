//
//  PlanApprovalBar.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/9/19.
//

import SwiftUI

// MARK: - PlanApprovalBar

/// Plan Mode 审批卡片 — 展示完整 plan markdown。
/// 比工具审批更大，提供 Approve / Reject 按钮。
struct PlanApprovalBar: View {
    let plan: PlanApprovalRequest
    let onApprove: () -> Void
    let onReject: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var titleHeight: CGFloat = 0
    
    private var displayPath: String? {
        plan.planPath ?? plan.filePath
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                // Header
                header
                
                if let path = displayPath, !path.isEmpty {
                    planPathRow(path)
                }
                
                // Plan content — DAG rendering for workflow plans, markdown otherwise
                if let dag = parseWorkflowDAG(from: plan.content) {
                    workflowDAGPreview(dag: dag)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        MarkdownRenderer(text: plan.content)
                            .font(.caption)
                            .onGeometryChange(for: CGFloat.self) { poxy in
                                poxy.size.height
                            } action: { newValue in
                                contentHeight = newValue
                            }
                        
                    }
                    .frame(height: max(0, min(280, contentHeight)))
                    .padding(12)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Action buttons
                HStack(spacing: 8) {
                    
                    Button(role: .destructive, action: onReject) {
                        Label("Reject", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button(action: onApprove) {
                        Label("Approve Plan", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.approvalPanelBackground)
        .layerBorder()
        .padding(12)
    }
    
    private var isWorkflowDAG: Bool {
        plan.content.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
    }
    
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWorkflowDAG ? "flowchart.fill" : "text.document.fill")
                .foregroundStyle(isWorkflowDAG ? .purple : .blue)
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 2) {
                ScrollView(.vertical) {
                    Text(plan.title)
                        .font(.subheadline.weight(.semibold))
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newValue in
                            titleHeight = newValue
                        }
                    
                }
                .frame(maxHeight: min(titleHeight, 70))
                
                Text(isWorkflowDAG ? "Workflow Plan" : "Proposed Plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let deadline = plan.deadlineSeconds {
                Text("\(deadline)s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onApprove) {
                Label("Approve Plan", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Button(role: .destructive, action: onReject) {
                Label("Reject", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
    
    private func planPathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            
            Spacer()
            
#if os(macOS)
            if canOpenPlanFile {
                Button {
                    openPlanFile()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Open plan file")
            }
#endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
    
#if os(macOS)
    private var canOpenPlanFile: Bool {
        guard let filePath = plan.filePath, !filePath.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: filePath)
    }
    
    private func openPlanFile() {
        guard let filePath = plan.filePath else { return }
        
        openFolderInFinder(path: filePath)
    }
#endif
    
    // MARK: - Workflow DAG detection & preview
    
    private func parseWorkflowDAG(from jsonString: String) -> DAGApprovalData? {
        guard let firstChar = jsonString.trimmingCharacters(in: .whitespacesAndNewlines).first,
              firstChar == "{" else { return nil }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        guard let dag = try? JSONDecoder().decode(DAGApprovalData.self, from: data),
              !dag.nodes.isEmpty else { return nil }
        return dag
    }
    
    @ViewBuilder
    private func workflowDAGPreview(dag: DAGApprovalData) -> some View {
        let nodes = dag.nodes.map { wn in
            WorkflowNode(
                name: wn.name,
                type: wn.type ?? (wn.tool != nil ? "tool" : "unknown"),
                state: .pending,
                toolName: wn.tool,
                inputMapping: wn.inputMapping
            )
        }
        let edges = (dag.edges ?? []).map { WorkflowEdge(from: $0.from, to: $0.to) }
        
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flowchart.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("Workflow DAG")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(dag.nodes.count) nodes, \(dag.edges?.count ?? 0) edges")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                WorkflowDAGLayoutView(nodes: nodes, edges: edges)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}


// MARK: - ApprovalBar

/// 文本高度测量 PreferenceKey。
private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 审批拦截栏 — 显示在输入框上方，阻断 input pipeline。
/// 对标 Claude Code / Cursor：审批不是消息，而是阻塞输入的状态。

/// v1.2 三态审批作用域。
private enum ApprovalScope: String, CaseIterable, Hashable {
    case local = "local"
    case user = "user"
    
    var label: String {
        switch self {
        case .local: return "Project (local)"
        case .user: return "User (global)"
        }
    }
}

// 扩展三态选择的回调
struct ApprovalBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let request: ApprovalRequest
    
    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "the agent"
    }
    
    private var approvalHeaderText: String {
        if request.isExternalPathAccess {
            return String(format: AgentKitLocalized.string("composer.request_file_access"), appDisplayName)
        }
        return "Allow \(appDisplayName) to run \(request.displayToolName)?"
    }
    
    
    // 三态回调映射图中的按钮
    let onDeny: () -> Void          // Deny 1
    let onAlwaysAllow: (String) -> Void    // Always allow 2 — 参数为 scope ("local" | "user")
    let onAllowOnce: () -> Void      // Allow once 3 ↩
    
    @State private var scope: ApprovalScope = .local
    @State private var contentHeight: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 0) {
                // 1. 顶部 Header 栏
                HStack(alignment: .center, spacing: 6) {
                    // 左侧黄色小圆点指示器
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    
                    Text(approvalHeaderText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    // 右侧 scope 选择标签（点击切换）— 外部路径访问无需 scope
                    if !request.isExternalPathAccess {
                        Menu {
                            Picker("Scope", selection: $scope) {
                                ForEach(ApprovalScope.allCases, id: \.self) { s in
                                    Text(s.label).tag(s)
                                }
                            }
                        } label: {
                            Text(scope.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.approvalPanelBackground.opacity(0.5))
                                .cornerRadius(4)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                // 2. 中间工具与参数内容区 (类似代码块容器)
                VStack(alignment: .leading, spacing: 8) {
                    // 外部路径访问：显示路径卡片
                    if request.isExternalPathAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(request.externalPathTarget)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(request.externalPathOperation)
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // MCP 工具：显示 server → tool 解析结果
                    if request.isMCP, let server = request.mcpServer {
                        HStack(spacing: 4) {
                            Text("MCP Server:")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(server)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text("→")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(request.mcpBareToolName)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    if let args = request.toolArgs, case .object(let dict) = args, !dict.isEmpty, !request.isExternalPathAccess {
                        // 测量文本真实高度：≤10行自适应；>10行固定180pt可滚动
                        ScrollView(.vertical, showsIndicators: true) {
                            argsText(dict)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TextHeightKey.self,
                                        value: geo.size.height
                                    )
                                })
                                .frame(maxWidth: .infinity)
                        }
                        .onPreferenceChange(TextHeightKey.self) { contentHeight = $0 }
                        .frame(height: contentHeight > 0 ? min(contentHeight, 180) : nil)
                        .animation(.none, value: contentHeight)
                        
                    } else if !request.isMCP, !request.isExternalPathAccess {
                        Text("No arguments provided.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
//                .background(Color.approvalSecondaryFill)
                .background(Color.approvalPanelBackground)
                .cornerRadius(6)
                .padding(.horizontal, 14)
                
                // 3. 底部三态按钮操作栏
                HStack(spacing: 8) {
                    // Deny 1
                    Button(action: onDeny) {
                        Text("Deny ") + Text("1").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Spacer()
                    
                    // Always allow 2 — MCP 工具显示 server 级提示
                    if !request.isExternalPathAccess {
                        Button(action: { onAlwaysAllow(scope.rawValue) }) {
                            VStack(alignment: .center, spacing: 1) {
                                Text("Always allow ") + Text("2").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .overlay(alignment: .top) {
                            if request.isMCP, let server = request.mcpServer {
                                Text("all from \"\(server)\"")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .offset(CGSizeMake(0, 20))
                            }
                        }
                    }
                    
                    // Allow once 3 ↩ (高亮主按钮)
                    Button(action: onAllowOnce) {
                        HStack(spacing: 4) {
                            Text("Allow once ") + Text("3 ⌘↩")
                        }
                        .foregroundStyle(colorScheme == .light ? .white.opacity(0.7) : .black.opacity(0.7) )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.approvalPanelBackground)
            .layerBorder()
            .padding(12)
        }
    }
    
    private func argsSummary(_ dict: [String: JSONValue]) -> String {
        dict.map { "\($0.key): \($0.value.stringValue)" }.joined(separator: "\n")
    }
    
    private func argsText(_ dict: [String: JSONValue]) -> some View {
        Text(argsSummary(dict))
        //            .textSelection(.enabled)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AskUserBar

/// ask_user 卡片 — 显示在输入框上方，阻断 input pipeline。
/// 模型遇到歧义时展示选项供用户选择。优先级：AskUser > Plan > Approval。
struct AskUserBar: View {
    let request: AskUserRequest
    let onSubmit: ([String], String?) -> Void
    let onSkip: () -> Void
    @State var optionsListHeight: CGFloat = 0
    
    @State private var selectedLabels: Set<String> = []
    @State private var customText: String = ""
    @State private var isExpanded: Bool = true
    
    /// 推荐项 label（含 `(Recommended)` 或 `（推荐）` 后缀），自动预选。
    private var recommendedLabel: String? {
        request.options.first { request.isRecommended($0) }?.label
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                // Header
                headerRow
                
                // Question text
                Text(request.question.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    
                
                // Options list
                if isExpanded {
                    ScrollView(.vertical) {
                        optionsList
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { newValue in
                                self.optionsListHeight = newValue
                            }
                    }
                    .frame(height: max(0, min(280, self.optionsListHeight)))
                }
                
                // Custom input (only when allowCustom)
                if request.allowCustom, isExpanded {
                    customInputRow
                }
                
                // Action buttons
                if isExpanded {
                    actionButtons
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.approvalPanelBackground)
        .layerBorder()
        .padding(12)
        .onAppear {
            // Auto-select recommended option
            if let rec = recommendedLabel {
                selectedLabels = [rec]
            }
        }
    }
    
    // MARK: - Header
    
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(request.header.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(5)
                
                Text(request.multiSelect ? AgentKitLocalized.string("composer.multi_select") : AgentKitLocalized.string("composer.please_select"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Deadline badge
            if let deadline = request.deadlineSeconds {
                Text("\(deadline)s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            
            // Collapse/expand toggle
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? AgentKitLocalized.string("composer.collapse") : AgentKitLocalized.string("composer.expand"))
            
            // Skip button
            Button(action: onSkip) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(AgentKitLocalized.string("composer.skip_question"))
        }
    }
    
    // MARK: - Options
    
    private var optionsList: some View {
        VStack(spacing: 6) {
            ForEach(request.options) { option in
                optionRow(option)
            }
        }
    }
    
    private func optionRow(_ option: AskUserOption) -> some View {
        let isSelected = selectedLabels.contains(option.label)
        let isRecommended = request.isRecommended(option)
        
        return Button {
            if request.multiSelect {
                if isSelected {
                    selectedLabels.remove(option.label)
                } else {
                    selectedLabels.insert(option.label)
                }
            } else {
                selectedLabels = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Selection indicator
                Group {
                    if request.multiSelect {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    } else {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }
                }
                .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        
                        if isRecommended {
                            Text(verbatim: AgentKitLocalized.string("composer.recommended"))
                                .font(.system(size: 9))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Custom input
    
    private var customInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .foregroundStyle(.secondary)
                .font(.caption)
            
            TextField(AgentKitLocalized.string("composer.custom_input_optional"), text: $customText)
                .textFieldStyle(.plain)
                .font(.subheadline)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Actions
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onSkip) {
                Label(AgentKitLocalized.string("composer.skip"), systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Button {
                let notes = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                onSubmit(Array(selectedLabels), notes.isEmpty ? nil : notes)
            } label: {
                Label(AgentKitLocalized.string("composer.confirm_selection"), systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedLabels.isEmpty && customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

// 辅助扩展：便于快速绘制带圆角的细边框
extension View {
    func layerBorder() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Workflow DAG approval JSON types

/// 审批卡中 workflow DAG 定义的轻量 Decodable。
/// `plan_approval_request.content` 为 JSON string 且首字符为 `{` 时尝试解码为此类型。
private struct DAGApprovalData: Decodable {
    let nodes: [DAGApprovalNode]
    let edges: [DAGApprovalEdge]?
}

private struct DAGApprovalNode: Decodable {
    let name: String
    let tool: String?
    let type: String?
    let label: String?
    let inputMapping: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case name, tool, type, label
        case inputMapping = "input_mapping"
    }
}

private struct DAGApprovalEdge: Decodable {
    let from: String
    let to: String
}

