//
//  AgentRuntime.swift
//  AgentKit
//
//  Embedded CodeAgent Runtime shared by iOS and macOS hosts.
//

import Foundation
#if canImport(CodeAgentRuntime)
import CodeAgentRuntime
#endif
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import Darwin
#endif

#if canImport(CodeAgentRuntime)

public enum EmbeddedRuntimeProfile: String, Sendable {
    /// No subprocess tools. Used by iOS and OS-sandboxed hosts.
    case sandboxed
    /// Full desktop tool graph, including shell, Git, gopls, hooks and stdio MCP.
    case fullDesktop

    var isSandboxed: Bool { self == .sandboxed }
}

public struct EmbeddedRuntimeConfiguration: Sendable {
    public var workspaceDirectory: URL
    public var dataDirectory: URL
    public var profile: EmbeddedRuntimeProfile
    /// Optional host-generated Code-Agent configuration document. JSON is
    /// accepted because Code-Agent decodes it through YAML. Nil uses the
    /// AgentKit bundled Gateway-compatible configuration.
    public var runtimeConfigYAML: String?
    /// Extra executable lookup paths prepended before the Go runtime starts.
    /// This matters for macOS apps launched from Finder, which inherit a minimal PATH.
    public var executableSearchPaths: [String]

    public init(
        workspaceDirectory: URL,
        dataDirectory: URL,
        profile: EmbeddedRuntimeProfile,
        runtimeConfigYAML: String? = nil,
        executableSearchPaths: [String] = []
    ) {
        self.workspaceDirectory = workspaceDirectory
        self.dataDirectory = dataDirectory
        self.profile = profile
        self.runtimeConfigYAML = runtimeConfigYAML
        self.executableSearchPaths = executableSearchPaths
    }

