//
//  BuiltInPreviewResources.swift
//  AgentKit
//
//  Loads accepted, self-contained design previews from the Swift package.
//

import Foundation

public struct BuiltInPreviewHTML: Codable, Sendable, Equatable {
    public let bytes: Int
    public let sha256: String
    public let interactivePreviewMaximumBytes: Int?

    enum CodingKeys: String, CodingKey {
        case bytes, sha256
        case interactivePreviewMaximumBytes = "interactivePreviewMaximumBytes"
    }
}

public struct BuiltInPreviewManifest: Codable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let status: String
    public let statusNote: String?
    public let current: String
    public let html: BuiltInPreviewHTML

    enum CodingKeys: String, CodingKey {
        case id, title, status, statusNote, current, html
    }
}

public struct BuiltInPreviewResource: Sendable, Equatable {
    public let manifest: BuiltInPreviewManifest
    public let html: Data
    public let htmlURL: URL
}

public enum BuiltInPreviewError: Error, Equatable, LocalizedError {
    case resourceRootMissing
    case indexMissing
    case invalidIndex(String)
    case previewNotFound(String)
    case invalidManifest(String)
    case unsafePath(String)
    case htmlMissing(String)
    case htmlTooLarge(Int)
    case htmlDigestMismatch(expected: String, actual: String)
    case htmlSizeMismatch(expected: Int, actual: Int)
    case invalidHTML
    case remoteResource(String)

    public var errorDescription: String? {
        switch self {
        case .resourceRootMissing:
            return "Bundled Previews resource root is missing."
        case .indexMissing:
            return "Bundled preview index is missing."
        case .invalidIndex(let message):
            return "Bundled preview index is invalid: \(message)"
        case .previewNotFound(let id):
            return "Bundled preview \(id) was not found."
        case .invalidManifest(let message):
            return "Bundled preview manifest is invalid: \(message)"
        case .unsafePath(let path):
            return "Bundled preview path is unsafe: \(path)"
        case .htmlMissing(let path):
            return "Bundled preview HTML is missing: \(path)"
        case .htmlTooLarge(let bytes):
            return "Bundled preview HTML exceeds the 2 MiB limit: \(bytes) bytes."
        case .htmlDigestMismatch(let expected, let actual):
            return "Bundled preview HTML digest mismatch: expected \(expected), got \(actual)."
        case .htmlSizeMismatch(let expected, let actual):
            return "Bundled preview HTML size mismatch: expected \(expected), got \(actual)."
        case .invalidHTML:
            return "Bundled preview HTML is not valid UTF-8."
        case .remoteResource(let reference):
            return "Bundled preview contains an external resource reference: \(reference)"
        }
    }
}

public enum BuiltInPreviewCatalog {
    private struct Index: Decodable {
        let schema: String
        let previews: [Entry]

        struct Entry: Decodable {
            let id: String
            let manifest: String
        }
    }

    /// Loads an accepted preview using the resource bundle compiled for AgentKit.
    public static func load(
        id: String,
        bundle: Bundle? = nil
    ) throws -> BuiltInPreviewResource {
        let root = try rootURL(in: bundle ?? .module)
        let indexPath = root.appendingPathComponent("index.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            throw BuiltInPreviewError.indexMissing
        }
        let index: Index
        do {
            index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexPath))
        } catch {
            throw BuiltInPreviewError.invalidIndex(error.localizedDescription)
        }
        guard index.schema == "agentkit.previews.v1" else {
            throw BuiltInPreviewError.invalidIndex("unsupported schema \(index.schema)")
        }
        guard let entry = index.previews.first(where: { $0.id == id }) else {
            throw BuiltInPreviewError.previewNotFound(id)
        }

        let manifestURL = try safeURL(for: entry.manifest, under: root)
        let manifest: BuiltInPreviewManifest
        do {
            manifest = try JSONDecoder().decode(
                BuiltInPreviewManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw BuiltInPreviewError.invalidManifest(error.localizedDescription)
        }
        guard manifest.id == id else {
            throw BuiltInPreviewError.invalidManifest("manifest id does not match index id")
        }
        guard manifest.status == "accepted" else {
            throw BuiltInPreviewError.invalidManifest("only accepted previews may be loaded")
        }
        guard manifest.current == "current.html" else {
            throw BuiltInPreviewError.invalidManifest("current must be current.html")
        }

        let manifestRoot = manifestURL.deletingLastPathComponent()
        let htmlURL = try safeURL(for: manifest.current, under: manifestRoot)
        guard FileManager.default.fileExists(atPath: htmlURL.path) else {
            throw BuiltInPreviewError.htmlMissing(htmlURL.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: htmlURL)
        } catch {
            throw BuiltInPreviewError.htmlMissing(error.localizedDescription)
        }
        guard data.count > 0 else {
            throw BuiltInPreviewError.htmlMissing(htmlURL.path)
        }
        guard data.count <= PreviewArtifact.maximumViewerBytes else {
            throw BuiltInPreviewError.htmlTooLarge(data.count)
        }
        guard data.count == manifest.html.bytes else {
            throw BuiltInPreviewError.htmlSizeMismatch(
                expected: manifest.html.bytes,
                actual: data.count
            )
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw BuiltInPreviewError.invalidHTML
        }
        try validateNoRemoteResources(html)

        let digest = PreviewRFC8785.sha256(data: data).lowercased()
        let normalizedDigest = digest.hasPrefix("sha256:")
            ? String(digest.dropFirst("sha256:".count))
            : digest
        guard normalizedDigest == manifest.html.sha256.lowercased() else {
            throw BuiltInPreviewError.htmlDigestMismatch(
                expected: manifest.html.sha256,
                actual: digest
            )
        }
        return BuiltInPreviewResource(manifest: manifest, html: data, htmlURL: htmlURL)
    }

    public static func rootURL(in bundle: Bundle? = nil) throws -> URL {
        guard let root = (bundle ?? .module).url(
            forResource: "Previews",
            withExtension: nil
        ) else {
            throw BuiltInPreviewError.resourceRootMissing
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Resolves a relative resource path and rejects traversal outside its root.
    static func safeURL(for relativePath: String, under root: URL) throws -> URL {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        guard !decoded.isEmpty,
              !decoded.hasPrefix("/"),
              !decoded.contains("\\"),
              !decoded.split(separator: "/").contains("..") else {
            throw BuiltInPreviewError.unsafePath(relativePath)
        }
        let standardizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = standardizedRoot
            .appendingPathComponent(decoded, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path == standardizedRoot.path
                || candidate.path.hasPrefix(rootPrefix) else {
            throw BuiltInPreviewError.unsafePath(relativePath)
        }
        return candidate
    }

    /// Rejects external resource references while allowing inline data and
    /// fragment URLs. Inline scripts/styles remain valid for trusted previews.
    static func validateNoRemoteResources(_ html: String) throws {
        let patterns = [
            #"(?i)\b(?:src|href)\s*=\s*["'](?!#|data:|javascript:|mailto:)([^"']+)"#,
            #"(?i)\bsrcset\s*=\s*["'](?!#|data:)([^"']+)"#,
            #"(?i)url\(\s*["']?(?!#|data:)([^)"']+)"#,
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let matchRange = Range(match.range, in: html) {
                throw BuiltInPreviewError.remoteResource(String(html[matchRange]))
            }
        }
    }
}
