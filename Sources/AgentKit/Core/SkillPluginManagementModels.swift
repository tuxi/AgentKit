//
//  SkillPluginManagementModels.swift
//  AgentKit
//
//  Stable client models for runtime-skill-inventory/v1,
//  runtime-plugin-inventory/v1 and runtime-plugin-mutation/v1.
//

import Foundation

// MARK: - Skills

public struct RuntimeManagementWarning: Codable, Hashable, Sendable, Identifiable {
    public let code: String
    public let message: String

    public var id: String { "\(code):\(message)" }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RuntimeSkillScopeContext: Codable, Hashable, Sendable {
    public let sessionID: String?
    public let workspaceID: String?
    public let displayName: String?
    public let resolved: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
        case displayName = "display_name"
        case resolved
    }

    public init(
        sessionID: String? = nil,
        workspaceID: String? = nil,
        displayName: String? = nil,
        resolved: Bool = false
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.displayName = displayName
        self.resolved = resolved
    }
}

public struct RuntimeSkillOrigin: Codable, Hashable, Sendable {
    public let name: String
    public let scope: String
    public let source: String
    public let path: String

    public init(name: String, scope: String, source: String, path: String) {
        self.name = name
        self.scope = scope
        self.source = source
        self.path = path
    }
}

public struct RuntimeSkillInterface: Codable, Hashable, Sendable {
    public let icon: String?

    public init(icon: String? = nil) {
        self.icon = icon
    }
}

public struct RuntimeSkillResources: Codable, Hashable, Sendable {
    public let count: Int
    public let names: [String]

    public init(count: Int = 0, names: [String] = []) {
        self.count = count
        self.names = names
    }
}

/// Source groups are intentionally open-ended on the client. A future Runtime
/// may add a group without making the entire inventory fail to decode.
public enum RuntimeSkillSourceGroup: Hashable, Sendable, Identifiable {
    case personal
    case system
    case project
    case plugin
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "user", "personal": self = .personal
        case "system": self = .system
        case "project": self = .project
        case "plugin": self = .plugin
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .personal: return "user"
        case .system: return "system"
        case .project: return "project"
        case .plugin: return "plugin"
        case .other(let value): return value
        }
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .personal: return "Personal"
        case .system: return "System"
        case .project: return "Project"
        case .plugin: return "Plugin"
        case .other(let value): return value
        }
    }

    public var localizedDisplayName: String {
        switch self {
        case .personal: return "个人"
        case .system: return "系统"
        case .project: return "项目"
        case .plugin: return "插件"
        case .other(let value): return value
        }
    }

    public static let installGroups: [RuntimeSkillSourceGroup] = [
        .personal, .system, .project, .plugin
    ]
}

public struct RuntimeSkillItem: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let displayName: String
    public let description: String
    public let scope: String
    public let source: String
    public let sourceGroupRaw: String
    public let path: String
    public let version: String
    public let sha256: String
    public let enabled: Bool
    public let status: String
    public let pluginName: String?
    public let interface: RuntimeSkillInterface?
    public let resources: RuntimeSkillResources
    public let warnings: [RuntimeManagementWarning]
    public let parseErrors: [String]
    public let shadowedBy: RuntimeSkillOrigin?
    public let shadows: [RuntimeSkillOrigin]

    enum CodingKeys: String, CodingKey {
        case name, description, scope, source, path, version, sha256
        case enabled, status, warnings, resources
        case displayName = "display_name"
        case sourceGroupRaw = "source_group"
        case pluginName = "plugin_name"
        case interface
        case parseErrors = "parse_errors"
        case shadowedBy = "shadowed_by"
        case shadows
    }

    public init(
        name: String,
        displayName: String,
        description: String,
        scope: String,
        source: String,
        sourceGroupRaw: String,
        path: String,
        version: String,
        sha256: String,
        enabled: Bool,
        status: String,
        pluginName: String? = nil,
        interface: RuntimeSkillInterface? = nil,
        resources: RuntimeSkillResources = .init(),
        warnings: [RuntimeManagementWarning] = [],
        parseErrors: [String] = [],
        shadowedBy: RuntimeSkillOrigin? = nil,
        shadows: [RuntimeSkillOrigin] = []
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.scope = scope
        self.source = source
        self.sourceGroupRaw = sourceGroupRaw
        self.path = path
        self.version = version
        self.sha256 = sha256
        self.enabled = enabled
        self.status = status
        self.pluginName = pluginName
        self.interface = interface
        self.resources = resources
        self.warnings = warnings
        self.parseErrors = parseErrors
        self.shadowedBy = shadowedBy
        self.shadows = shadows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        let decodedGroup = try c.decodeIfPresent(String.self, forKey: .sourceGroupRaw) ?? scope
        sourceGroupRaw = decodedGroup.isEmpty ? "system" : decodedGroup
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "invalid"
        pluginName = try c.decodeIfPresent(String.self, forKey: .pluginName)
        interface = try c.decodeIfPresent(RuntimeSkillInterface.self, forKey: .interface)
        resources = try c.decodeIfPresent(RuntimeSkillResources.self, forKey: .resources) ?? .init()
        warnings = try c.decodeIfPresent([RuntimeManagementWarning].self, forKey: .warnings) ?? []
        parseErrors = try c.decodeIfPresent([String].self, forKey: .parseErrors) ?? []
        shadowedBy = try c.decodeIfPresent(RuntimeSkillOrigin.self, forKey: .shadowedBy)
        shadows = try c.decodeIfPresent([RuntimeSkillOrigin].self, forKey: .shadows) ?? []
    }

    public var sourceGroup: RuntimeSkillSourceGroup {
        RuntimeSkillSourceGroup(rawValue: sourceGroupRaw)
    }

    public var id: String {
        "\(sourceGroupRaw):\(scope):\(name):\(path)"
    }

    public var isEffective: Bool { enabled && status == "active" }
    public var isShadowed: Bool { status == "shadowed" || shadowedBy != nil || !shadows.isEmpty }
    public var isInvalid: Bool { status == "invalid" || !parseErrors.isEmpty }
    public var displayTitle: String { displayName.isEmpty ? name : displayName }

    public var versionDisplay: String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未声明" : trimmed
    }
}

