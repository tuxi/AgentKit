//
//  SkillPluginManagementViewModel.swift
//  AgentKit
//

import Foundation
import Observation

struct SkillPluginManagementOperations: Sendable {
    var capabilities: @Sendable () async throws -> RuntimeCapabilitySnapshot
    var skills: @Sendable (String?) async throws -> RuntimeSkillInventory
    var plugins: @Sendable () async throws -> RuntimePluginInventory
    var install: @Sendable (String, Bool) async throws -> RuntimePluginMutation
    var setEnabled: @Sendable (String, Bool) async throws -> RuntimePluginMutation
    var uninstall: @Sendable (String) async throws -> RuntimePluginMutation

    init(client: any SkillPluginManaging) {
        capabilities = { try await client.runtimeCapabilities() }
        skills = { try await client.skillInventory(sessionID: $0) }
        plugins = { try await client.pluginInventory() }
        install = { try await client.installLocalPlugin(source: $0, confirmed: $1) }
        setEnabled = { try await client.setPluginEnabled(name: $0, enabled: $1) }
        uninstall = { try await client.uninstallPlugin(name: $0) }
    }
}

public enum SkillPluginManagementSection: Hashable, Sendable, Identifiable {
    case customize
    case skills
    case plugins
    case installed(RuntimeSkillSourceGroup)

    public var id: String {
        switch self {
        case .customize: return "customize"
        case .skills: return "skills"
        case .plugins: return "plugins"
        case .installed(let group): return "installed:\(group.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .customize: return "Customize"
        case .skills: return "Skills"
        case .plugins: return "Plugins"
        case .installed(let group): return group.localizedDisplayName
        }
    }
}

public enum RuntimeSkillVisibilityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case attention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .active: return "已启用"
        case .attention: return "需注意"
        }
    }
}

@MainActor
@Observable
public final class SkillPluginManagementViewModel {
    public let sessionID: String?

    public private(set) var skillInventory = RuntimeSkillInventory()
    public private(set) var pluginInventory = RuntimePluginInventory()
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var isMutating = false
    public private(set) var isRestartingRuntime = false
    public private(set) var capabilityUnavailable = false
    public private(set) var requiresAuthentication = false
    public private(set) var skillError: String?
    public private(set) var pluginError: String?
    public private(set) var operationError: String?
    public private(set) var notice: String?
    public private(set) var reloadRequired = false
    public private(set) var reloadHint: String?
    public private(set) var restartError: String?

    public var searchText = ""
    public var visibilityFilter: RuntimeSkillVisibilityFilter = .all
    public var sourceFilter: RuntimeSkillSourceGroup?

    @ObservationIgnored private let operations: SkillPluginManagementOperations
    @ObservationIgnored private let onRestartRuntime: (@MainActor @Sendable () async -> Bool)?

    public convenience init(
        client: any SkillPluginManaging,
        sessionID: String?,
        onRestartRuntime: (@MainActor @Sendable () async -> Bool)? = nil
    ) {
        self.init(
            operations: SkillPluginManagementOperations(client: client),
            sessionID: sessionID,
            onRestartRuntime: onRestartRuntime
        )
    }

    init(
        operations: SkillPluginManagementOperations,
        sessionID: String?,
        onRestartRuntime: (@MainActor @Sendable () async -> Bool)? = nil
    ) {
        self.operations = operations
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = (trimmed?.isEmpty == false) ? trimmed : nil
        self.onRestartRuntime = onRestartRuntime
    }

    public var canRestartRuntime: Bool { onRestartRuntime != nil }

    public var scopeResolved: Bool {
        guard sessionID != nil else { return false }
        return skillInventory.scope.resolved
    }

    public var scopeTitle: String {
        guard let sessionID else { return "未选择会话 · Project 技能不可用" }
        if skillInventory.scope.resolved {
            let name = skillInventory.scope.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (name?.isEmpty == false) ? name! : String(sessionID.prefix(10)) + "…"
            return "会话 \(label)"
        }
        return "会话 \(String(sessionID.prefix(10)))… · 工作区未解析"
    }

