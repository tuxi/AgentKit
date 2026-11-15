//
//  UIPreviewActivityProjection.swift
//  AgentKit
//
//  Projects `ui_preview_result.v1` by structured schema and canonical asset
//  identity only. Tool names, prose, and file paths do not select this UI.
//  The preview artifact supplies runtime identity; the result supplies the
//  adaptation/explore classification and the lineage.
//

import ClientToolProtocol
import Foundation

enum UIPreviewActivityProjection {
    private static let negotiation = PreviewCapabilityNegotiation(
        hello: PreviewCapability.allCases.map(\.rawValue),
        runtime: PreviewCapability.allCases.map(\.rawValue),
        client: .previewClient
    )

    struct RelatedAssets: Equatable, Sendable {
        let layoutJSON: AgentAssetRef?
        let evidenceJSON: AgentAssetRef?
    }

    /// Returns the validated fallback image asset ID. The bridge uses this
    /// exact path before exposing local bytes to WebKit.
    static func validatedImageAssetIDs(in tool: ToolNodePayload) -> [String]? {
        guard let document = resultDocument(in: tool),
              let asset = registeredFallbackAsset(
                  document.fallbackAsset,
                  in: tool
              ) else {
            return nil
        }
        return [asset.id]
    }

    static func make(
        tool: ToolNodePayload,
        turnID: String,
        previewArtifacts: [PreviewArtifact],
        turns: [ConversationTurn],
        assetIndex: AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.UIPreview? {
        guard let document = resultDocument(in: tool),
              let artifact = correlatedArtifact(
                  previewArtifacts,
                  tool: tool,
                  document: document
              ),
              let fallbackAsset = registeredFallbackAsset(
                  document.fallbackAsset,
                  in: tool
              ) else {
            return nil
        }

        let related: RelatedAssets
        if let lineage = document.lineage {
            guard let resolved = resolveRelatedAssets(
                lineage: lineage,
                turns: turns
            ) else {
                return nil
            }
            related = resolved
        } else {
            related = RelatedAssets(layoutJSON: nil, evidenceJSON: nil)
        }

        func projectedAsset(
            _ asset: AgentAssetRef,
            fallbackName: String,
            width: Int?,
            height: Int?,
            mimeType: String?,
            sha256: String?
        ) -> ConversationWebDocument.UIPreviewAsset {
            let reference = assetIndex.reference(forStructuredAsset: asset)
            let actionID = registerAction.map {
                $0(.transcript(turnID: turnID, action: .openAsset(reference)))
            }
            return ConversationWebDocument.UIPreviewAsset(
                assetID: asset.id,
                role: "fallback",
                displayName: compactDisplayName(
                    asset.displayName ?? URL(fileURLWithPath: fallbackName).lastPathComponent
                ),
                mimeType: mimeType,
                width: width,
                height: height,
                sha256: sha256,
                viewActionID: actionID
            )
        }

        func relatedAsset(_ asset: AgentAssetRef) -> ConversationWebDocument.UIPreviewRelatedAsset {
            let reference = assetIndex.reference(forStructuredAsset: asset)
            let actionID = registerAction.map {
                $0(.transcript(turnID: turnID, action: .openAsset(reference)))
            }
            return ConversationWebDocument.UIPreviewRelatedAsset(
                assetID: asset.id,
                displayName: compactDisplayName(
                    asset.displayName
                        ?? asset.workspaceRelativePath.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        }
                        ?? asset.id
                ),
                viewActionID: actionID
            )
        }

        let rawActionID = registerAction.map {
            $0(.transcript(turnID: turnID, action: .openUIPreview(callID: tool.callID)))
        }
        let state = artifact.presentationState(capabilities: negotiation)
        let lineage = document.lineage.map { lineage in
            ConversationWebDocument.UIPreviewLineage(
                layoutArtifactID: lineage.layoutArtifactID,
                layoutRevision: lineage.layoutRevision,
                layoutRevisionSHA256: lineage.layoutRevisionSHA256,
                sourceAssetID: lineage.sourceAssetID,
                sourceAssetSHA256: lineage.sourceAssetSHA256,
                evidenceSHA256: lineage.evidenceSHA256,
                target: lineage.target,
                state: lineage.state,
                targetMatrixID: lineage.targetMatrix.id,
                targetMatrixTargets: lineage.targetMatrix.targets,
                approvalState: lineage.approval.state.rawValue,
                approvalEvidenceRef: lineage.approval.evidenceRef
            )
        }

        return ConversationWebDocument.UIPreview(
            title: document.title,
            mode: document.mode,
            modeLabel: document.modeLabel,
            artifactKey: document.artifactKey,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            revisionSHA256: artifact.revisionSHA256,
            kind: artifact.kind.rawValue,
            presentationState: state.rawValue,
            runtimeStatus: artifact.status.rawValue,
            statusLabel: statusLabel(state),
            tone: tone(state),
            fallbackText: artifact.fallback?.text,
            minHeight: artifact.presentation?.minHeight,
            preferredAspectRatio: artifact.presentation?.preferredAspectRatio,
            fallback: projectedAsset(
                fallbackAsset,
                fallbackName: document.fallbackAsset.relativePath,
                width: document.fallbackAsset.width,
                height: document.fallbackAsset.height,
                mimeType: document.fallbackAsset.mimeType,
                sha256: document.fallbackAsset.sha256
            ),
            lineage: lineage,
            layoutJSON: related.layoutJSON.map(relatedAsset),
            evidenceJSON: related.evidenceJSON.map(relatedAsset),
            rawActionID: rawActionID
        )
    }