public struct RuntimeSkillInventory: Codable, Hashable, Sendable {
    public let schema: String
    public let scope: RuntimeSkillScopeContext
    public let items: [RuntimeSkillItem]
    public let warnings: [RuntimeManagementWarning]
    public let reloadRequired: Bool
    public let reloadHint: String?

    enum CodingKeys: String, CodingKey {
        case schema, scope, items, warnings
        case reloadRequired = "reload_required"
        case reloadHint = "reload_hint"
    }

    public init(
        schema: String = "runtime-skill-inventory/v1",
        scope: RuntimeSkillScopeContext = .init(),
        items: [RuntimeSkillItem] = [],
        warnings: [RuntimeManagementWarning] = [],
        reloadRequired: Bool = false,
        reloadHint: String? = nil
    ) {
        self.schema = schema
        self.scope = scope
        self.items = items
        self.warnings = warnings
        self.reloadRequired = reloadRequired
        self.reloadHint = reloadHint
    }
}

// MARK: - Plugins

public struct RuntimePluginInstalledSkill: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let valid: Bool
    public let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case name, path, valid
        case errorCode = "error_code"
    }

    public var id: String { "\(name):\(path)" }

    public init(name: String, path: String, valid: Bool, errorCode: String? = nil) {
        self.name = name
        self.path = path
        self.valid = valid
        self.errorCode = errorCode
    }
}

