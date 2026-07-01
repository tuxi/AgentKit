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
    }

    let id: String
    let display: String
    let kind: Kind
    let target: String
    let turnID: String
    let sourceCallID: String?
    let resolvedArtifactCallID: String?

    init(
        display: String,
        kind: Kind,
        target: String,
        turnID: String,
        sourceCallID: String? = nil,
        resolvedArtifactCallID: String? = nil
    ) {
        self.id = "\(kind.rawValue):\(turnID):\(target):\(sourceCallID ?? "")"
        self.display = display
        self.kind = kind
        self.target = target
        self.turnID = turnID
        self.sourceCallID = sourceCallID
        self.resolvedArtifactCallID = resolvedArtifactCallID
    }
}

struct AssetIndex: Sendable {
    let turnID: String
    private let artifactsByPath: [String: ArtifactNode]
    private let artifactsByCallID: [String: ArtifactNode]

    init(turn: ConversationTurn) {
        self.turnID = turn.id
        var byPath: [String: ArtifactNode] = [:]
        var byCallID: [String: ArtifactNode] = [:]

        func index(_ artifact: ArtifactNode) {
            byCallID[artifact.callID] = artifact
            if let path = artifact.path, !path.isEmpty {
                byPath[path] = artifact
            }
        }

        for block in turn.blocks {
            switch block {
            case .toolGroup(let group):
                for tool in group.tools {
                    if let artifact = tool.artifact {
                        index(artifact)
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
    }

    func artifact(callID: String) -> ArtifactNode? {
        artifactsByCallID[callID]
    }

    func artifact(path: String) -> ArtifactNode? {
        artifactsByPath[path] ?? artifactsByPath[normalizedPath(path)]
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
        let normalized = normalizedPath(raw)
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

    private func normalizedPath(_ path: String) -> String {
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
