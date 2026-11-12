//
//  SkillPluginManagementPluginsView.swift
//  AgentKit
//

import SwiftUI
import UniformTypeIdentifiers

struct SkillPluginManagementPluginsView: View {
    @Bindable var viewModel: SkillPluginManagementViewModel
    let runtimeDisplayName: String
    let canInstallLocalPlugin: Bool
    let localInstallDisabledReason: String?
    let restartPrompt: String?

    @State private var showsImporter = false
    @State private var pendingInstallURL: URL?
    @State private var pendingRemoval: RuntimePluginItem?
    @State private var importerError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    stateBanners
                    localInstallExplanation
                    pluginList
                }
                .padding(22)
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.directory, pluginArchiveType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                pendingInstallURL = urls.first
            case .failure(let error):
                importerError = "无法选择本地插件：\(error.localizedDescription)"
            }
        }
        .alert("安装本地插件？", isPresented: installConfirmationBinding) {
            Button("取消", role: .cancel) {
                pendingInstallURL = nil
            }
            Button("安装") {
                guard let url = pendingInstallURL else { return }
                pendingInstallURL = nil
                Task { await install(url) }
            }
        } message: {
            Text(verbatim: installConfirmationMessage)
        }
        .confirmationDialog(
            "卸载插件？",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("卸载 \(pendingRemoval?.displayTitle ?? "")", role: .destructive) {
                guard let plugin = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await viewModel.uninstallPlugin(plugin) }
            }
            Button("取消", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("Runtime 会删除该插件的版本化 cache。重启 Runtime 后，其 namespaced skills 与 MCP servers 才会从活动注册表移除。")
        }
        .accessibilityIdentifier("customization.plugins")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugins")
                    .font(.system(size: 22, weight: .semibold))
                Text("\(runtimeDisplayName) · \(viewModel.pluginInventory.items.count) installed · \(viewModel.enabledPluginCount) enabled")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing || viewModel.capabilityUnavailable)

            Button {
                showsImporter = true
            } label: {
                Label("安装本地插件", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canInstallLocalPlugin || viewModel.isMutating || viewModel.capabilityUnavailable)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var stateBanners: some View {
        if viewModel.capabilityUnavailable {
            ManagementBanner(
                title: "当前 Runtime 不支持插件管理",
                message: "Runtime 未声明 skill_plugin_management_v1。请升级并重新连接 Runtime。",
                tone: .warning
            )
        }
        if viewModel.requiresAuthentication {
            ManagementBanner(
                title: "需要 Runtime 认证",
                message: "401 不会被解释为空插件列表。请在“服务器”设置中检查访问令牌。",
                tone: .error
            )
        }
        if viewModel.reloadRequired {
            ManagementBanner(
                title: "重启 Runtime 后应用变更",
                message: viewModel.reloadHint ?? restartPrompt ?? "插件状态已持久化，但活动 Skill/MCP 注册表仍是启动快照。",
                tone: .warning
            ) {
                if viewModel.canRestartRuntime {
                    Button {
                        Task { await viewModel.restartRuntime() }
                    } label: {
                        if viewModel.isRestartingRuntime {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在重启…")
                            }
                        } else {
                            Label("重启 Runtime", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRestartingRuntime)
                } else if let restartPrompt, !restartPrompt.isEmpty {
                    Text(verbatim: restartPrompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let pluginError = viewModel.pluginError {
            ManagementBanner(
                title: "插件列表不可用",
                message: pluginError,
                tone: .error
            ) {
                Button("重试") { Task { await viewModel.refresh() } }
                    .buttonStyle(.borderless)
            }
        }
        if let operationError = viewModel.operationError {
            ManagementBanner(title: "操作失败", message: operationError, tone: .error)
        }
        if let restartError = viewModel.restartError {
            ManagementBanner(title: "Runtime 重启失败", message: restartError, tone: .error)
        }
        if let notice = viewModel.notice {
            ManagementBanner(title: notice, tone: .success)
        }
        if let importerError {
            ManagementBanner(title: "文件选择失败", message: importerError, tone: .error)
        }
        if viewModel.failedIntegrityPluginCount > 0 {
            ManagementBanner(
                title: "\(viewModel.failedIntegrityPluginCount) 个插件完整性校验失败",
                message: "失败插件仍会显示，不会让整个插件页面失败。禁用/启用会被 Runtime 的 409 完整性保护拒绝；可直接尝试卸载。",
                tone: .warning
            )
        }
    }

    @ViewBuilder
    private var localInstallExplanation: some View {
        if !canInstallLocalPlugin {
            ManagementBanner(
                title: "本地安装已禁用",
                message: localInstallDisabledReason ?? "当前 Runtime 不可访问本机绝对路径。远程 marketplace 不在第一版范围内。",
                tone: .info
            )
        }
    }

    @ViewBuilder
    private var pluginList: some View {
        if viewModel.isLoading && viewModel.pluginInventory.items.isEmpty {
            ProgressView("正在读取 Runtime Plugin Inventory…")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if viewModel.pluginInventory.items.isEmpty && viewModel.pluginError == nil {
            ManagementEmptyState(
                icon: "puzzlepiece.extension",
                title: "尚未安装 Plugins",
                message: canInstallLocalPlugin
                    ? "选择本地目录或 .zip 后，Runtime 会验证并安装到版本化 cache。"
                    : "远程 Runtime 暂不支持从此设备安装本地插件。"
            )
        } else {
            ForEach(viewModel.pluginInventory.items) { plugin in
                PluginCard(
                    plugin: plugin,
                    isMutating: viewModel.isMutating,
                    onToggle: {
                        Task { await viewModel.setPluginEnabled(plugin, enabled: !plugin.enabled) }
                    },
                    onUninstall: {
                        pendingRemoval = plugin
                    }
                )
            }
        }
    }

    private var installConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingInstallURL != nil },
            set: { if !$0 { pendingInstallURL = nil } }
        )
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var installConfirmationMessage: String {
        guard let url = pendingInstallURL else { return "" }
        return "Runtime 将读取并校验：\n\(url.path)\n\n不会在 Talkify 中解析 manifest 或 SKILL.md；仅支持本地目录和 .zip。"
    }

    private var pluginArchiveType: UTType {
        UTType(filenameExtension: "zip") ?? .data
    }

    private func install(_ url: URL) async {
        importerError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        await viewModel.installLocalPlugin(source: url.path)
    }
}

private struct PluginCard: View {
    let plugin: RuntimePluginItem
    let isMutating: Bool
    let onToggle: () -> Void
    let onUninstall: () -> Void

    @State private var showsContents = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !plugin.description.isEmpty {
                Text(verbatim: plugin.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            metadata
            contents
            if plugin.integrityFailed {
                ManagementBanner(
                    title: "Integrity failed",
                    message: "\(plugin.errorCode ?? "plugin_integrity_error") · 该插件已从活动 Skill/MCP 注册表隔离，但仍保留在已安装列表中。",
                    tone: .error
                )
            }
            footer
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    plugin.integrityFailed ? Color.red.opacity(0.30) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
        .accessibilityIdentifier("customization.plugin.\(plugin.name)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(plugin.displayTitle.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: plugin.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: "\(plugin.name)@\(plugin.version)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    ManagementBadge(
                        text: plugin.enabled ? "Enabled" : "Disabled",
                        systemImage: plugin.enabled ? "checkmark.circle" : "pause.circle",
                        tone: plugin.enabled ? .success : .muted
                    )
                    PluginIntegrityBadge(plugin: plugin)
                    if plugin.reloadRequired {
                        ManagementBadge(text: "Reload required", systemImage: "arrow.clockwise", tone: .warning)
                    }
                    if let category = plugin.category, !category.isEmpty {
                        ManagementBadge(text: category, tone: .neutral)
                    }
                }
            }
            Spacer(minLength: 8)
            if let websiteURL = plugin.websiteURL, let url = URL(string: websiteURL) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("打开插件网站")
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            ManagementBadge(text: "source: \(plugin.source)", systemImage: "shippingbox", tone: .neutral)
            ManagementBadge(text: plugin.sourceKind, systemImage: "tray.and.arrow.down", tone: .neutral)
            if let cacheID = optional(plugin.cacheID) {
                ManagementBadge(text: cacheID, tone: .muted)
            }
            if !plugin.capabilities.isEmpty {
                ManagementBadge(text: "\(plugin.capabilities.count) capabilities", systemImage: "slider.horizontal.3", tone: .accent)
            }
            Spacer()
        }
    }

    private var contents: some View {
        DisclosureGroup(isExpanded: $showsContents) {
            VStack(alignment: .leading, spacing: 10) {
                contentLine(
                    title: "Skills",
                    values: plugin.installedSkills.map { skill in
                        "\(skill.name)\(skill.valid ? "" : " · invalid")"
                    },
                    icon: "sparkles",
                    tone: plugin.installedSkills.allSatisfy(\.valid) ? .accent : .danger
                )
                contentLine(
                    title: "MCP",
                    values: plugin.mcpServers,
                    icon: "server.rack",
                    tone: .accent
                )
                contentLine(
                    title: "Apps",
                    values: plugin.hasApps ? ["包含 app metadata（第一版不执行）"] : [],
                    icon: "app.dashed",
                    tone: .warning
                )
                contentLine(
                    title: "Hooks",
                    values: plugin.hasHooks ? ["包含 hook metadata（第一版不执行）"] : [],
                    icon: "bolt.horizontal",
                    tone: .warning
                )
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Text("包含内容")
                    .font(.system(size: 11.5, weight: .semibold))
                ManagementBadge(text: "\(plugin.installedSkills.count) skills", tone: .accent)
                ManagementBadge(text: "\(plugin.mcpServers.count) MCP", tone: .neutral)
                if plugin.hasApps { ManagementBadge(text: "Apps", tone: .warning) }
                if plugin.hasHooks { ManagementBadge(text: "Hooks", tone: .warning) }
            }
        }
    }

    private func contentLine(
        title: String,
        values: [String],
        icon: String,
        tone: ManagementBadgeTone
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .frame(width: 16)
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 48, alignment: .leading)
            if values.isEmpty {
                Text("无")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                FlowText(values: values)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Label(plugin.enabled ? "禁用" : "启用", systemImage: plugin.enabled ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(isMutating || plugin.integrityFailed)
            .help(plugin.integrityFailed ? "Integrity failed 插件会被 Runtime 以 409 拒绝启停。" : "")

            Button(role: .destructive, action: onUninstall) {
                Label("卸载", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isMutating)

            Spacer()
            Text(verbatim: plugin.cachePath.isEmpty ? plugin.name : plugin.cachePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct FlowText: View {
    let values: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(values.prefix(4), id: \.self) { value in
                Text(verbatim: value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            if values.count > 4 {
                Text("+\(values.count - 4)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
