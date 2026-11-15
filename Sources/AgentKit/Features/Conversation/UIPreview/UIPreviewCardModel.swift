//
//  UIPreviewCardModel.swift
//  AgentKit
//
//  Native timeline projection for `ui_preview_result.v1`. This is the same
//  validated projection the Web workbench consumes (`UIPreviewActivityProjection`),
//  reshaped into a renderer-neutral value so the iOS SwiftUI timeline can show
//  the card without depending on the Web document types.
//

import ClientToolProtocol
import Foundation

struct UIPreviewCardModel: Equatable, Identifiable {
    struct Fallback: Equatable {
        let assetID: String
        let displayName: String
        let mimeType: String?
        let width: Int?
        let height: Int?
        let sha256: String?
    }

    struct Lineage: Equatable {
        let layoutArtifactID: String
        let layoutRevision: Int
        let layoutRevisionSHA256: String
        let sourceAssetID: String
        let sourceAssetSHA256: String
        let evidenceSHA256: String?
        let target: String
        let state: String
        let targetMatrixID: String
        let targetMatrixTargets: [String]
        let approvalState: String
        let approvalEvidenceRef: String?
    }

    let callID: String
    let title: String
    let mode: String
    let modeLabel: String
    let artifactKey: String
    let artifactID: String
    let revision: Int
    let revisionSHA256: String
    let kind: String
    let presentationState: String
    let runtimeStatus: String
    let statusLabel: String
    let tone: String
    let fallbackText: String?
    let minHeight: Int?
    let preferredAspectRatio: Double?
    let fallback: Fallback
    let lineage: Lineage?
    let layoutJSON: AgentAssetRef?
    let evidenceJSON: AgentAssetRef?

    /// One Block per preview revision, even if the same tool result is fed
    /// twice by a live+replay merge.
    var id: String { "\(callID)#\(artifactID)r\(revision)" }

    var isAdaptation: Bool { mode == UIPreviewResultDocument.adaptationMode }
    var isInteractiveReady: Bool { presentationState == "interactiveReady" }

    init(
        callID: String,
        projected: ConversationWebDocument.UIPreview,
        related: UIPreviewActivityProjection.RelatedAssets?
    ) {
        self.callID = callID
        title = projected.title
        mode = projected.mode
        modeLabel = projected.modeLabel
        artifactKey = projected.artifactKey
        artifactID = projected.artifactID
        revision = projected.revision
        revisionSHA256 = projected.revisionSHA256
        kind = projected.kind
        presentationState = projected.presentationState
        runtimeStatus = projected.runtimeStatus
        statusLabel = projected.statusLabel
        tone = projected.tone
        fallbackText = projected.fallbackText
        minHeight = projected.minHeight
        preferredAspectRatio = projected.preferredAspectRatio
        fallback = Fallback(
            assetID: projected.fallback.assetID,
            displayName: projected.fallback.displayName,
            mimeType: projected.fallback.mimeType,
            width: projected.fallback.width,
            height: projected.fallback.height,
            sha256: projected.fallback.sha256
        )
        lineage = projected.lineage.map { lineage in
            Lineage(
                layoutArtifactID: lineage.layoutArtifactID,
                layoutRevision: lineage.layoutRevision,
                layoutRevisionSHA256: lineage.layoutRevisionSHA256,
                sourceAssetID: lineage.sourceAssetID,
                sourceAssetSHA256: lineage.sourceAssetSHA256,
                evidenceSHA256: lineage.evidenceSHA256,
                target: lineage.target,
                state: lineage.state,
                targetMatrixID: lineage.targetMatrixID,
                targetMatrixTargets: lineage.targetMatrixTargets,
                approvalState: lineage.approvalState,
                approvalEvidenceRef: lineage.approvalEvidenceRef
            )
        }
        layoutJSON = related?.layoutJSON
        evidenceJSON = related?.evidenceJSON
    }
}

enum UIPreviewCardModelBuilder {
    /// Projects every `ui_preview_result.v1` tool in one turn. A result whose
    /// artifact is missing, mismatched, or whose adaptation lineage cannot be
    /// resolved produces no card, exactly like the Web renderer.
    static func models(
        turn: ConversationTurn,
        allTurns: [ConversationTurn],
        previewArtifacts: [PreviewArtifact],
        conversationID: String?
    ) -> [UIPreviewCardModel] {
        let scoped = conversationID.map { id in
            previewArtifacts.filter { $0.sessionID == id }
        } ?? previewArtifacts
        guard !scoped.isEmpty else { return [] }

        let assetIndex = AssetIndex(turn: turn)
        var models: [UIPreviewCardModel] = []
        var seen = Set<String>()
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools {
                guard let projected = UIPreviewActivityProjection.make(
                    tool: tool,
                    turnID: turn.id,
                    previewArtifacts: scoped,
                    turns: allTurns,
                    assetIndex: assetIndex,
                    registerAction: nil
                ) else {
                    continue
                }
                let related = UIPreviewActivityProjection.relatedAssets(
                    in: tool,
                    turns: allTurns
                )
                let model = UIPreviewCardModel(
                    callID: tool.callID,
                    projected: projected,
                    related: related
                )
                guard seen.insert(model.id).inserted else { continue }
                models.append(model)
            }
        }
        return models
    }
}
