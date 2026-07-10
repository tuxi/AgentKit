//
//  AssetReference.swift
//  AgentKit
//
//  Lightweight asset references discovered in a turn transcript.
//

import Foundation

struct AssetReference: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case url
        case filePath
        case artifact
        case structured
    }

    let id: String
    let display: String
    let kind: Kind
    let target: String
    let turnID: String
    let sourceCallID: String?
    let resolvedArtifactCallID: String?
    let structuredAsset: AgentAssetRef?

    init(
        display: String,
        kind: Kind,
        target: String,
        turnID: String,
        sourceCallID: String? = nil,
        resolvedArtifactCallID: String? = nil,
        structuredAsset: AgentAssetRef? = nil
    ) {
        self.id = structuredAsset?.id ?? "\(kind.rawValue):\(turnID):\(target):\(sourceCallID ?? "")"
        self.display = display
        self.kind = kind
        self.target = target
        self.turnID = turnID
        self.sourceCallID = sourceCallID
        self.resolvedArtifactCallID = resolvedArtifactCallID
        self.structuredAsset = structuredAsset
    }
}

struct AssetIndex: Sendable {
    let turnID: String
    private let artifactsByPath: [String: ArtifactNode]
    private let artifactsByCallID: [String: ArtifactNode]
    private let structuredAssetsByPath: [String: AgentAssetRef]
    private let structuredAssetsByID: [String: AgentAssetRef]

    init(turn: ConversationTurn) {
        self.turnID = turn.id
        var byPath: [String: ArtifactNode] = [:]
        var byCallID: [String: ArtifactNode] = [:]
        var structuredByPath: [String: AgentAssetRef] = [:]
        var structuredByID: [String: AgentAssetRef] = [:]

        func index(_ artifact: ArtifactNode) {
            byCallID[artifact.callID] = artifact
            if let path = artifact.path, !path.isEmpty {
                for alias in Self.pathAliases(for: path, includeRelativeForms: true) {
                    byPath[alias] = artifact
                }
            }
        }

        func index(_ asset: AgentAssetRef) {
            structuredByID[asset.id] = asset
            let paths: [(String?, Bool)] = [
                (asset.workspaceRelativePath, true),
                (asset.uri, true),
                (asset.displayName, true),
                (asset.absolutePath, false)
            ]
            for (raw, includeRelativeForms) in paths {
                guard let raw, !raw.isEmpty else { continue }
                for alias in Self.pathAliases(for: raw, includeRelativeForms: includeRelativeForms) {
                    structuredByPath[alias] = asset
                }
            }
        }

        for block in turn.blocks {
            switch block {
            case .toolGroup(let group):
                for tool in group.tools {
                    if let artifact = tool.artifact {
                        index(artifact)
                    }
                    for asset in tool.assets {
                        index(asset)
                    }
                }
            case .artifact(_, let artifact):
                index(artifact)
            default:
                break
            }
        }

        self.artifactsByPath = byPath
        self.artifactsByCallID = byCallID
        self.structuredAssetsByPath = structuredByPath
        self.structuredAssetsByID = structuredByID
    }

    func artifact(callID: String) -> ArtifactNode? {
        artifactsByCallID[callID]
    }

    func artifact(path: String) -> ArtifactNode? {
        for alias in Self.pathAliases(for: path, includeRelativeForms: true) {
            if let artifact = artifactsByPath[alias] {
                return artifact
            }
        }
        return nil
    }

    func reference(forURL raw: String) -> AssetReference {
        if Self.isRuntimeResourceURI(raw) {
            return reference(forRuntimeResourceURI: raw)
        }
        return AssetReference(
            display: raw,
            kind: .url,
            target: raw,
            turnID: turnID
        )
    }

    func reference(forRuntimeResourceURI raw: String) -> AssetReference {
        let uri = Self.normalizedPath(raw)
        if let structured = structuredAsset(path: uri) {
            return reference(forStructuredAsset: structured, display: raw)
        }

        let lastPathComponent = URL(string: uri)?.lastPathComponent
        let asset = AgentAssetRef(
            id: "resource_\(turnID)_\(Self.stableHexHash(uri))",
            kind: "mcp_resource",
            uri: uri,
            displayName: (lastPathComponent?.isEmpty == false) ? lastPathComponent : uri,
            metadata: [
                "resource_uri": .string(uri),
                "resource_scheme": .string(URL(string: uri)?.scheme ?? "")
            ]
        )
        return reference(forStructuredAsset: asset, display: raw)
    }

