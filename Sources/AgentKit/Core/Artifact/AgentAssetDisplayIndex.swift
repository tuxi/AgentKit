//
//  AgentAssetDisplayIndex.swift
//  AgentKit
//
//  Presentation helpers for structured asset references.
//

import Foundation

enum AgentAssetDisplayIndex {
    static func unique(_ assets: [AgentAssetRef]) -> [AgentAssetRef] {
        var result: [AgentAssetRef] = []
        var positionsByKey: [String: Int] = [:]

        for asset in assets {
            let key = semanticKey(for: asset)
            if let index = positionsByKey[key] {
                if shouldPrefer(asset, over: result[index]) {
                    result[index] = asset
                }
                continue
            }

            positionsByKey[key] = result.count
            result.append(asset)
        }

        return result
    }

    private static func semanticKey(for asset: AgentAssetRef) -> String {
        let target = asset.workspaceRelativePath
            ?? asset.absolutePath
            ?? asset.uri
            ?? asset.displayName
            ?? asset.id
        let lineRange = [
            asset.range?.startLine.map(String.init) ?? "",
            asset.range?.endLine.map(String.init) ?? ""
        ].joined(separator: ":")
        return [
            asset.kind,
            asset.workspaceID ?? "",
            normalize(target),
            lineRange
        ].joined(separator: "|")
    }

    private static func shouldPrefer(_ candidate: AgentAssetRef, over current: AgentAssetRef) -> Bool {
        let candidateColumn = candidate.range?.startColumn ?? 0
        let currentColumn = current.range?.startColumn ?? 0
        if currentColumn <= 1, candidateColumn > 1 { return true }
        let currentHasPreview = !(current.preview ?? "").isEmpty
        let candidateHasPreview = !(candidate.preview ?? "").isEmpty
        if !currentHasPreview, candidateHasPreview { return true }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,;:)]}"))
            .replacingOccurrences(of: "\\/", with: "/")
    }
}
