//
//  UIEvidenceActivityProjection.swift
//  AgentKit
//
//  Projects `ui_evidence.v1` by structured schema and asset identity only.
//  Tool names, prose, recommendations, and file paths do not select this UI.
//

import ClientToolProtocol
import Foundation

enum UIEvidenceActivityProjection {
    private struct ParsedEvidence {
        let document: UIEvidenceDocument
        let sourceAsset: AgentAssetRef
        let cropAssets: [AgentAssetRef]
        let assets: [AgentAssetRef]
    }

    /// Returns the validated asset IDs in source/crop document order. WebKit
    /// calls this exact path before exposing any local bytes.
    static func validatedAssetIDs(in tool: ToolNodePayload) -> [String]? {
        parse(tool: tool)?.assets.map(\.id)
    }

    static func make(
        tool: ToolNodePayload,
        turnID: String,
        assetIndex: AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.UIEvidence? {
        guard let parsed = parse(tool: tool) else { return nil }
        let document = parsed.document
        let sourceName = compactDisplayName(
            parsed.sourceAsset.displayName
                ?? parsed.sourceAsset.workspaceRelativePath.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                }
                ?? document.source.assetID
        )

        let assets = parsed.assets.enumerated().map { index, asset -> ConversationWebDocument.UIEvidenceAsset in
            let crop = index > 0 ? document.crops[index - 1] : nil
            let reference = assetIndex.reference(forStructuredAsset: asset)
            let actionID = registerAction.map {
                $0(.transcript(turnID: turnID, action: .openAsset(reference)))
            }
            let bbox = crop.map { region(from: $0.sourceBBox) }
            let pixelSize = crop.map {
                (
                    max(1, Int((Double(document.source.width) * $0.sourceBBox.width).rounded())),
                    max(1, Int((Double(document.source.height) * $0.sourceBBox.height).rounded()))
                )
            } ?? (document.source.width, document.source.height)
            return ConversationWebDocument.UIEvidenceAsset(
                assetID: asset.id,
                role: crop == nil ? "source" : "crop",
                displayName: compactDisplayName(asset.displayName ?? asset.id),
                width: pixelSize.0,
                height: pixelSize.1,
                sourceAssetID: crop == nil ? nil : document.source.assetID,
                sourceBBox: bbox,
                purpose: crop?.purpose.rawValue,
                viewActionID: actionID
            )
        }

        let warnings = document.warningNotes
        let rawActionID = registerAction.map {
            $0(.transcript(turnID: turnID, action: .openUIEvidence(callID: tool.callID)))
        }
        let ocrPreview = document.elements
            .filter { $0.kind == .text && !($0.text ?? "").isEmpty }
            .prefix(8)
            .map { element in
                ConversationWebDocument.UIEvidenceTextItem(
                    id: element.id,
                    text: compactEvidenceText(element.text ?? ""),
                    bbox: region(from: element.bbox),
                    confidence: element.confidence,
                    evidence: element.evidence.rawValue
                )
            }
        let repeatedGroups = document.repeatedGroups.map { group in
            ConversationWebDocument.UIEvidenceGroup(
                id: group.id,
                axis: group.axis.rawValue,
                memberIDs: group.memberIDs,
                bbox: region(from: group.bbox),
                confidence: group.confidence,
                evidence: group.evidence.rawValue
            )
        }
        let uncertainties = document.uncertainties.enumerated().map { index, uncertainty in
            ConversationWebDocument.UIEvidenceNote(
                id: "uncertainty-\(index)",
                text: compactEvidenceText(uncertainty.description, limit: 360),
                reason: uncertainty.reason.map { compactEvidenceText($0, limit: 120) }
            )
        }
        var limits = [
            "Elements: \(document.limits.elementCount)",
            "Elements truncated: \(document.limits.elementsTruncated ? "yes" : "no")",
            "Tree nodes truncated: \(document.limits.treeNodesTruncated ? "yes" : "no")",
        ]
        if document.sourceTree.truncated && !document.limits.treeNodesTruncated {
            limits.append("Source tree truncated: yes")
        }

        return ConversationWebDocument.UIEvidence(
            title: "UI evidence: \(sourceName)",
            displayName: sourceName,
            sourceAssetID: document.source.assetID,
            sourceTreeKind: document.sourceTree.kind.rawValue,
            sourceTreeNote: document.sourceTreeNote,
            producer: compactDisplayName("\(document.producer.name)/\(document.producer.version)"),
            summary: ConversationWebDocument.UIEvidenceSummary(
                textElements: document.textElementCount,
                containers: document.containerCount,
                repeatedGroups: document.repeatedGroups.count,
                crops: document.crops.count,
                observed: document.observedCount,
                inferred: document.inferredCount,
                uncertain: document.uncertainElementCount,
                uncertainties: document.uncertainties.count,
                warnings: warnings.count
            ),
            assets: assets,
            ocrPreview: Array(ocrPreview),
            repeatedGroups: repeatedGroups,
            uncertainties: uncertainties,
            warnings: warnings,
            limits: limits,
            rawActionID: rawActionID
        )
    }