    static func resultDocument(in tool: ToolNodePayload) -> UIPreviewResultDocument? {
        guard let raw = tool.structuredOutput,
              raw["schema"].string == "ui_preview_result.v1" else {
            return nil
        }
        return UIPreviewResultDocument.parse(raw)
    }

    // MARK: - Artifact binding

    private static func validateArtifact(
        _ artifact: PreviewArtifact,
        document: UIPreviewResultDocument,
        tool: ToolNodePayload
    ) -> Bool {
        guard artifact.callID == tool.callID,
              artifact.title == document.title,
              artifact.kind.rawValue == document.kind,
              artifact.metadata["preview_mode"].string == document.mode else {
            return false
        }

        switch document.mode {
        case UIPreviewResultDocument.adaptationMode:
            guard let metadataLineage = UIPreviewLineage.parse(
                      artifact.metadata["ui_preview_lineage"]
                  ),
                  metadataLineage == document.lineage else {
                return false
            }
        case UIPreviewResultDocument.exploreMode:
            guard artifact.metadata["ui_preview_lineage"] == .null else {
                return false
            }
        default:
            return false
        }

        let fallbackID = document.fallbackAsset.assetID
        let expectedDigest = "sha256:" + document.fallbackAsset.sha256
        switch artifact.kind {
        case .interactiveHTML:
            guard artifact.fallback?.assetID == fallbackID,
                  let fallback = artifact.fallbackAsset,
                  fallback.sha256.lowercased() == expectedDigest,
                  fallback.mimeType.lowercased() == document.fallbackAsset.mimeType else {
                return false
            }
        case .staticImage:
            guard let fallback = artifact.assets.first(where: { $0.assetID == fallbackID }),
                  fallback.sha256.lowercased() == expectedDigest,
                  fallback.mimeType.lowercased() == document.fallbackAsset.mimeType else {
                return false
            }
        }
        return true
    }

    private static func correlatedArtifact(
        _ artifacts: [PreviewArtifact],
        tool: ToolNodePayload,
        document: UIPreviewResultDocument
    ) -> PreviewArtifact? {
        // A scripted or replayed runtime can reuse one call ID across turns
        // while the artifact keeps accumulating revisions. Pick the revision
        // this result actually describes — its lineage and fallback identity —
        // instead of the newest revision of the call, which would otherwise
        // take every earlier turn's card down with it on replay.
        artifacts
            .filter {
                $0.callID == tool.callID
                    && $0.title == document.title
                    && $0.kind.rawValue == document.kind
                    && $0.metadata["preview_mode"].string == document.mode
                    && validateArtifact($0, document: document, tool: tool)
            }
            .max { $0.revision < $1.revision }
    }