public struct RuntimePluginItem: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let version: String
    public let description: String
    public let displayName: String?
    public let category: String?
    public let capabilities: [String]
    public let icon: String?
    public let logo: String?
    public let brandColor: String?
    public let websiteURL: String?
    public let enabled: Bool
    public let source: String
    public let sourceKind: String
    public let cacheID: String
    public let cachePath: String
    public let manifestSHA256: String
    public let bundleSHA256: String
    public let installedSkills: [RuntimePluginInstalledSkill]
    public let mcpServers: [String]
    public let hasApps: Bool
    public let hasHooks: Bool
    public let integrityStatus: String
    public let errorCode: String?
    public let reloadRequired: Bool

    enum CodingKeys: String, CodingKey {
        case name, version, description, category, capabilities, icon, logo, enabled, source
        case displayName = "display_name"
        case brandColor = "brand_color"
        case websiteURL = "website_url"
        case sourceKind = "source_kind"
        case cacheID = "cache_id"
        case cachePath = "cache_path"
        case manifestSHA256 = "manifest_sha256"
        case bundleSHA256 = "bundle_sha256"
        case installedSkills = "installed_skills"
        case mcpServers = "mcp_servers"
        case hasApps = "has_apps"
        case hasHooks = "has_hooks"
        case integrityStatus = "integrity_status"
        case errorCode = "error_code"
        case reloadRequired = "reload_required"
    }

    public init(
        name: String,
        version: String,
        description: String,
        displayName: String? = nil,
        category: String? = nil,
        capabilities: [String] = [],
        icon: String? = nil,
        logo: String? = nil,
        brandColor: String? = nil,
        websiteURL: String? = nil,
        enabled: Bool,
        source: String,
        sourceKind: String,
        cacheID: String = "",
        cachePath: String = "",
        manifestSHA256: String = "",
        bundleSHA256: String = "",
        installedSkills: [RuntimePluginInstalledSkill] = [],
        mcpServers: [String] = [],
        hasApps: Bool = false,
        hasHooks: Bool = false,
        integrityStatus: String = "verified",
        errorCode: String? = nil,
        reloadRequired: Bool = false
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.displayName = displayName
        self.category = category
        self.capabilities = capabilities
        self.icon = icon
        self.logo = logo
        self.brandColor = brandColor
        self.websiteURL = websiteURL
        self.enabled = enabled
        self.source = source
        self.sourceKind = sourceKind
        self.cacheID = cacheID
        self.cachePath = cachePath
        self.manifestSHA256 = manifestSHA256
        self.bundleSHA256 = bundleSHA256
        self.installedSkills = installedSkills
        self.mcpServers = mcpServers
        self.hasApps = hasApps
        self.hasHooks = hasHooks
        self.integrityStatus = integrityStatus
        self.errorCode = errorCode
        self.reloadRequired = reloadRequired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        brandColor = try c.decodeIfPresent(String.self, forKey: .brandColor)
        websiteURL = try c.decodeIfPresent(String.self, forKey: .websiteURL)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind) ?? ""
        cacheID = try c.decodeIfPresent(String.self, forKey: .cacheID) ?? ""
        cachePath = try c.decodeIfPresent(String.self, forKey: .cachePath) ?? ""
        manifestSHA256 = try c.decodeIfPresent(String.self, forKey: .manifestSHA256) ?? ""
        bundleSHA256 = try c.decodeIfPresent(String.self, forKey: .bundleSHA256) ?? ""
        installedSkills = try c.decodeIfPresent([RuntimePluginInstalledSkill].self, forKey: .installedSkills) ?? []
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        hasApps = try c.decodeIfPresent(Bool.self, forKey: .hasApps) ?? false
        hasHooks = try c.decodeIfPresent(Bool.self, forKey: .hasHooks) ?? false
        integrityStatus = try c.decodeIfPresent(String.self, forKey: .integrityStatus) ?? "unknown"
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        reloadRequired = try c.decodeIfPresent(Bool.self, forKey: .reloadRequired) ?? false
    }

    public var displayTitle: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return displayName
    }

    public var id: String { name }
    public var integrityFailed: Bool { integrityStatus != "verified" }
    public var activeSkillNames: [String] { installedSkills.filter(\.valid).map(\.name) }
}

public struct RuntimePluginInventory: Codable, Hashable, Sendable {
    public let schema: String
    public let items: [RuntimePluginItem]
    public let reloadRequired: Bool
    public let reloadHint: String?

    enum CodingKeys: String, CodingKey {
        case schema, items
        case reloadRequired = "reload_required"
        case reloadHint = "reload_hint"
    }

    public init(
        schema: String = "runtime-plugin-inventory/v1",
        items: [RuntimePluginItem] = [],
        reloadRequired: Bool = false,
        reloadHint: String? = nil
    ) {
        self.schema = schema
        self.items = items
        self.reloadRequired = reloadRequired
        self.reloadHint = reloadHint
    }
}

public struct RuntimePluginMutation: Codable, Hashable, Sendable {
    public let schema: String
    public let action: String
    public let plugin: RuntimePluginItem?
    public let name: String?
    public let version: String?
    public let reloadRequired: Bool
    public let reloadHint: String?

    enum CodingKeys: String, CodingKey {
        case schema, action, plugin, name, version
        case reloadRequired = "reload_required"
        case reloadHint = "reload_hint"
    }
}

// MARK: - Client boundary

public protocol SkillPluginManaging: Sendable {
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot
    func skillInventory(sessionID: String?) async throws -> RuntimeSkillInventory
    func pluginInventory() async throws -> RuntimePluginInventory
    func installLocalPlugin(source: String, confirmed: Bool) async throws -> RuntimePluginMutation
    func setPluginEnabled(name: String, enabled: Bool) async throws -> RuntimePluginMutation
    func uninstallPlugin(name: String) async throws -> RuntimePluginMutation
}

// MARK: - Errors