    public var effectiveSkillCount: Int {
        skillInventory.items.filter { $0.isEffective && isBackedByActivePlugin($0) }.count
    }

    public var attentionSkillCount: Int {
        skillInventory.items.filter(isAttention).count
    }

    public var enabledPluginCount: Int {
        pluginInventory.items.filter(\.enabled).count
    }

    public var failedIntegrityPluginCount: Int {
        pluginInventory.items.filter(\.integrityFailed).count
    }

    public var warnings: [RuntimeManagementWarning] {
        var result = skillInventory.warnings
        for plugin in pluginInventory.items where plugin.integrityFailed {
            result.append(
                RuntimeManagementWarning(
                    code: plugin.errorCode ?? "plugin_integrity_error",
                    message: "\(plugin.displayTitle) 完整性校验失败"
                )
            )
        }
        return result
    }

    public var groups: [RuntimeSkillSourceGroup] {
        var seen = Set<String>()
        var result: [RuntimeSkillSourceGroup] = []
        for group in RuntimeSkillSourceGroup.installGroups + skillInventory.items.map(\.sourceGroup) {
            if seen.insert(group.rawValue).inserted {
                result.append(group)
            }
        }
        return result
    }

    public func skillCount(for group: RuntimeSkillSourceGroup) -> Int {
        skillInventory.items.filter {
            $0.sourceGroup == group && isBackedByActivePlugin($0)
        }.count
    }

