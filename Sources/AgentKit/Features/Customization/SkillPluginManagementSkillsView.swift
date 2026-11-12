//
//  SkillPluginManagementSkillsView.swift
//  AgentKit
//

import SwiftUI

struct SkillPluginManagementSkillsView: View {
    @Bindable var viewModel: SkillPluginManagementViewModel
    let onSelectSkill: (RuntimeSkillItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    stateBanners
                    filters

                    if viewModel.isLoading && viewModel.skillInventory.items.isEmpty {
                        ProgressView("正在读取 Runtime Skill Inventory…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if let error = viewModel.skillError {
                        ManagementBanner(
                            title: "技能清单不可用",
                            message: error,
                            tone: .error
                        ) {
                            Button("重试") { Task { await viewModel.refresh() } }
                                .buttonStyle(.borderless)
                        }
                    } else if visibleItemCount == 0 {
                        ManagementEmptyState(
                            icon: "sparkles",
                            title: emptyTitle,
                            message: emptyMessage
                        )
                    } else {
                        ForEach(viewModel.groups) { group in
                            let skills = viewModel.visibleSkills(for: group)
                            if !skills.isEmpty {
                                skillGroup(group, skills: skills)
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
        .accessibilityIdentifier("customization.skills")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills")
                    .font(.system(size: 22, weight: .semibold))
                Text(verbatim: viewModel.scopeTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing || viewModel.capabilityUnavailable)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var stateBanners: some View {
        if viewModel.capabilityUnavailable {
            ManagementBanner(
                title: "当前 Runtime 不支持 Skill 管理",
                message: "Runtime 未声明 skill_plugin_management_v1。请升级并重新连接 Runtime。",
                tone: .warning
            )
        }
        if viewModel.requiresAuthentication {
            ManagementBanner(
                title: "需要 Runtime 认证",
                message: "请在“服务器”设置中检查该 Runtime 的访问令牌。管理 API 不会绕过 401。",
                tone: .error
            )
        }
        if viewModel.sessionID == nil {
            ManagementBanner(
                title: "Project 技能需要会话",
                message: "当前未选择会话。Runtime 仅返回 Personal、System 与 Plugin 技能；不会使用 workspace_path 绕过会话作用域。",
                tone: .info
            )
        } else if !viewModel.scopeResolved && !viewModel.skillInventory.items.isEmpty {
            ManagementBanner(
                title: "工作区作用域未解析",
                message: "该会话尚未完成 workspace rebind，Project 技能可能缺失。",
                tone: .warning
            )
        }
        if viewModel.reloadRequired {
            ManagementBanner(
                title: "Runtime 重启后生效",
                message: viewModel.reloadHint ?? "当前清单来自 Runtime 启动快照。重启后再刷新。",
                tone: .warning
            )
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索名称、描述或 scope", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Picker("状态", selection: $viewModel.visibilityFilter) {
                ForEach(RuntimeSkillVisibilityFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            if let group = viewModel.sourceFilter {
                HStack(spacing: 7) {
                    ManagementBadge(
                        text: "已筛选 \(group.localizedDisplayName)",
                        systemImage: "line.3.horizontal.decrease.circle",
                        tone: .accent
                    )
                    Button("清除") {
                        viewModel.sourceFilter = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func skillGroup(_ group: RuntimeSkillSourceGroup, skills: [RuntimeSkillItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ManagementSectionHeader(
                title: group.localizedDisplayName,
                subtitle: groupDescription(group),
                count: skills.count
            )
            ForEach(skills) { skill in
                SkillRow(skill: skill) { onSelectSkill(skill) }
            }
        }
        .accessibilityIdentifier("customization.skills.group.\(group.rawValue)")
    }

    private var visibleItemCount: Int {
        viewModel.groups.reduce(0) { count, group in
            count + viewModel.visibleSkills(for: group).count
        }
    }

    private var emptyTitle: String {
        viewModel.searchText.isEmpty ? "没有可显示的 Skills" : "没有匹配的 Skills"
    }

    private var emptyMessage: String {
        if !viewModel.searchText.isEmpty {
            return "调整搜索词或状态筛选后重试。"
        }
        if viewModel.sessionID == nil {
            return "选择 DreamLog 会话后可解析 Project 技能；System、Personal 与 Plugin 技能仍由 Runtime 提供。"
        }
        return "Runtime 当前没有向此作用域暴露技能。"
    }

    private func groupDescription(_ group: RuntimeSkillSourceGroup) -> String {
        switch group {
        case .personal: return "用户级 Runtime skills"
        case .system: return "随 Runtime 分发的只读 system bundle"
        case .project: return "由当前会话持久化工作区解析"
        case .plugin: return "已启用插件的 namespaced skills"
        case .other: return "Runtime 返回的其他来源"
        }
    }
}