    func reference(forPath raw: String, sourceCallID: String? = nil) -> AssetReference {
        let normalized = Self.normalizedPath(raw)
        let artifact = artifact(path: raw)
        if let artifact {
            return AssetReference(
                display: raw,
                kind: .artifact,
                target: normalized,
                turnID: turnID,
                sourceCallID: sourceCallID,
                resolvedArtifactCallID: artifact.callID
            )
        }
        if let structured = structuredAsset(path: normalized) {
            return reference(forStructuredAsset: structured, display: raw)
        }
        return AssetReference(
            display: raw,
            kind: .filePath,
            target: normalized,
            turnID: turnID,
            sourceCallID: sourceCallID,
            resolvedArtifactCallID: nil
        )
    }

    func reference(forStructuredAsset asset: AgentAssetRef, display: String? = nil) -> AssetReference {
        let target = asset.workspaceRelativePath
            ?? asset.absolutePath
            ?? asset.uri
            ?? asset.id
        return AssetReference(
            display: display ?? asset.displayName ?? target,
            kind: .structured,
            target: target,
            turnID: turnID,
            sourceCallID: asset.sourceCallID,
            structuredAsset: asset
        )
    }

    func reference(forAnnotation annotation: AgentTextAnnotation) -> AssetReference? {
        guard let asset = structuredAssetsByID[annotation.assetID] else { return nil }
        return reference(forStructuredAsset: asset, display: annotation.text)
    }

    func structuredAsset(id: String) -> AgentAssetRef? {
        structuredAssetsByID[id]
    }

    func assetsShareFile(_ lhs: AgentAssetRef, _ rhs: AgentAssetRef) -> Bool {
        let lhsPath = lhs.workspaceRelativePath ?? lhs.absolutePath ?? lhs.uri ?? lhs.displayName
        let rhsPath = rhs.workspaceRelativePath ?? rhs.absolutePath ?? rhs.uri ?? rhs.displayName
        guard let lhsPath, let rhsPath else { return false }
        return Self.normalizedPath(lhsPath) == Self.normalizedPath(rhsPath)
    }

    func structuredAsset(path: String) -> AgentAssetRef? {
        for alias in Self.pathAliases(for: path, includeRelativeForms: true) {
            if let asset = structuredAssetsByPath[alias] {
                return asset
            }
        }
        return nil
    }

