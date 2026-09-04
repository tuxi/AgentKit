//
//  PromptComposerPanel.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/8/25.
//

import SwiftUI

// MARK: - PromptComposerPanel

/// 自动化创建表单的「Prompt + 工作区 + 模型」输入面板。
///
/// 这不是聊天输入栏，而是精简的配置面板 —— 只承载创建自动化任务所需的三样东西：
///   1. 运行指令（prompt）多行编辑
///   2. 目标工作区（cwds[0]，来自最近工作区 / 项目）
///   3. 运行模型（model_id，来自模型目录）
///
/// 通过 @Binding 把三者回传给宿主的创建表单，由宿主组装 `AutomationCreateRequest`。
/// 不再复制聊天输入栏的语音、审批权限菜单、草稿工作区 chip —— 后者在无会话草稿时
/// 渲染为空，正是此前「样式非常难看」的根因。
struct PromptComposerPanel: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(ModelSettingsStore.self) private var modelSettings

    let placeholder: String

    /// 运行指令（prompt）。
    @Binding var text: String
    /// 选中的模型（App 侧 id，即 `modelSettings.availableModelIDs` 之一）。
    @Binding var modelID: String
    /// 选中的工作区（用于 `cwds[0]`）。
    @Binding var workspace: Workspace?

    @State private var contentWidth: CGFloat = 0
    
    @State private var isImporterPresented = false
    @State private var isNewProjectPresented = false
    @State private var newProjectName = ""
    @State private var createError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptEditor
            controls
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, newValue in
            contentWidth = newValue
        }
    }

    // MARK: - Prompt editor

    private var promptEditor: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 88, maxHeight: 160)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Controls (workspace + model)

    private var controls: some View {
        HStack(spacing: 8) {
            workspaceMenu {
                if let workspace {
                    controlChip(icon: "folder", text: workspace.name)
                } else {
                    controlChip(icon: "folder.badge.plus", text: AgentKitLocalized.string("workspace.select_workspace"))
                }
            }
            Spacer()
            modelMenu
        }
    }

    // MARK: Workspace

    private func workspaceMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            if !workspaceStore.recentWorkspaces.workspaces.isEmpty {
                Section("Recent") {
                    ForEach(workspaceStore.recentWorkspaces.workspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            if workspaceStore.projects.isAvailable {
                // iOS：Documents 项目列表（排除已在 Recent 中的，避免重复）。
                let recentIDs = Set(workspaceStore.recentWorkspaces.workspaces.map(\.id))
                let others = workspaceStore.projects.projects.filter { !recentIDs.contains($0.id) }
                if !others.isEmpty {
                    Section("Projects") {
                        ForEach(others) { ws in
                            workspaceButton(ws)
                        }
                    }
                }
                Divider()
                Menu {
                    Button {
                        newProjectName = "New Project"
                        isNewProjectPresented = true
                    } label: {
                        Label(AgentKitLocalized.string("workspace.new_blank_project"), systemImage: "folder.badge.plus")
                    }
                    Button {
                        if isImporterPresented == true {
                            isImporterPresented = false
                            Task {
                                try? await Task.sleep(for: .seconds(1))
                                await MainActor.run {
                                    isImporterPresented = true
                                }
                            }
                        } else {
                            isImporterPresented = true
                        }
                        
                    } label: {
                        #if os(macOS)
                        Label(AgentKitLocalized.string("workspace.use_existing_folder"), systemImage: "folder")
                        #else
                        Label(AgentKitLocalized.string("workspace.import_existing_folder"), systemImage: "square.and.arrow.down")
                        #endif
                    }
                } label: {
                    Label(AgentKitLocalized.string("workspace.new_project"), systemImage: "plus")
                }
            } else {
                // macOS：无工作区根 → 任意文件夹选择。
                Divider()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(workspaceStore.isPreparingWorkspace)   // clone/import 进行中禁止再选目录
    }
    
    private func workspaceButton(_ ws: Workspace) -> some View {
        Button {
            workspaceStore.selectWorkspace(ws)
            workspace = ws
        } label: {
            Label(ws.name, systemImage: "folder")
        }
    }

    // MARK: Model

    @ViewBuilder
    private var modelMenu: some View {
        Menu {
            let groups = modelSettings.unifiedModelGroups
            if groups.isEmpty {
                ForEach(modelSettings.availableModelIDs, id: \.self) { id in
                    modelButton(id)
                }
            } else {
                ForEach(groups, id: \.connectionID) { group in
                    Section {
                        ForEach(group.models, id: \.id) { model in
                            modelButton(model.id)
                        }
                    } header: {
                        Text(group.name)
                    }
                }
            }
        } label: {
            controlChip(
                icon: "brain.head.profile",
                text: modelSettings.displayName(for: modelID),
                isPlaceholder: modelID.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(modelSettings.availableModelIDs.isEmpty)
        .onAppear { prefillModelIfNeeded() }
        .onChange(of: modelSettings.availableModelIDs) { _, _ in
            prefillModelIfNeeded()
        }
    }

    @ViewBuilder
    private func modelButton(_ id: String) -> some View {
        Button {
            modelID = id
        } label: {
            HStack {
                Text(modelSettings.displayName(for: id))
                if id == modelID {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    // MARK: - Chip

    private func controlChip(icon: String, text: String, isPlaceholder: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            if contentWidth >= 230 {
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isPlaceholder ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
        )
        .foregroundStyle(isPlaceholder ? Color.accentColor : Color.primary)
        .opacity(isPlaceholder ? 1 : 0.9)
    }

    // MARK: - Helpers

    /// 初次加载 / 模型目录刷新时，把默认模型回填进绑定（便于用户直接创建）。
    private func prefillModelIfNeeded() {
        guard modelID.isEmpty else { return }
        let fallback = modelSettings.modelForNewConversation
        if !fallback.0.isEmpty, modelSettings.isModelAvailable(fallback.0) {
            modelID = fallback.0
        }
    }
}