    private static func parse(tool: ToolNodePayload) -> ParsedEvidence? {
        guard let raw = tool.structuredOutput,
              raw["schema"].string == "ui_evidence.v1",
              let document = UIEvidenceDocument.parse(raw) else {
            return nil
        }

        var assetsByID: [String: AgentAssetRef] = [:]
        for asset in tool.assets {
            guard assetsByID[asset.id] == nil else { return nil }
            assetsByID[asset.id] = asset
        }
        guard let sourceAsset = assetsByID[document.source.assetID],
              sourceAsset.kind == "image",
              isSupportedImageMIMEType(sourceAsset.mimeType),
              sourceAsset.mimeType == document.source.mimeType,
              hasSafeWorkspaceRelativePath(sourceAsset),
              validateSourceAsset(sourceAsset, document: document) else {
            return nil
        }

        var cropAssets: [AgentAssetRef] = []
        for crop in document.crops {
            guard let asset = assetsByID[crop.assetID],
                  asset.id != sourceAsset.id,
                  asset.kind == "image",
                  isSupportedImageMIMEType(asset.mimeType),
                  hasSafeWorkspaceRelativePath(asset),
                  validateCropAsset(asset, crop: crop, sourceID: sourceAsset.id) else {
                return nil
            }
            cropAssets.append(asset)
        }

        return ParsedEvidence(
            document: document,
            sourceAsset: sourceAsset,
            cropAssets: cropAssets,
            assets: [sourceAsset] + cropAssets
        )
    }

    private static func validateSourceAsset(
        _ asset: AgentAssetRef,
        document: UIEvidenceDocument
    ) -> Bool {
        guard validateAssetRole(asset, expected: "source") else { return false }
        if let sha256 = asset.metadata?["sha256"] {
            guard sha256.string == document.source.sha256 else { return false }
        }
        if let width = asset.metadata?["width"] {
            guard integer(width) == document.source.width else { return false }
        }
        if let height = asset.metadata?["height"] {
            guard integer(height) == document.source.height else { return false }
        }
        if let sourceKind = asset.metadata?["source_kind"] {
            guard sourceKind.string == document.source.sourceKind.rawValue else { return false }
        }
        return true
    }

    private static func validateCropAsset(
        _ asset: AgentAssetRef,
        crop: UIEvidenceCrop,
        sourceID: String
    ) -> Bool {
        guard validateAssetRole(asset, expected: "crop") else { return false }
        if let rawSourceID = asset.metadata?["source_asset_id"] {
            guard rawSourceID.string == sourceID else { return false }
        }
        if let rawBBox = asset.metadata?["source_bbox"] {
            guard rawBBox.object != nil,
                  let bbox = parseRegion(rawBBox),
                  bbox == region(from: crop.sourceBBox) else {
                return false
            }
        }
        if let rawPurpose = asset.metadata?["purpose"] {
            guard rawPurpose.string == crop.purpose.rawValue else { return false }
        }
        return true
    }

    private static func validateAssetRole(_ asset: AgentAssetRef, expected: String) -> Bool {
        guard let role = asset.metadata?["asset_role"] else { return true }
        return role.string == expected
    }

    private static func parseRegion(_ value: JSONValue) -> ConversationWebDocument.ImageRegion? {
        guard let object = value.object,
              let x = finiteNumber(object["x"] ?? .null),
              let y = finiteNumber(object["y"] ?? .null),
              let width = finiteNumber(object["width"] ?? .null),
              let height = finiteNumber(object["height"] ?? .null),
              (0...1).contains(x),
              (0...1).contains(y),
              (0...1).contains(width),
              (0...1).contains(height),
              x + width <= 1.000_000_001,
              y + height <= 1.000_000_001 else {
            return nil
        }
        return ConversationWebDocument.ImageRegion(x: x, y: y, width: width, height: height)
    }

