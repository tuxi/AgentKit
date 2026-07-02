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
                byPath[Self.normalizedPath(path)] = artifact
            }
        }

        func index(_ asset: AgentAssetRef) {
            structuredByID[asset.id] = asset
            let paths = [
                asset.workspaceRelativePath,
                asset.absolutePath,
                asset.uri,
                asset.displayName
            ]
            for raw in paths {
                guard let raw, !raw.isEmpty else { continue }
                structuredByPath[Self.normalizedPath(raw)] = asset
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
        artifactsByPath[Self.normalizedPath(path)]
    }

    func reference(forURL raw: String) -> AssetReference {
        AssetReference(
            display: raw,
            kind: .url,
            target: raw,
            turnID: turnID
        )
    }

    func reference(forPath raw: String, sourceCallID: String? = nil) -> AssetReference {
        let normalized = Self.normalizedPath(raw)
        if let structured = structuredAsset(path: normalized) {
            return reference(forStructuredAsset: structured, display: raw)
        }
        let artifact = artifact(path: raw)
        return AssetReference(
            display: raw,
            kind: artifact == nil ? .filePath : .artifact,
            target: normalized,
            turnID: turnID,
            sourceCallID: sourceCallID,
            resolvedArtifactCallID: artifact?.callID
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

    private func structuredAsset(path: String) -> AgentAssetRef? {
        structuredAssetsByPath[path] ?? structuredAssetsByPath[Self.normalizedPath(path)]
    }

    private static func normalizedPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,;:)]}"))
            .replacingOccurrences(of: "\\/", with: "/")
    }
}

enum AssetReferenceDetector {
    private static let urlPattern = #"https?://[^\s<>)\]]+"#
    private static let pathPattern = #"(?<![\w:/.-])(?:\.{1,2}/|/|[A-Za-z0-9_+.-]+/)[A-Za-z0-9_+@./:-]*\.[A-Za-z0-9_+-]+"#

    static func matches(in text: String, assetIndex: AssetIndex) -> [(range: NSRange, reference: AssetReference)] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [(NSRange, AssetReference)] = []

        for match in regex(urlPattern).matches(in: text, range: fullRange) {
            let raw = nsText.substring(with: match.range)
            results.append((match.range, assetIndex.reference(forURL: raw)))
        }

        for match in regex(pathPattern).matches(in: text, range: fullRange) {
            guard !results.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else {
                continue
            }
            let raw = nsText.substring(with: match.range)
            results.append((match.range, assetIndex.reference(forPath: raw)))
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
        assetIndex: AssetIndex
    ) -> [(range: NSRange, reference: AssetReference)] {
        guard !annotations.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [(NSRange, AssetReference)] = []
        var seen = Set<String>()

        for annotation in annotations {
            let display = annotation.text
            guard !display.isEmpty,
                  let reference = assetIndex.reference(forAnnotation: annotation) else {
                continue
            }

            var searchRange = fullRange
            while searchRange.length > 0 {
                let found = nsText.range(of: display, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }

                let key = "\(annotation.assetID):\(found.location):\(found.length)"
                if !seen.contains(key),
                   !results.contains(where: { NSIntersectionRange($0.0, found).length > 0 }) {
                    results.append((found, reference))
                    seen.insert(key)
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
