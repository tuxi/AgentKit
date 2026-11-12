import CryptoKit
import Foundation

struct SystemSkillFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
}

struct SystemSkillEntry: Codable, Equatable, Sendable {
    let name: String
    let source: String
    let destination: String
    let sha256: String
    let scope: String
    let version: String?
    let files: [SystemSkillFile]
}

struct SystemSkillManifest: Codable, Equatable, Sendable {
    let schema: String
    let bundleVersion: String
    let skills: [SystemSkillEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case bundleVersion = "bundle_version"
        case skills
    }
}

struct SystemSkillMarker: Codable, Equatable {
    let schema: String
    let bundleVersion: String
    let fingerprint: String
    let source: String
    let files: [SystemSkillFile]

    enum CodingKeys: String, CodingKey {
        case schema
        case bundleVersion = "bundle_version"
        case fingerprint
        case source
        case files
    }
}

enum BundledSkillsInstallerError: Error, LocalizedError {
    case missingManifest(URL)
    case invalidManifest(String)
    case unsafePath(String)
    case hashMismatch(String)
    case symlinkRejected(URL)
    case nonRegularFile(URL)
    case missingFile(String)
    case undeclaredFile(String)
    case invalidDestination(URL)

    var errorDescription: String? {
        switch self {
        case .missingManifest(let url):
            return "System skill manifest is missing at \(url.path)"
        case .invalidManifest(let reason):
            return "Invalid system skill manifest: \(reason)"
        case .unsafePath(let path):
            return "Unsafe system skill path: \(path)"
        case .hashMismatch(let path):
            return "System skill hash mismatch: \(path)"
        case .symlinkRejected(let url):
            return "System skill bundle contains a symlink: \(url.path)"
        case .nonRegularFile(let url):
            return "System skill bundle contains a non-regular file: \(url.path)"
        case .missingFile(let path):
            return "System skill bundle is missing \(path)"
        case .undeclaredFile(let path):
            return "System skill bundle contains undeclared file \(path)"
        case .invalidDestination(let url):
            return "System skill destination is unsafe: \(url.path)"
        }
    }
}

enum BundledSkillsInstaller {
    static let schema = "codeagent.system-skills.v1"
    static let manifestFilename = "system-skills.json"
    static let markerFilename = ".codeagent-system-skills.json"
    static let markerSalt = "codeagent-system-skills-v1"

    static func install(
        bundleRoot: URL,
        dataDirectory: URL,
        source: String,
        fileManager: FileManager = .default
    ) throws {
        let manifestURL = bundleRoot.appendingPathComponent(manifestFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BundledSkillsInstallerError.missingManifest(manifestURL)
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SystemSkillManifest.self, from: manifestData)
        try validate(manifest)
        try verifyBundle(bundleRoot, manifest: manifest, allowMarker: false, fileManager: fileManager)

        let skillsRoot = dataDirectory.appendingPathComponent("skills", isDirectory: true)
        let destination = skillsRoot.appendingPathComponent(".system", isDirectory: true)
        try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try recoverInterruptedInstall(skillsRoot: skillsRoot, destination: destination, fileManager: fileManager)
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw BundledSkillsInstallerError.invalidDestination(destination)
        }

        let marker = SystemSkillMarker(
            schema: manifest.schema,
            bundleVersion: manifest.bundleVersion,
            fingerprint: sha256(manifestData),
            source: source,
            files: installedFiles(manifest, manifestData: manifestData)
        )
        if markerMatches(
            destination.appendingPathComponent(markerFilename),
            expected: marker,
            destination: destination,
            manifest: manifest,
            fileManager: fileManager
        ) {
            return
        }

