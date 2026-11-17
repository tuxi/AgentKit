import SwiftUI

private struct ComposerEnvironmentNameKey: EnvironmentKey { static let defaultValue = "执行环境" }
private struct ComposerEnvironmentSymbolKey: EnvironmentKey { static let defaultValue = "desktopcomputer" }
public extension EnvironmentValues {
    var composerEnvironmentName: String {
        get { self[ComposerEnvironmentNameKey.self] }
        set { self[ComposerEnvironmentNameKey.self] = newValue }
    }
    var composerEnvironmentSymbol: String {
        get { self[ComposerEnvironmentSymbolKey.self] }
        set { self[ComposerEnvironmentSymbolKey.self] = newValue }
    }
}

/// Secret-free presentation supplied by the host's existing connection monitor.
public struct ComposerDiagnostic: Sendable, Equatable, Identifiable {
    public enum Destination: Sendable { case environment, models }
    public let id: String
    public let title: String
    public let message: String
    public let details: String
    public let destination: Destination
    public let blocksSubmission: Bool

    public init(id: String, title: String, message: String, details: String,
                destination: Destination, blocksSubmission: Bool = true) {
        self.id = id
        self.title = title
        self.message = message
        self.details = details
        self.destination = destination
        self.blocksSubmission = blocksSubmission
    }

    public static func runtime(_ snapshot: RuntimeServerDiagnosticSnapshot, name: String) -> Self? {
        let title: String
        let message: String
        switch snapshot.status {
        case .connected, .starting, .checking, .reconnecting: return nil
        case .offline:
            title = "无法连接执行环境"
            message = "请检查 \(name) 的连接，或打开环境设置。"
        case .authenticationRequired, .authenticationFailed:
            title = "执行环境认证失败"
            message = "请在环境设置中检查访问凭据。"
        case .protocolIncompatible:
            title = "执行环境协议不兼容"
            message = "请更新执行环境后重新检查。"
        case .tlsRequired, .configurationError:
            title = "执行环境配置有误"
            message = "请打开环境设置检查连接配置。"
        }
        var endpoint = snapshot.endpoint.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        endpoint?.user = nil; endpoint?.password = nil; endpoint?.query = nil; endpoint?.fragment = nil
        // Allowlisted fields: never copy raw HTTP bodies or authentication data.
        let details = "环境：\(name)\n状态：\(snapshot.status.rawValue)\n地址：\(endpoint?.string ?? "—")\n最近检查：\(snapshot.lastCheckedAt?.ISO8601Format() ?? "—")"
        return Self(id: "\(snapshot.connectionID):\(snapshot.status.rawValue)", title: title,
                    message: message, details: details, destination: .environment)
    }
}

private struct ComposerDiagnosticKey: EnvironmentKey { static let defaultValue: ComposerDiagnostic? = nil }
private struct ComposerRecheckEnvironmentKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () async -> Void)? = nil
}
private struct ComposerOpenModelSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}
public extension EnvironmentValues {
    var composerDiagnostic: ComposerDiagnostic? {
        get { self[ComposerDiagnosticKey.self] }
        set { self[ComposerDiagnosticKey.self] = newValue }
    }
    var composerRecheckEnvironment: (@MainActor @Sendable () async -> Void)? {
        get { self[ComposerRecheckEnvironmentKey.self] }
        set { self[ComposerRecheckEnvironmentKey.self] = newValue }
    }
    var composerOpenModelSettings: (@MainActor @Sendable () -> Void)? {
        get { self[ComposerOpenModelSettingsKey.self] }
        set { self[ComposerOpenModelSettingsKey.self] = newValue }
    }
}

#if os(macOS)
/// Both entry points use the same live identity and the existing environment
/// settings flow, which owns switching/active-work guards and server isolation.
struct ComposerEnvironmentMenu: View {
    enum Style { case icon, chip, draftCard }
    var style: Style
    @Environment(\.composerEnvironmentName) private var name
    @Environment(\.composerEnvironmentSymbol) private var symbol
    @Environment(\.sessionRailOpenSettings) private var openSettings
    @State private var presented = false
    @State private var hovering = false

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 6) {
                if style != .draftCard { Image(systemName: symbol) }
                if style != .icon { Text(style == .draftCard ? "选择环境" : name).lineLimit(1) }
                if style == .draftCard {
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: style == .draftCard ? 14 : 12))
            .frame(maxWidth: style == .draftCard ? .infinity : nil,
                   minHeight: style == .draftCard ? 32 : 28, alignment: .leading)
            .padding(.horizontal, style == .draftCard ? 8 : 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .help(name)
        .accessibilityLabel("选择执行环境，当前为\(name)")
        .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("当前环境").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
                Divider()
                Button {
                    presented = false
                    openSettings?(.environment)
                } label: {
                    Label("选择或添加环境…", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openSettings == nil)
            }
            .font(.system(size: 13))
            .padding(14)
            .frame(width: 280)
        }
    }
}
#endif