public enum SkillPluginManagementError: Error, Equatable, Sendable {
    case authenticationRequired(String)
    case authenticationInvalid(String)
    case workspaceScopeUnresolved(String)
    case conversationNotFound(String)
    case pluginNotFound(String)
    case pluginIntegrityFailed(String)
    case pluginManifestInvalid(String)
    case pluginConfirmationRequired(String)
    case pluginSourceInvalid(String)
    case pluginSourceUnsupported(String)
    case pluginRegistryInvalid(String)
    case skillInventoryFailed(String)
    case pluginOperationFailed(String)
    case unsupportedCapability
    case invalidResponse
    case http(statusCode: Int, code: String?, message: String)

    public static func mapped(
        statusCode: Int,
        code: String?,
        message: String?
    ) -> SkillPluginManagementError {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (statusCode, code) {
        case (401, "runtime_auth_required"):
            return .authenticationRequired(text)
        case (401, _):
            return .authenticationInvalid(text)
        case (409, "workspace_scope_unresolved"):
            return .workspaceScopeUnresolved(text)
        case (409, "plugin_integrity_error"):
            return .pluginIntegrityFailed(text)
        case (422, "plugin_manifest_invalid"):
            return .pluginManifestInvalid(text)
        case (428, "plugin_confirmation_required"):
            return .pluginConfirmationRequired(text)
        case (404, "conversation_not_found"):
            return .conversationNotFound(text)
        case (404, "plugin_not_found"):
            return .pluginNotFound(text)
        case (400, "plugin_source_invalid"):
            return .pluginSourceInvalid(text)
        case (400, "plugin_source_unsupported"):
            return .pluginSourceUnsupported(text)
        case (500, "plugin_registry_invalid"):
            return .pluginRegistryInvalid(text)
        case (500, "skill_inventory_failed"):
            return .skillInventoryFailed(text)
        case (500, "plugin_operation_failed"):
            return .pluginOperationFailed(text)
        default:
            return .http(statusCode: statusCode, code: code, message: text)
        }
    }

    public var requiresAuthentication: Bool {
        switch self {
        case .authenticationRequired, .authenticationInvalid: return true
        default: return false
        }
    }

    public var requiresSessionSelection: Bool {
        switch self {
        case .workspaceScopeUnresolved, .conversationNotFound: return true
        default: return false
        }
    }
}

extension SkillPluginManagementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let detail):
            return detail.isEmpty ? "Runtime 要求身份认证。请打开“服务器”设置完成认证。" : detail
        case .authenticationInvalid(let detail):
            return detail.isEmpty ? "Runtime 身份认证失效。请重新连接或更新访问令牌。" : detail
        case .workspaceScopeUnresolved(let detail):
            return detail.isEmpty ? "当前会话尚未绑定有效工作区，项目技能不可用。" : detail
        case .conversationNotFound(let detail):
            return detail.isEmpty ? "找不到当前会话，无法解析项目技能。" : detail
        case .pluginNotFound(let detail):
            return detail.isEmpty ? "插件未安装或已被移除。" : detail
        case .pluginIntegrityFailed(let detail):
            return detail.isEmpty ? "插件完整性校验失败。该插件可识别，但启用/禁用会被 Runtime 拒绝。" : detail
        case .pluginManifestInvalid(let detail):
            return detail.isEmpty ? "插件 manifest 无效，未执行安装。" : detail
        case .pluginConfirmationRequired(let detail):
            return detail.isEmpty ? "安装本地插件需要显式确认。" : detail
        case .pluginSourceInvalid(let detail):
            return detail.isEmpty ? "本地插件路径无效或不可访问。" : detail
        case .pluginSourceUnsupported(let detail):
            return detail.isEmpty ? "仅支持本地目录或 .zip 插件。" : detail
        case .pluginRegistryInvalid(let detail):
            return detail.isEmpty ? "Runtime 无法读取已安装插件清单。" : detail
        case .skillInventoryFailed(let detail):
            return detail.isEmpty ? "Runtime 无法读取技能清单。" : detail
        case .pluginOperationFailed(let detail):
            return detail.isEmpty ? "插件操作失败。" : detail
        case .unsupportedCapability:
            return "当前 Runtime 不支持 Skill & Plugin Management v1。"
        case .invalidResponse:
            return "Runtime 返回了无效的 Skill/Plugin 数据。"
        case .http(let statusCode, let code, let message):
            if !message.isEmpty { return message }
            if let code, !code.isEmpty { return "请求失败（HTTP \(statusCode)，\(code)）。" }
            return "请求失败（HTTP \(statusCode)）。"
        }
    }
}