    static func isRuntimeResourceURI(_ raw: String) -> Bool {
        guard let scheme = URL(string: normalizedPath(raw))?.scheme?.lowercased() else { return false }
        return !["http", "https", "file"].contains(scheme)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,;:)]}"))
            .replacingOccurrences(of: "\\/", with: "/")
        guard trimmed != "/" else { return trimmed }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func pathAliases(for raw: String, includeRelativeForms: Bool) -> [String] {
        var aliases: [String] = []

        func append(_ value: String) {
            let normalized = normalizedPath(value)
            guard !normalized.isEmpty, !aliases.contains(normalized) else { return }
            aliases.append(normalized)
        }

        append(raw)

        if let url = URL(string: raw),
           url.scheme == "workspace" {
            append(url.path)
        }

        let normalized = normalizedPath(raw)
        if normalized.hasPrefix("./") {
            append(String(normalized.dropFirst(2)))
        }

        guard includeRelativeForms else { return aliases }
        if normalized.hasPrefix("/") {
            append(String(normalized.dropFirst()))
        }
        let baseAliases = aliases
        for alias in baseAliases {
            if !alias.hasPrefix("/") {
                append("/" + alias)
            }
            if !alias.hasPrefix("./"), !alias.hasPrefix("/") {
                append("./" + alias)
            }
        }

        return aliases
    }

    private static func stableHexHash(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

enum AssetReferenceDetector {
    private static let urlPattern = #"https?://[^\s<>)\]]+"#
    private static let runtimeResourcePattern = #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>)\]]+"#
    private static let pathPattern = #"(?<![\w:/.-])(?:\.{1,2}/|/|[A-Za-z0-9_+.-]+/)[A-Za-z0-9_+@./:-]*\.[A-Za-z0-9_+-]+"#
    private static let directoryPattern = #"(?<![\w:/.-])(?:\.{1,2}/|/|\.?[A-Za-z0-9_+.-]+/)(?:[A-Za-z0-9_+@.-]+/)*"#

    static func matches(in text: String, assetIndex: AssetIndex) -> [(range: NSRange, reference: AssetReference)] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [(NSRange, AssetReference)] = []

        for match in regex(urlPattern).matches(in: text, range: fullRange) {
            let raw = nsText.substring(with: match.range)
            results.append((match.range, assetIndex.reference(forURL: raw)))
        }

        for match in regex(runtimeResourcePattern).matches(in: text, range: fullRange) {
            guard !results.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else {
                continue
            }
            let raw = nsText.substring(with: match.range)
            guard AssetIndex.isRuntimeResourceURI(raw) else { continue }
            results.append((match.range, assetIndex.reference(forRuntimeResourceURI: raw)))
        }

        for match in regex(pathPattern).matches(in: text, range: fullRange) {
            guard !results.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else {
                continue
            }
            let raw = nsText.substring(with: match.range)
            results.append((match.range, assetIndex.reference(forPath: raw)))
        }

        for match in regex(directoryPattern).matches(in: text, range: fullRange) {
            guard !results.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else {
                continue
            }
            let raw = nsText.substring(with: match.range)
            let reference = assetIndex.reference(forPath: raw)
            guard reference.kind != .filePath else { continue }
            results.append((match.range, reference))
        }

        return results.sorted(by: { (
            lhs: (range: NSRange, reference: AssetReference),
            rhs: (range: NSRange, reference: AssetReference)
        ) in
            lhs.range.location < rhs.range.location
        })
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static and tested; fallback is intentionally empty.
        (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }
}

enum TextAnnotationReferenceDetector {
    static func matches(
        in text: String,
        annotations: [AgentTextAnnotation],
        consumedKeys: inout Set<String>,
        assetIndex: AssetIndex
    ) -> [(range: NSRange, reference: AssetReference)] {
        guard !annotations.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [(NSRange, AssetReference)] = []

        for annotation in annotations {
            let annotationKey = annotation.renderedMatchKey
            guard !consumedKeys.contains(annotationKey) else { continue }

            let display = annotation.text
            guard !display.isEmpty,
                  let reference = assetIndex.reference(forAnnotation: annotation) else {
                continue
            }

            var searchRange = fullRange
            while searchRange.length > 0 {
                let found = nsText.range(of: display, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }

                if !results.contains(where: { NSIntersectionRange($0.0, found).length > 0 }) {
                    results.append((found, reference))
                    consumedKeys.insert(annotationKey)
                    break
                }

                let nextLocation = found.location + max(found.length, 1)
                guard nextLocation < nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        return results.sorted(by: { (
            lhs: (range: NSRange, reference: AssetReference),
            rhs: (range: NSRange, reference: AssetReference)
        ) in
            lhs.range.location < rhs.range.location
        })
    }
}

extension AgentTextAnnotation {
    var renderedMatchKey: String {
        [
            assetID,
            text,
            startUTF16.map(String.init) ?? "",
            endUTF16.map(String.init) ?? "",
            sourceTurnID ?? "",
            sourceCallID ?? ""
        ].joined(separator: "|")
    }

    var looksLikePathText: Bool {
        text.contains("/") || text.contains("\\")
    }

    var lineNumberValue: Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    func replacingAssetID(_ assetID: String) -> AgentTextAnnotation {
        AgentTextAnnotation(
            assetID: assetID,
            kind: kind,
            text: text,
            startByte: startByte,
            endByte: endByte,
            startUTF16: startUTF16,
            endUTF16: endUTF16,
            sourceTurnID: sourceTurnID,
            sourceCallID: sourceCallID
        )
    }
}

extension Array where Element == AgentTextAnnotation {
    var sortedForRenderedMatching: [AgentTextAnnotation] {
        enumerated()
            .sorted { lhs, rhs in
                let lStart = lhs.element.startUTF16 ?? Int.max
                let rStart = rhs.element.startUTF16 ?? Int.max
                if lStart != rStart { return lStart < rStart }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func resolvingNearbyLineNumberAssets(assetIndex: AssetIndex) -> [AgentTextAnnotation] {
        let sorted = sortedForRenderedMatching
        return sorted.enumerated().map { index, annotation in
            guard annotation.looksLikePathText,
                  let annotationEnd = annotation.endUTF16,
                  let currentAsset = assetIndex.structuredAsset(id: annotation.assetID) else {
                return annotation
            }

            let nearbyLine = sorted.dropFirst(index + 1).first { candidate in
                guard let candidateStart = candidate.startUTF16,
                      candidateStart >= annotationEnd,
                      candidateStart - annotationEnd <= 8,
                      let line = candidate.lineNumberValue,
                      let candidateAsset = assetIndex.structuredAsset(id: candidate.assetID),
                      assetIndex.assetsShareFile(currentAsset, candidateAsset),
                      candidateAsset.range?.startLine == line else {
                    return false
                }
                return true
            }

            guard let nearbyLine else { return annotation }
            return annotation.replacingAssetID(nearbyLine.assetID)
        }
    }
}