    private static func region(from bbox: UIEvidenceBBox) -> ConversationWebDocument.ImageRegion {
        ConversationWebDocument.ImageRegion(
            x: bbox.x,
            y: bbox.y,
            width: bbox.width,
            height: bbox.height
        )
    }

    private static func finiteNumber(_ value: JSONValue) -> Double? {
        let number: Double?
        switch value {
        case .integer(let integer): number = Double(integer)
        case .number(let value): number = value
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .integer(let value): return value
        case .number(let value) where value.rounded() == value: return Int(value)
        default: return nil
        }
    }

    static func hasSafeWorkspaceRelativePath(_ asset: AgentAssetRef) -> Bool {
        guard let path = asset.workspaceRelativePath,
              !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    private static func isSupportedImageMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return ["image/png", "image/jpeg", "image/webp"].contains(mimeType.lowercased())
    }

    private static func compactDisplayName(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = singleLine.isEmpty ? "ui-evidence" : singleLine
        return value.count <= 160 ? value : String(value.prefix(157)) + "…"
    }

    private static func compactEvidenceText(_ raw: String, limit: Int = 240) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.count <= limit ? singleLine : String(singleLine.prefix(limit - 1)) + "…"
    }
}

/// Schema-level dispatcher for structured image activities. This intentionally
/// knows only the two published output schemas, never a producer tool name.
enum StructuredImageActivityAssets {
    static func validatedAssetIDs(in tool: ToolNodePayload) -> [String]? {
        ViewImageActivityProjection.validatedAssetIDs(in: tool)
            ?? UIEvidenceActivityProjection.validatedAssetIDs(in: tool)
            ?? UILayoutActivityProjection.validatedImageAssetIDs(in: tool)
            ?? UIPreviewActivityProjection.validatedImageAssetIDs(in: tool)
    }
}

/// Resolves only registered workspace-relative image assets. Absolute paths and
/// file URIs in wire events are display metadata, never a source of bytes.
enum WorkspaceImageAssetResolver {
    struct ResolvedImage {
        let data: Data
        let mimeType: String
    }

    static func resolve(
        asset: AgentAssetRef,
        workspaceID: String?,
        workspaceRoot: URL
    ) -> ResolvedImage? {
        guard let validated = validatedWorkspaceImage(
            asset: asset,
            workspaceID: workspaceID,
            workspaceRoot: workspaceRoot
        ),
        let data = try? Data(contentsOf: validated.url, options: .mappedIfSafe),
        data.count <= 64 * 1024 * 1024 else {
            return nil
        }
        return ResolvedImage(data: data, mimeType: validated.mimeType)
    }

    /// The URL returned here has already passed workspace identity, traversal,
    /// symlink containment, regular-file, size, and image-content checks.
    static func resolvedImageURL(
        asset: AgentAssetRef,
        workspaceID: String?,
        workspaceRoot: URL
    ) -> URL? {
        validatedWorkspaceImage(
            asset: asset,
            workspaceID: workspaceID,
            workspaceRoot: workspaceRoot
        )?.url
    }

    private static func validatedWorkspaceImage(
        asset: AgentAssetRef,
        workspaceID: String?,
        workspaceRoot: URL
    ) -> (url: URL, mimeType: String)? {
        if let declaredWorkspaceID = asset.workspaceID, !declaredWorkspaceID.isEmpty,
           declaredWorkspaceID != workspaceID {
            return nil
        }
        guard asset.kind == "image",
              UIEvidenceActivityProjection.hasSafeWorkspaceRelativePath(asset),
              let relativePath = asset.workspaceRelativePath else {
            return nil
        }

        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard contains(candidate, in: root),
              let values = try? candidate.resourceValues(forKeys: [
                  .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 64 * 1024 * 1024,
              let sniffedMIME = sniffImageMIMEType(at: candidate),
              let declaredMIME = asset.mimeType?.lowercased(),
              declaredMIME == sniffedMIME else {
            return nil
        }
        return (candidate, sniffedMIME)
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPrefix)
    }

    private static func sniffImageMIMEType(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 12), data.count >= 12 else {
            return nil
        }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return "image/png"
        }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) {
            return "image/jpeg"
        }
        if String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        return nil
    }
}