    public static func platformDefault(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> EmbeddedRuntimeConfiguration {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        #if os(macOS)
        let appDirectory = support
            .appendingPathComponent(bundleIdentifier ?? "CodeAgent", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
        let home = fileManager.homeDirectoryForCurrentUser
        return EmbeddedRuntimeConfiguration(
            workspaceDirectory: home,
            dataDirectory: appDirectory,
            profile: .fullDesktop,
            runtimeConfigYAML: nil,
            executableSearchPaths: [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                home.appendingPathComponent(".local/bin").path,
                home.appendingPathComponent("go/bin").path,
            ]
        )
        #else
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return EmbeddedRuntimeConfiguration(
            workspaceDirectory: documents,
            dataDirectory: support,
            profile: .sandboxed,
            runtimeConfigYAML: nil
        )
        #endif
    }
}

#if os(iOS)
private final class RuntimeBackgroundTaskGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        let work = {
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                self.end()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func end() {
        lock.lock()
        let id = identifier
        identifier = .invalid
        lock.unlock()

        guard id != .invalid else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}
#endif

public final class AgentRuntime: @unchecked Sendable {
    private init() {}

    public static let shared = AgentRuntime()

    private var server: MobileServer?
    private var injectedSecretsJSON: String?
    private var startupModelNameOverride: String?
    private var configuration = EmbeddedRuntimeConfiguration.platformDefault()
    let runtimeAccessCredentialStore = EmbeddedRuntimeAccessCredentialStore()

    public var isAlive: Bool { server != nil }
    public var currentConfiguration: EmbeddedRuntimeConfiguration { configuration }

    /// Configure the embedded host before it starts. Changing filesystem/profile
    /// policy on a live runtime requires an explicit stop followed by configure.
    public func configure(_ configuration: EmbeddedRuntimeConfiguration) throws {
        guard server == nil else {
            throw NSError(
                domain: "AgentKit.EmbeddedRuntime",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Stop the embedded runtime before changing its configuration."]
            )
        }
        self.configuration = configuration
    }

    /// Installs a generated Provider configuration before Runtime startup.
    /// Structural Provider changes on a live Runtime still require stop/configure/start.
    public func configureProviderConnections(
        _ generated: GeneratedRuntimeProviderConfiguration
    ) throws {
        var updated = configuration
        updated.runtimeConfigYAML = generated.configYAML
        try configure(updated)
    }

    @discardableResult
    public func ensureStarted() throws -> Int {
        if let server {
            return server.port()
        }
        return try launch()
    }

    @discardableResult
    public func start() throws -> Int { try ensureStarted() }

    /// iOS checkpoints active work during its background grace period. macOS
    /// deliberately keeps full-desktop turns running while the app is inactive.
    public func suspendRuntime(timeoutMillis: Int = 2000) {
        #if os(iOS)
        guard let server else { return }
        DispatchQueue.global(qos: .background).async {
            let backgroundTask = RuntimeBackgroundTaskGuard()
            backgroundTask.begin(name: "AgentRuntime.Suspend")
            let watchdog = DispatchWorkItem { backgroundTask.end() }
            DispatchQueue.global(qos: .background).asyncAfter(
                deadline: .now() + .milliseconds(timeoutMillis),
                execute: watchdog
            )
            try? server.suspend()
            watchdog.cancel()
            backgroundTask.end()
        }
        #endif
    }

    public func resumeRuntime(sessionID: String) throws {
        guard let server else {
            throw NSError(
                domain: "AgentKit.EmbeddedRuntime",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Runtime is not started."]
            )
        }
        try server.resumeSession(sessionID)
    }

    public func reconfigure(secretsJSON: String = "", modelName: String = "") throws {
        guard let server else { return }
        try server.reconfigure(secretsJSON, modelName: modelName)
        if !secretsJSON.isEmpty {
            injectedSecretsJSON = secretsJSON
        }
    }

    @discardableResult
    public func restart() throws -> Int {
        stop()
        return try launch(secretsJSON: injectedSecretsJSON ?? "")
    }

    @discardableResult
    public func ensureStarted(with credentialStore: any CredentialStore) async throws -> Int {
        let map = (try? await credentialStore.all()) ?? CredentialMap()
        let secretsJSON = map.toSecretsJSON()
        let finalSecrets = secretsJSON == "{}" ? AgentSettings.secretsJSON() : secretsJSON
        startupModelNameOverride = ""

        if let server {
            try server.reconfigure(finalSecrets, modelName: "")
            injectedSecretsJSON = finalSecrets
            return server.port()
        }
        return try launch(secretsJSON: finalSecrets)
    }

    @discardableResult
    public func launch(with credentialStore: any CredentialStore) async throws -> Int {
        try await ensureStarted(with: credentialStore)
    }

    public func reconfigure(with credentialStore: any CredentialStore) async throws {
        guard let server else { return }
        let map = (try? await credentialStore.all()) ?? CredentialMap()
        let secretsJSON = map.toSecretsJSON()
        try server.reconfigure(secretsJSON, modelName: "")
        injectedSecretsJSON = secretsJSON
        startupModelNameOverride = ""
    }

    public func endpoint() -> String { server?.endpoint() ?? "" }
    public func port() -> Int { server?.port() ?? -1 }

    // MARK: - Shared Runtime listener

    func startSharedListener(
        configuration: RuntimeSharedListenerConfiguration
    ) throws {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        let data = try JSONEncoder.runtimeSharing.encode(configuration)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        try server.startSharedListener(json)
    }

    func stopSharedListener() throws {
        try server?.stopSharedListener()
    }

    func sharedListenerStatus() throws -> RuntimeSharedListenerStatus {
        guard let server else {
            return RuntimeSharedListenerStatus(
                state: .stopped,
                listenAddress: nil,
                listenOrigin: nil,
                port: 0,
                startedAt: nil,
                stoppedAt: nil,
                lastTransitionAt: nil,
                lastError: nil
            )
        }
        var error: NSError?
        let json = server.sharedListenerStatus(&error)
        if let error { throw error }
        guard let data = json.data(using: .utf8) else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        return try JSONDecoder.runtimeSharing.decode(
            RuntimeSharedListenerStatus.self,
            from: data
        )
    }

    func rotateSharedBootstrap(
        sha256: String,
        expiresAt: Date
    ) throws {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        try server.rotateSharedBootstrap(
            sha256,
            expiresAtUnix: Int64(expiresAt.timeIntervalSince1970)
        )
    }

    func pendingSharedEnrollments() throws
        -> [RuntimePendingSharedEnrollment] {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        var error: NSError?
        let json = server.pendingSharedEnrollments(&error)
        if let error { throw error }
        guard let data = json.data(using: .utf8) else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        return try JSONDecoder.runtimeSharing.decode(
            [RuntimePendingSharedEnrollment].self,
            from: data
        )
    }

    func acknowledgeSharedEnrollment(_ enrollmentID: String) throws {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        try server.acknowledgeSharedEnrollment(enrollmentID)
    }

    func rejectSharedEnrollment(_ enrollmentID: String) throws {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        try server.rejectSharedEnrollment(enrollmentID)
    }

    func updateSharedDevices(
        _ records: [RuntimeSharedDeviceValidationRecord]
    ) throws {
        guard let server else {
            throw RuntimeSharingError.runtimeNotStarted
        }
        let data = try JSONEncoder.runtimeSharing.encode(records)
        guard let json = String(data: data, encoding: .utf8) else {
            throw RuntimeSharingError.sharedListenerUnavailable
        }
        try server.updateSharedDevices(json)
    }

    public func stop() {
        try? server?.stop()
        server = nil
    }

    @discardableResult
    private func launch(secretsJSON: String = "") throws -> Int {
        stop()

        let fileManager = FileManager.default
        let config = configuration
        try fileManager.createDirectory(
            at: config.workspaceDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: config.dataDirectory,
            withIntermediateDirectories: true
        )
        Self.applyDataProtectionIfNeeded(to: config.dataDirectory)
        Self.bootstrapExecutablePath(config.executableSearchPaths)
        Self.installBundledSkills(in: config.dataDirectory)

        let finalSecrets = secretsJSON.isEmpty ? AgentSettings.secretsJSON() : secretsJSON
        injectedSecretsJSON = finalSecrets
        let model = startupModelNameOverride ?? AgentSettings.model
        let serverAccessToken = runtimeAccessCredentialStore.rotate()

        var error: NSError?
        guard let newServer = MobileStart(
            config.workspaceDirectory.path,
            config.dataDirectory.path,
            config.runtimeConfigYAML ?? Self.bundledConfigYAML(),
            model,
            finalSecrets,
            serverAccessToken,
            "",
            config.profile.isSandboxed,
            &error
        ) else {
            throw error ?? NSError(
                domain: "AgentKit.EmbeddedRuntime",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MobileStart failed."]
            )
        }
        server = newServer
        return newServer.port()
    }

    private static func bundledConfigYAML() -> String {
        #if DEBUG
        let gatewayBaseURL = "http://192.168.1.13:12221/api/v1/agent"
        #else
        let gatewayBaseURL = "https://api.objc.com/api/v1/agent"
        #endif
        guard let url = Bundle.module.url(forResource: "config", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.replacingOccurrences(of: "__GATEWAY_BASE_URL__", with: gatewayBaseURL)
    }

    private static func installBundledSkills(in dataDirectory: URL) {
        let fileManager = FileManager.default
        guard let source = Bundle.module.url(forResource: "skills", withExtension: nil),
              let bundledSkills = try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return
        }

        let destination = dataDirectory.appendingPathComponent("skills", isDirectory: true)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Replace only skills owned by the bundle. User-installed sibling skills survive upgrades.
        for bundledSkill in bundledSkills {
            let target = destination.appendingPathComponent(
                bundledSkill.lastPathComponent,
                isDirectory: true
            )
            try? fileManager.removeItem(at: target)
            try? fileManager.copyItem(at: bundledSkill, to: target)
        }
    }

    private static func applyDataProtectionIfNeeded(to directory: URL) {
        #if os(iOS)
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? fileManager.setAttributes(attributes, ofItemAtPath: directory.path)
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in items where url.lastPathComponent.contains(".sqlite")
            || url.lastPathComponent.contains(".db") {
            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        #endif
    }

    private static func bootstrapExecutablePath(_ additionalPaths: [String]) {
        #if os(macOS)
        guard !additionalPaths.isEmpty else { return }
        let fileManager = FileManager.default
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen = Set<String>()
        let paths = (additionalPaths + inherited).filter {
            fileManager.fileExists(atPath: $0) && seen.insert($0).inserted
        }
        setenv("PATH", paths.joined(separator: ":"), 1)
        #endif
    }
}

#endif
