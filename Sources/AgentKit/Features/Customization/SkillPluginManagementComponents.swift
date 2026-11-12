//
//  SkillPluginManagementComponents.swift
//  AgentKit
//

import SwiftUI

enum ManagementBadgeTone {
    case neutral
    case accent
    case success
    case warning
    case danger
    case muted

    var foreground: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        case .muted: return .secondary
        }
    }
}

struct ManagementBadge: View {
    let text: String
    var systemImage: String?
    var tone: ManagementBadgeTone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.foreground.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().stroke(tone.foreground.opacity(0.18), lineWidth: 1)
        }
    }
}

struct ManagementBanner<Actions: View>: View {
    enum Tone {
        case info
        case warning
        case error
        case success

        var color: Color {
            switch self {
            case .info: return .accentColor
            case .warning: return .orange
            case .error: return .red
            case .success: return .green
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let title: String
    var message: String?
    let tone: Tone
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let message, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
                    .padding(.top, 3)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tone.color.opacity(0.075), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(tone.color.opacity(0.18), lineWidth: 1)
        }
    }
}

extension ManagementBanner where Actions == EmptyView {
    init(title: String, message: String? = nil, tone: Tone) {
        self.init(title: title, message: message, tone: tone) { EmptyView() }
    }
}

struct ManagementSectionHeader: View {
    let title: String
    var subtitle: String?
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.10), in: Capsule())
            }
            Spacer()
        }
    }
}

struct ManagementEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(verbatim: title)
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(24)
    }
}

struct SkillStatusBadges: View {
    let skill: RuntimeSkillItem

    var body: some View {
        HStack(spacing: 5) {
            ManagementBadge(
                text: skill.isEffective ? "已启用" : "未启用",
                systemImage: skill.isEffective ? "checkmark.circle" : "pause.circle",
                tone: skill.isEffective ? .success : .muted
            )
            if skill.isShadowed {
                ManagementBadge(text: "Shadow", systemImage: "square.3.layers.3d", tone: .warning)
            }
            if skill.isInvalid || !skill.parseErrors.isEmpty {
                ManagementBadge(text: "Error", systemImage: "exclamationmark.triangle", tone: .danger)
            } else if !skill.warnings.isEmpty {
                ManagementBadge(text: "Warning", systemImage: "exclamationmark.circle", tone: .warning)
            }
        }
    }
}

struct SkillOriginBadges: View {
    let skill: RuntimeSkillItem

    var body: some View {
        HStack(spacing: 5) {
            ManagementBadge(
                text: skill.sourceGroup.displayName,
                systemImage: sourceIcon,
                tone: skill.sourceGroup == .system ? .neutral : .accent
            )
            ManagementBadge(text: skill.scope.isEmpty ? "unknown" : skill.scope, tone: .neutral)
            ManagementBadge(text: "v\(skill.versionDisplay)", tone: .muted)
            if let pluginName = skill.pluginName, !pluginName.isEmpty {
                ManagementBadge(text: pluginName, systemImage: "puzzlepiece.extension", tone: .accent)
            }
        }
    }

    private var sourceIcon: String {
        switch skill.sourceGroup {
        case .personal: return "person"
        case .system: return "gearshape.2"
        case .project: return "folder"
        case .plugin: return "puzzlepiece.extension"
        case .other: return "shippingbox"
        }
    }
}

struct SkillRow: View {
    let skill: RuntimeSkillItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: skill.interface?.icon ?? fallbackIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: skill.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(alignment: .center, spacing: 8) {
                            Text(verbatim: skill.name)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            SkillStatusBadges(skill: skill)
                        }
                    }

                    if !skill.description.isEmpty {
                        Text(verbatim: skill.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SkillOriginBadges(skill: skill)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 8)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("customization.skill.\(skill.name)")
    }

    private var fallbackIcon: String {
        switch skill.sourceGroup {
        case .personal: return "person.crop.circle"
        case .system: return "gearshape.2"
        case .project: return "folder.badge.gearshape"
        case .plugin: return "puzzlepiece.extension"
        case .other: return "shippingbox"
        }
    }
}