    public func visibleSkills(for group: RuntimeSkillSourceGroup) -> [RuntimeSkillItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return skillInventory.items
            .filter { item in
                guard item.sourceGroup == group else { return false }
                guard sourceFilter == nil || sourceFilter == group else { return false }
                guard isBackedByActivePlugin(item) else { return false }
                if !query.isEmpty {
                    let haystack = [
                        item.name,
                        item.displayTitle,
                        item.description,
                        item.scope,
                        item.source,
                        item.pluginName ?? "",
                    ].joined(separator: "\n")
                    guard haystack.localizedCaseInsensitiveContains(query) else { return false }
                }
                switch visibilityFilter {
                case .all: return true
                case .active: return item.isEffective
                case .attention: return isAttention(item)
                }
            }
            .sorted { lhs, rhs in
                lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        capabilityUnavailable = false
        requiresAuthentication = false
        operationError = nil
        restartError = nil
        defer { isLoading = false }

        do {
            let capabilities = try await operations.capabilities()
            guard capabilities.supportsSkillPluginManagement else {
                capabilityUnavailable = true
                return
            }
        } catch {
            present(error, target: .operation)
            return
        }

        await refreshSkills(clearError: true)
        await refreshPlugins(clearError: true)
        updateReloadState()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshSkills(clearError: false)
        await refreshPlugins(clearError: false)
        updateReloadState()
    }

    public func installLocalPlugin(source: String) async {
        guard !isMutating else { return }
        isMutating = true
        operationError = nil
        notice = nil
        defer { isMutating = false }
        do {
            let mutation = try await operations.install(source, true)
            apply(mutation)
            notice = "已安装 \(mutation.plugin?.displayTitle ?? source) 插件。"
            await refresh()
        } catch {
            present(error, target: .operation)
        }
    }

    public func setPluginEnabled(_ plugin: RuntimePluginItem, enabled: Bool) async {
        guard !isMutating else { return }
        isMutating = true
        operationError = nil
        notice = nil
        defer { isMutating = false }
        do {
            let mutation = try await operations.setEnabled(plugin.name, enabled)
            apply(mutation)
            notice = enabled
                ? "已启用 \(plugin.displayTitle)。"
                : "已禁用 \(plugin.displayTitle)。"
            await refresh()
        } catch {
            present(error, target: .operation)
        }
    }

    public func uninstallPlugin(_ plugin: RuntimePluginItem) async {
        guard !isMutating else { return }
        isMutating = true
        operationError = nil
        notice = nil
        defer { isMutating = false }
        do {
            let mutation = try await operations.uninstall(plugin.name)
            apply(mutation)
            notice = "已卸载 \(plugin.displayTitle)。"
            await refresh()
        } catch {
            present(error, target: .operation)
        }
    }

    public func restartRuntime() async {
        guard let onRestartRuntime, !isRestartingRuntime else { return }
        isRestartingRuntime = true
        restartError = nil
        defer { isRestartingRuntime = false }
        let restarted = await onRestartRuntime()
        guard restarted else {
            restartError = "Runtime 重启失败。请检查 Runtime Server 状态后重试。"
            return
        }
        await load()
        if !reloadRequired {
            notice = "Runtime 已重启，Skill/Plugin 状态已刷新。"
        }
    }

    public func clearNotice() {
        notice = nil
        operationError = nil
        restartError = nil
    }

    private func refreshSkills(clearError: Bool) async {
        if clearError { skillError = nil }
        do {
            skillInventory = try await operations.skills(sessionID)
            if requiresAuthentication { requiresAuthentication = false }
        } catch {
            present(error, target: .skills)
        }
    }

    private func refreshPlugins(clearError: Bool) async {
        if clearError { pluginError = nil }
        do {
            pluginInventory = try await operations.plugins()
            if let error = pluginError, error.hasPrefix("插件列表加载失败") {
                pluginError = nil
            }
        } catch {
            present(error, target: .plugins)
        }
    }

    private func apply(_ mutation: RuntimePluginMutation) {
        guard let plugin = mutation.plugin else { return }
        if let index = pluginInventory.items.firstIndex(where: { $0.name == plugin.name }) {
            var items = pluginInventory.items
            items[index] = plugin
            pluginInventory = RuntimePluginInventory(
                schema: pluginInventory.schema,
                items: items,
                reloadRequired: pluginInventory.reloadRequired || mutation.reloadRequired,
                reloadHint: mutation.reloadHint ?? pluginInventory.reloadHint
            )
        }
        reloadRequired = reloadRequired || mutation.reloadRequired
        reloadHint = mutation.reloadHint ?? reloadHint
    }

    private func updateReloadState() {
        reloadRequired = skillInventory.reloadRequired || pluginInventory.reloadRequired
        reloadHint = pluginInventory.reloadHint
            ?? skillInventory.reloadHint
            ?? (reloadRequired ? "重启 Runtime 后应用插件变更。" : nil)
    }

    private func isAttention(_ item: RuntimeSkillItem) -> Bool {
        item.isInvalid || item.isShadowed || !item.warnings.isEmpty
    }

    /// The Runtime should already omit disabled/tampered plugin roots. This
    /// defensive projection keeps the UI from presenting a stale namespaced
    /// skill as active if the two inventory reads straddle a lifecycle change.
    private func isBackedByActivePlugin(_ item: RuntimeSkillItem) -> Bool {
        guard item.sourceGroup == .plugin else { return true }
        let pluginName = item.pluginName
            ?? item.name.split(separator: ":", maxSplits: 1).first.map(String.init)
        guard let pluginName,
              let plugin = pluginInventory.items.first(where: { $0.name == pluginName })
        else { return false }
        return plugin.enabled && plugin.integrityStatus == "verified"
    }

    private enum ErrorTarget { case skills, plugins, operation }

    private func present(_ error: Error, target: ErrorTarget) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let managementError = error as? SkillPluginManagementError {
            if managementError.requiresAuthentication {
                requiresAuthentication = true
            }
            if case .unsupportedCapability = managementError {
                capabilityUnavailable = true
            }
        }
        switch target {
        case .skills:
            skillError = "技能列表加载失败：\(message)"
        case .plugins:
            pluginError = "插件列表加载失败：\(message)"
        case .operation:
            operationError = message
        }
    }
}
