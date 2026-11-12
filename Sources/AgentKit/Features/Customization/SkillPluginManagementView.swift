//
//  SkillPluginManagementView.swift
//  AgentKit
//
//  Host-neutral Skills & Plugins management surface. Inventory, status,
//  integrity and lifecycle semantics come exclusively from Runtime APIs.
//

import SwiftUI

public struct SkillPluginManagementView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var viewModel: SkillPluginManagementViewModel
    @State private var selection: SkillPluginManagementSection = .customize
    @State private var selectedSkill: RuntimeSkillItem?

    private let runtimeDisplayName: String
    private let canInstallLocalPlugin: Bool
    private let localInstallDisabledReason: String?
    private let restartPrompt: String?

    public init(
        client: any SkillPluginManaging,
        sessionID: String?,
        runtimeDisplayName: String,
        canInstallLocalPlugin: Bool,
        localInstallDisabledReason: String? = nil,
        restartPrompt: String? = nil,
        onRestartRuntime: (@MainActor @Sendable () async -> Bool)? = nil
    ) {
        _viewModel = State(initialValue: SkillPluginManagementViewModel(
            client: client,
            sessionID: sessionID,
            onRestartRuntime: onRestartRuntime
        ))
        self.runtimeDisplayName = runtimeDisplayName
        self.canInstallLocalPlugin = canInstallLocalPlugin
        self.localInstallDisabledReason = localInstallDisabledReason
        self.restartPrompt = restartPrompt
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .background(Color.primary.opacity(0.012))
        .task {
            await viewModel.load()
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailView(skill: skill)
        }
        .accessibilityIdentifier("customization.root")
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 228)
            Divider().opacity(0.6)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            compactHeader
            Divider().opacity(0.6)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("自定义")
                        .font(.system(size: 18, weight: .semibold))
                }
                Text("Customize")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 23)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                sidebarButton(.customize, title: "Customize", systemImage: "square.grid.2x2")
                sidebarButton(.skills, title: "Skills", systemImage: "sparkles", count: viewModel.skillInventory.items.count)
                sidebarButton(.plugins, title: "Plugins", systemImage: "puzzlepiece.extension", count: viewModel.pluginInventory.items.count)
            }
            .padding(.horizontal, 9)

            Text("已安装")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 17)
                .padding(.top, 20)
                .padding(.bottom, 5)

            VStack(spacing: 2) {
                ForEach(RuntimeSkillSourceGroup.installGroups) { group in
                    sidebarButton(
                        .installed(group),
                        title: group.localizedDisplayName,
                        systemImage: icon(for: group),
                        count: viewModel.skillCount(for: group)
                    )
                }
            }
            .padding(.horizontal, 9)

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.capabilityUnavailable ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(verbatim: runtimeDisplayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                Text(verbatim: viewModel.scopeTitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if viewModel.reloadRequired {
                    Label("Reload required", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
        .background(Color.primary.opacity(0.018))
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                if viewModel.reloadRequired {
                    ManagementBadge(text: "Reload required", systemImage: "arrow.clockwise", tone: .warning)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    compactButton(.customize, title: "Customize", icon: "square.grid.2x2")
                    compactButton(.skills, title: "Skills", icon: "sparkles")
                    compactButton(.plugins, title: "Plugins", icon: "puzzlepiece.extension")
                    ForEach(RuntimeSkillSourceGroup.installGroups) { group in
                        compactButton(.installed(group), title: group.localizedDisplayName, icon: icon(for: group))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .customize:
            customizeLanding
        case .skills:
            SkillPluginManagementSkillsView(viewModel: viewModel) { selectedSkill = $0 }
        case .plugins:
            pluginsView
        case .installed:
            SkillPluginManagementSkillsView(viewModel: viewModel) { selectedSkill = $0 }
        }
    }

    private var pluginsView: some View {
        SkillPluginManagementPluginsView(
            viewModel: viewModel,
            runtimeDisplayName: runtimeDisplayName,
            canInstallLocalPlugin: canInstallLocalPlugin,
            localInstallDisabledReason: localInstallDisabledReason,
            restartPrompt: restartPrompt
        )
    }

    private var customizeLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Customize")
                        .font(.system(size: 24, weight: .semibold))
                    Text("扩展 AgentKit 的技能与插件。所有 inventory、manifest 校验和生命周期状态均由 Runtime 提供。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在连接 Runtime inventory…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.capabilityUnavailable {
                    ManagementBanner(
                        title: "此 Runtime 不支持 v1 管理能力",
                        message: "需要 skill_plugin_management_v1。页面不会回退读取本地 SKILL.md 或 plugin manifest。",
                        tone: .warning
                    )
                }
                if viewModel.requiresAuthentication {
                    ManagementBanner(
                        title: "Runtime 认证失败",
                        message: "401 会在页面内显示，不会伪装为空 inventory。请检查服务器访问令牌。",
                        tone: .error
                    )
                }
                if viewModel.reloadRequired {
                    ManagementBanner(
                        title: "有插件变更等待 Runtime 重启",
                        message: viewModel.reloadHint ?? restartPrompt ?? "重启 Runtime 后刷新 Skills 与 MCP 注册表。",
                        tone: .warning
                    )
                }

                HStack(spacing: 12) {
                    customizeCard(
                        title: "Skills",
                        subtitle: "\(viewModel.effectiveSkillCount) active · \(viewModel.attentionSkillCount) need attention",
                        icon: "sparkles",
                        action: { select(.skills) }
                    )
                    customizeCard(
                        title: "Plugins",
                        subtitle: "\(viewModel.enabledPluginCount) enabled · \(viewModel.failedIntegrityPluginCount) integrity failed",
                        icon: "puzzlepiece.extension",
                        action: { select(.plugins) }
                    )
                }

                ManagementSectionHeader(
                    title: "已安装",
                    subtitle: "Runtime 按 source_group 投影的 Skill 作用域",
                    count: viewModel.skillInventory.items.count
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(RuntimeSkillSourceGroup.installGroups) { group in
                        Button {
                            select(.installed(group))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: group))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.localizedDisplayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(groupDescription(group))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(viewModel.skillCount(for: group))")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = viewModel.skillError ?? viewModel.pluginError {
                    ManagementBanner(
                        title: "Runtime 数据不完整",
                        message: error,
                        tone: .warning
                    ) {
                        Button("重新加载") { Task { await viewModel.refresh() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(22)
        }
        .accessibilityIdentifier("customization.landing")
    }

    private func customizeCard(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func sidebarButton(
        _ section: SkillPluginManagementSection,
        title: String,
        systemImage: String,
        count: Int? = nil
    ) -> some View {
        let selected = selection == section
        return Button {
            select(section)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("customization.nav.\(section.id)")
    }

    private func compactButton(
        _ section: SkillPluginManagementSection,
        title: String,
        icon: String
    ) -> some View {
        let selected = selection == section
        return Button {
            select(section)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 29)
                .background(
                    selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func select(_ section: SkillPluginManagementSection) {
        selection = section
        switch section {
        case .installed(let group):
            viewModel.sourceFilter = group
        case .skills, .customize, .plugins:
            viewModel.sourceFilter = nil
        }
    }

    private func icon(for group: RuntimeSkillSourceGroup) -> String {
        switch group {
        case .personal: return "person"
        case .system: return "gearshape.2"
        case .project: return "folder"
        case .plugin: return "puzzlepiece.extension"
        case .other: return "shippingbox"
        }
    }

    private func groupDescription(_ group: RuntimeSkillSourceGroup) -> String {
        switch group {
        case .personal: return "Personal"
        case .system: return "System"
        case .project: return "Project"
        case .plugin: return "Plugin"
        case .other: return "Other"
        }
    }
}

#if DEBUG
#Preview("Skill & Plugin Management") {
    SkillPluginManagementView(
        client: PreviewSkillPluginClient(),
        sessionID: "dreamlog-preview",
        runtimeDisplayName: "Talkify Embedded Runtime",
        canInstallLocalPlugin: true,
        onRestartRuntime: { true }
    )
    .frame(width: 980, height: 680)
}

private struct PreviewSkillPluginClient: SkillPluginManaging {
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot {
        .init(capabilities: ["skill_plugin_management_v1": true])
    }

    func skillInventory(sessionID: String?) async throws -> RuntimeSkillInventory {
        RuntimeSkillInventory(
            scope: .init(sessionID: sessionID, displayName: "DreamLog", resolved: true),
            items: [
                .init(
                    name: "ui-adaptation",
                    displayName: "UI Adaptation",
                    description: "Adapt product UI to native platform conventions.",
                    scope: "project",
                    source: "agents",
                    sourceGroupRaw: "project",
                    path: ".agents/skills/ui-adaptation/SKILL.md",
                    version: "1",
                    sha256: String(repeating: "a", count: 64),
                    enabled: true,
                    status: "active"
                ),
                .init(
                    name: "verify-change",
                    displayName: "Verify Change",
                    description: "Verify a change before delivery.",
                    scope: "system",
                    source: "system",
                    sourceGroupRaw: "system",
                    path: "skills/.system/verify-change/SKILL.md",
                    version: "1",
                    sha256: String(repeating: "b", count: 64),
                    enabled: true,
                    status: "active"
                ),
            ]
        )
    }

    func pluginInventory() async throws -> RuntimePluginInventory {
        RuntimePluginInventory(items: [
            .init(
                name: "docs",
                version: "1.0.0",
                description: "Documentation workflow plugin.",
                displayName: "Docs Center",
                enabled: true,
                source: "local",
                sourceKind: "local_directory",
                installedSkills: [.init(name: "docs:search", path: "skills/search/SKILL.md", valid: true)],
                mcpServers: ["docs__lookup"],
                hasApps: false,
                hasHooks: true
            )
        ])
    }

    func installLocalPlugin(source: String, confirmed: Bool) async throws -> RuntimePluginMutation { fatalError() }
    func setPluginEnabled(name: String, enabled: Bool) async throws -> RuntimePluginMutation { fatalError() }
    func uninstallPlugin(name: String) async throws -> RuntimePluginMutation { fatalError() }
}
#endif