struct PluginIntegrityBadge: View {
    let plugin: RuntimePluginItem

    var body: some View {
        switch plugin.integrityStatus {
        case "verified":
            ManagementBadge(text: "Integrity verified", systemImage: "checkmark.shield", tone: .success)
        case "failed":
            ManagementBadge(text: "Integrity failed", systemImage: "xmark.shield", tone: .danger)
        default:
            ManagementBadge(text: plugin.integrityStatus, systemImage: "shield", tone: .warning)
        }
    }
}

struct SkillDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let skill: RuntimeSkillItem

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if skill.scope == "system" {
                        ManagementBanner(
                            title: "系统技能（只读）",
                            message: "系统技能随 Runtime 分发和更新。此面板不会直接编辑或改写 SKILL.md。",
                            tone: .info
                        )
                    }
                    metadata
                    diagnostics
                    resources
                    shadows
                    pathSection
                }
                .padding(22)
            }
            .navigationTitle(skill.displayTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: skill.interface?.icon ?? "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: skill.displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                    Text(verbatim: skill.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !skill.description.isEmpty {
                Text(verbatim: skill.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                SkillOriginBadges(skill: skill)
                SkillStatusBadges(skill: skill)
            }
        }
    }

    private var metadata: some View {
        ManagementDetailSection(title: "身份") {
            ManagementKeyValueRow(label: "Source", value: skill.source)
            ManagementKeyValueRow(label: "Scope", value: skill.scope)
            ManagementKeyValueRow(label: "Source group", value: skill.sourceGroupRaw)
            ManagementKeyValueRow(label: "Version", value: skill.versionDisplay)
            if let pluginName = skill.pluginName, !pluginName.isEmpty {
                ManagementKeyValueRow(label: "Plugin", value: pluginName)
            }
            ManagementKeyValueRow(label: "SHA-256", value: skill.sha256.isEmpty ? "未提供" : skill.sha256)
        }
    }

    @ViewBuilder
    private var diagnostics: some View {
        if !skill.warnings.isEmpty || !skill.parseErrors.isEmpty {
            ManagementDetailSection(title: "诊断") {
                ForEach(skill.warnings) { warning in
                    ManagementDiagnosticRow(
                        title: warning.code,
                        message: warning.message,
                        tone: .warning
                    )
                }
                ForEach(Array(skill.parseErrors.enumerated()), id: \.offset) { _, error in
                    ManagementDiagnosticRow(
                        title: "parse_error",
                        message: error,
                        tone: .danger
                    )
                }
            }
        }
    }

    private var resources: some View {
        ManagementDetailSection(title: "Resources") {
            ManagementKeyValueRow(label: "Count", value: "\(skill.resources.count)")
            if skill.resources.names.isEmpty {
                Text("未声明资源文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(skill.resources.names, id: \.self) { name in
                    Text(verbatim: name)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var shadows: some View {
        if skill.shadowedBy != nil || !skill.shadows.isEmpty {
            ManagementDetailSection(title: "覆盖关系") {
                if let shadowedBy = skill.shadowedBy {
                    ManagementDiagnosticRow(
                        title: "被 \(shadowedBy.scope) 覆盖",
                        message: shadowedBy.path,
                        tone: .warning
                    )
                }
                ForEach(skill.shadows, id: \.path) { origin in
                    ManagementDiagnosticRow(
                        title: "覆盖 \(origin.scope)",
                        message: origin.path,
                        tone: .info
                    )
                }
            }
        }
    }

    private var pathSection: some View {
        ManagementDetailSection(title: "Runtime 投影路径") {
            Text(verbatim: skill.path.isEmpty ? "未提供" : skill.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

struct ManagementDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct ManagementKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 102, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct ManagementDiagnosticRow: View {
    enum Tone { case info, warning, danger
        var color: Color {
            switch self {
            case .info: return .accentColor
            case .warning: return .orange
            case .danger: return .red
            }
        }
    }

    let title: String
    let message: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