    private static func registeredFallbackAsset(
        _ descriptor: UIPreviewFallbackAsset,
        in tool: ToolNodePayload
    ) -> AgentAssetRef? {
        let matches = tool.assets.filter { $0.id == descriptor.assetID }
        guard matches.count == 1,
              let asset = matches.first,
              asset.kind == "image",
              asset.mimeType?.lowercased() == descriptor.mimeType,
              UILayoutActivityProjection.hasSafeWorkspaceRelativePath(asset),
              asset.workspaceRelativePath == descriptor.relativePath,
              asset.sourceCallID == nil || asset.sourceCallID == tool.callID else {
            return nil
        }
        return asset
    }

    // MARK: - Lineage assets

    /// Resolves the layout JSON and evidence JSON that belong to the lineage.
    /// Returns nil when a matching layout revision carries conflicting source
    /// or evidence identity, so a mismatched record cannot look authoritative.
    static func resolveRelatedAssets(
        lineage: UIPreviewLineage,
        turns: [ConversationTurn]
    ) -> RelatedAssets? {
        var layoutJSON: AgentAssetRef?
        var evidenceJSON: AgentAssetRef?
        var foundLayout = false

        for turn in turns.reversed() {
            for block in turn.blocks.reversed() {
                guard case .toolGroup(let group) = block else { continue }
                for tool in group.tools.reversed() {
                    if !foundLayout,
                       let validated = UILayoutActivityProjection.validatedLayoutRevision(
                           in: tool
                       ),
                       validated.document.artifactID == lineage.layoutArtifactID,
                       validated.document.revision == lineage.layoutRevision,
                       validated.document.revisionSHA256 == lineage.layoutRevisionSHA256 {
                        guard validated.document.sourceAssetID == lineage.sourceAssetID,
                              validated.document.sourceAssetSHA256 == lineage.sourceAssetSHA256,
                              validated.document.evidenceSHA256 == lineage.evidenceSHA256 else {
                            return nil
                        }
                        layoutJSON = validated.layoutJSON
                        foundLayout = true
                    }
                    if evidenceJSON == nil {
                        evidenceJSON = evidenceAsset(in: tool, lineage: lineage)
                    }
                }
            }
        }
        return RelatedAssets(layoutJSON: layoutJSON, evidenceJSON: evidenceJSON)
    }

    private static func evidenceAsset(
        in tool: ToolNodePayload,
        lineage: UIPreviewLineage
    ) -> AgentAssetRef? {
        guard let evidenceSHA256 = lineage.evidenceSHA256 else { return nil }
        return tool.assets.first { asset in
            guard asset.kind == "file",
                  asset.mimeType?.lowercased() == "application/json",
                  UILayoutActivityProjection.hasSafeWorkspaceRelativePath(asset),
                  let metadata = asset.metadata,
                  metadata["asset_role"]?.string == "evidence",
                  metadata["evidence_sha256"]?.string == evidenceSHA256,
                  metadata["source_asset_id"]?.string == lineage.sourceAssetID else {
                return false
            }
            return true
        }
    }

    private static func statusLabel(_ state: PreviewPresentationState) -> String {
        switch state {
        case .loading: return "生成中"
        case .interactiveReady: return "预览就绪"
        case .staticFallback: return "静态证据"
        case .unavailable: return "不可用"
        case .renderFailed: return "渲染失败"
        case .expired: return "已过期"
        }
    }

    private static func tone(_ state: PreviewPresentationState) -> String {
        switch state {
        case .interactiveReady: return "success"
        case .staticFallback: return "info"
        case .expired: return "warning"
        case .unavailable, .renderFailed: return "danger"
        case .loading: return "neutral"
        }
    }

    private static func compactDisplayName(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = singleLine.isEmpty ? "ui-preview" : singleLine
        return value.count <= 160 ? value : String(value.prefix(157)) + "…"
    }
}
