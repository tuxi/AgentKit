//
//  UILayoutActivityProjection.swift
//  AgentKit
//
//  Projects `ui_layout_result.v1` by structured schema and asset identity only.
//  Tool names, prose, and file paths do not select this UI.
//

import ClientToolProtocol
import Foundation

enum UILayoutActivityProjection {
    private struct ParsedLayout {
        let document: UILayoutResultDocument
        let overlayAsset: AgentAssetRef
        let layoutJSONAsset: AgentAssetRef
    }

    /// Returns the validated image asset IDs (the overlay only). The bridge
    /// uses this exact path before exposing local bytes to WebKit.
    static func validatedImageAssetIDs(in tool: ToolNodePayload) -> [String]? {
        parse(tool: tool).map { [$0.overlayAsset.id] }
    }

    /// Reuses the full ui_layout_result.v1 validation path so a lineage card
    /// can only link to a layout revision whose JSON asset is registered.
    static func validatedLayoutRevision(
        in tool: ToolNodePayload
    ) -> (document: UILayoutResultDocument, layoutJSON: AgentAssetRef)? {
        guard let parsed = parse(tool: tool) else { return nil }
        return (parsed.document, parsed.layoutJSONAsset)
    }

    static func make(
        tool: ToolNodePayload,
        turnID: String,
        assetIndex: AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.UILayout? {
        guard let parsed = parse(tool: tool) else { return nil }
        let document = parsed.document

        func projectedAsset(
            _ asset: AgentAssetRef,
            descriptor: UILayoutAssetDescriptor,
            role: String
        ) -> ConversationWebDocument.UILayoutAsset {
            let reference = assetIndex.reference(forStructuredAsset: asset)
            let actionID = registerAction.map {
                $0(.transcript(turnID: turnID, action: .openAsset(reference)))
            }
            return ConversationWebDocument.UILayoutAsset(
                assetID: asset.id,
                role: role,
                displayName: compactDisplayName(
                    asset.displayName ?? descriptor.filename
                ),
                width: descriptor.width,
                height: descriptor.height,
                viewActionID: actionID
            )
        }

        let rawActionID = registerAction.map {
            $0(.transcript(turnID: turnID, action: .openUILayout(callID: tool.callID)))
        }
        return ConversationWebDocument.UILayout(
            title: "UI layout: \(document.created ? "created" : "reused") revision \(document.revision)",
            artifactID: document.artifactID,
            revision: document.revision,
            revisionSHA256: document.revisionSHA256,
            sourceAssetID: document.sourceAssetID,
            sourceAssetSHA256: document.sourceAssetSHA256,
            evidenceSHA256: document.evidenceSHA256,
            canvasWidth: document.canvas.width,
            canvasHeight: document.canvas.height,
            nodeCount: document.nodeCount,
            assumptionCount: document.assumptionCount,
            targets: document.targets,
            created: document.created,
            overlay: projectedAsset(
                parsed.overlayAsset,
                descriptor: document.overlayAsset,
                role: "layout_overlay"
            ),
            layoutJSON: projectedAsset(
                parsed.layoutJSONAsset,
                descriptor: document.layoutJSONAsset,
                role: "layout_json"
            ),
            rawActionID: rawActionID
        )
    }

    private static func parse(tool: ToolNodePayload) -> ParsedLayout? {
        guard let raw = tool.structuredOutput,
              raw["schema"].string == "ui_layout_result.v1",
              let document = UILayoutResultDocument.parse(raw) else {
            return nil
        }

        var assetsByID: [String: AgentAssetRef] = [:]
        for asset in tool.assets {
            guard assetsByID[asset.id] == nil else { return nil }
            assetsByID[asset.id] = asset
        }
        guard let overlayAsset = assetsByID[document.overlayAsset.assetID],
              overlayAsset.id != document.layoutJSONAsset.assetID,
              isRegisteredImage(
                  overlayAsset,
                  descriptor: document.overlayAsset,
                  tool: tool
              ),
              validateAssetMetadata(
                  overlayAsset,
                  document: document,
                  role: "layout_overlay",
                  expectedPath: document.overlayAsset.relativePath
              ),
              let layoutJSONAsset = assetsByID[document.layoutJSONAsset.assetID],
              isRegisteredFile(
                  layoutJSONAsset,
                  descriptor: document.layoutJSONAsset,
                  tool: tool
              ),
              validateAssetMetadata(
                  layoutJSONAsset,
                  document: document,
                  role: "layout_json",
                  expectedPath: document.layoutJSONAsset.relativePath
              ) else {
            return nil
        }

        return ParsedLayout(
            document: document,
            overlayAsset: overlayAsset,
            layoutJSONAsset: layoutJSONAsset
        )
    }

    private static func isRegisteredImage(
        _ asset: AgentAssetRef,
        descriptor: UILayoutAssetDescriptor,
        tool: ToolNodePayload
    ) -> Bool {
        guard asset.kind == "image",
              asset.mimeType?.lowercased() == descriptor.mimeType,
              hasSafeWorkspaceRelativePath(asset),
              asset.workspaceRelativePath == descriptor.relativePath else {
            return false
        }
        return matchesSourceCall(asset, tool: tool)
    }

    private static func isRegisteredFile(
        _ asset: AgentAssetRef,
        descriptor: UILayoutAssetDescriptor,
        tool: ToolNodePayload
    ) -> Bool {
        guard asset.kind == "file",
              asset.mimeType?.lowercased() == descriptor.mimeType,
              hasSafeWorkspaceRelativePath(asset),
              asset.workspaceRelativePath == descriptor.relativePath else {
            return false
        }
        return matchesSourceCall(asset, tool: tool)
    }

    private static func matchesSourceCall(
        _ asset: AgentAssetRef,
        tool: ToolNodePayload
    ) -> Bool {
        guard let sourceCallID = asset.sourceCallID else { return true }
        return sourceCallID == tool.callID
    }

    private static func validateAssetMetadata(
        _ asset: AgentAssetRef,
        document: UILayoutResultDocument,
        role: String,
        expectedPath: String
    ) -> Bool {
        guard let metadata = asset.metadata else { return true }
        guard validateRole(metadata["asset_role"], expected: role),
              validateString(metadata["layout_artifact_id"], expected: document.artifactID),
              validateString(
                  metadata["layout_revision_sha256"],
                  expected: document.revisionSHA256
              ),
              validateString(
                  metadata["source_asset_id"],
                  expected: document.sourceAssetID
              ),
              validateString(
                  metadata["source_asset_sha256"],
                  expected: document.sourceAssetSHA256
              ),
              validateInteger(metadata["layout_revision"], expected: document.revision),
              validateInteger(metadata["node_count"], expected: document.nodeCount),
              validateCanvas(metadata["canvas"], canvas: document.canvas) else {
            return false
        }
        if let rawPath = metadata["relative_path"] {
            guard rawPath.string == expectedPath else { return false }
        }
        return true
    }

    private static func validateRole(_ value: JSONValue?, expected: String) -> Bool {
        guard let value else { return true }
        return value.string == expected
    }

    private static func validateString(_ value: JSONValue?, expected: String) -> Bool {
        guard let value else { return true }
        return value.string == expected
    }

    private static func validateInteger(_ value: JSONValue?, expected: Int) -> Bool {
        guard let value else { return true }
        switch value {
        case .integer(let integer):
            return integer == expected
        case .number(let number):
            return number == Double(expected)
        default:
            return false
        }
    }

    private static func validateCanvas(
        _ value: JSONValue?,
        canvas: UILayoutCanvas
    ) -> Bool {
        guard let value else { return true }
        guard let object = value.object else { return false }
        return integer(object["width"]) == canvas.width
            && integer(object["height"]) == canvas.height
    }

    private static func integer(_ value: JSONValue?) -> Int? {
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
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    private static func compactDisplayName(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = singleLine.isEmpty ? "ui-layout" : singleLine
        return value.count <= 160 ? value : String(value.prefix(157)) + "…"
    }
}