        let stage = skillsRoot.appendingPathComponent(
            ".system.stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try copyTree(bundleRoot, to: stage, fileManager: fileManager)
        let markerData = try JSONEncoder.pretty.encode(marker)
        try markerData.write(to: stage.appendingPathComponent(markerFilename), options: .atomic)
        try verifyBundle(stage, manifest: manifest, allowMarker: true, fileManager: fileManager)

        let backup = skillsRoot.appendingPathComponent(".system.backup", isDirectory: true)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: stage, to: destination)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
        } catch {
            if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    static func verifyBundle(
        _ root: URL,
        manifest: SystemSkillManifest,
        allowMarker: Bool,
        fileManager: FileManager = .default
    ) throws {
        var expected = Set<String>()
        for skill in manifest.skills {
            for file in skill.files {
                let relative = "\(skill.destination)/\(file.path)"
                expected.insert(relative)
                let url = root.appendingPathComponent(relative)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw BundledSkillsInstallerError.missingFile(relative)
                }
                guard try sha256(fileAt: url, fileManager: fileManager) == file.sha256 else {
                    throw BundledSkillsInstallerError.hashMismatch(relative)
                }
            }
            guard aggregateHash(skill.files) == skill.sha256 else {
                throw BundledSkillsInstallerError.hashMismatch("\(skill.name) aggregate")
            }
        }

        let manifestRelative = manifestFilename
        expected.insert(manifestRelative)
        if allowMarker {
            expected.insert(markerFilename)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw BundledSkillsInstallerError.missingFile(root.path)
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw BundledSkillsInstallerError.symlinkRejected(url)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw BundledSkillsInstallerError.nonRegularFile(url)
            }
            let relative = relativePath(of: url, under: root)
            guard expected.contains(relative) else {
                throw BundledSkillsInstallerError.undeclaredFile(relative)
            }
        }
    }

    static func markerMatches(
        _ markerURL: URL,
        expected: SystemSkillMarker,
        destination: URL,
        manifest: SystemSkillManifest,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let actual = try? JSONDecoder().decode(SystemSkillMarker.self, from: data),
              actual.schema == expected.schema,
              actual.bundleVersion == expected.bundleVersion,
              actual.fingerprint == expected.fingerprint,
              actual.files == expected.files else {
            return false
        }
        for file in expected.files {
            let url = destination.appendingPathComponent(file.path)
            guard let digest = try? sha256(fileAt: url, fileManager: fileManager), digest == file.sha256 else {
                return false
            }
        }
        return (try? verifyBundle(destination, manifest: manifest, allowMarker: true, fileManager: fileManager)) != nil
    }

    private static func validate(_ manifest: SystemSkillManifest) throws {
        guard manifest.schema == schema else {
            throw BundledSkillsInstallerError.invalidManifest("unsupported schema \(manifest.schema)")
        }
        guard !manifest.bundleVersion.isEmpty, !manifest.skills.isEmpty else {
            throw BundledSkillsInstallerError.invalidManifest("bundle version and skills are required")
        }
        var names = Set<String>()
        for skill in manifest.skills {
            guard safeComponent(skill.name), safeComponent(skill.destination), skill.name == skill.destination else {
                throw BundledSkillsInstallerError.invalidManifest("invalid skill name/destination \(skill.name)")
            }
            guard names.insert(skill.name).inserted else {
                throw BundledSkillsInstallerError.invalidManifest("duplicate skill \(skill.name)")
            }
            guard skill.scope == "system" else {
                throw BundledSkillsInstallerError.invalidManifest("skill \(skill.name) is not system-scoped")
            }
            guard !skill.files.isEmpty, skill.files.contains(where: { $0.path == "SKILL.md" }) else {
                throw BundledSkillsInstallerError.invalidManifest("skill \(skill.name) is missing SKILL.md")
            }
            for file in skill.files {
                guard safeRelativePath(file.path), isSHA256(file.sha256) else {
                    throw BundledSkillsInstallerError.invalidManifest("invalid file entry for \(skill.name)")
                }
            }
        }
    }

    private static func recoverInterruptedInstall(
        skillsRoot: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let backup = skillsRoot.appendingPathComponent(".system.backup", isDirectory: true)
        if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: backup.path) {
            try fileManager.moveItem(at: backup, to: destination)
        }
        if let entries = try? fileManager.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(".system.stage-") {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func copyTree(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw BundledSkillsInstallerError.missingFile(source.path)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw BundledSkillsInstallerError.symlinkRejected(url)
            }
            let relative = relativePath(of: url, under: source)
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: target)
            } else {
                throw BundledSkillsInstallerError.nonRegularFile(url)
            }
        }
    }


    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else { return url.path }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func installedFiles(
        _ manifest: SystemSkillManifest,
        manifestData: Data
    ) -> [SystemSkillFile] {
        var files = manifest.skills.flatMap { skill in
            skill.files.map { SystemSkillFile(path: "\(skill.destination)/\($0.path)", sha256: $0.sha256) }
        }
        files.append(SystemSkillFile(path: manifestFilename, sha256: sha256(manifestData)))
        return files.sorted { $0.path < $1.path }
    }

    private static func aggregateHash(_ files: [SystemSkillFile]) -> String {
        var data = Data(markerSalt.utf8)
        data.append(0)
        for file in files.sorted(by: { $0.path < $1.path }) {
            data.append(contentsOf: file.path.utf8)
            data.append(0)
            data.append(contentsOf: file.sha256.utf8)
            data.append(0x0a)
        }
        return SHA256.hash(data: data).hexString
    }

    private static func sha256(fileAt url: URL, fileManager: FileManager) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw BundledSkillsInstallerError.symlinkRejected(url)
        }
        guard values.isRegularFile == true else {
            throw BundledSkillsInstallerError.nonRegularFile(url)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    private static func safeComponent(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Bundle {
    static var agentKitResourceBundle: Bundle { .module }
}
