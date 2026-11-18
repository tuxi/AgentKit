//
//  ConversationWebDocument.swift
//  AgentKit
//
//  Versioned, presentation-only payload sent to the bundled Web renderer.
//

import Foundation
import ClientToolProtocol

struct ConversationWebDocument: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let revision: UInt64
    let conversationID: String
    let todos: [Todo]
    let turns: [Turn]
    let live: LiveState?

    struct Todo: Codable, Equatable, Sendable {
        let content: String
        let activeForm: String?
        let status: String
    }

    /// What a turn wrote to disk, as reported by the Runtime (`diffstat`).
    /// Mirrors the core `TurnChanges` but only carries what the renderer needs.
    struct WebTurnChanges: Codable, Equatable, Sendable {
        struct File: Codable, Equatable, Sendable {
            let path: String
            let added: Int
            let removed: Int
            let status: String
        }
        /// Capped by the Runtime (200). May be shorter than `filesChanged`.
        let files: [File]
        let filesChanged: Int
        let addedLines: Int
        let removedLines: Int
        /// "编辑 3 个文件" — appended to the collapsed turn summary.
        let summary: String?

        init?(_ changes: TurnChanges?) {
            guard let changes, !changes.isEmpty else { return nil }
            self.files = changes.files.map {
                File(path: $0.path, added: $0.added,
                     removed: $0.removed, status: $0.status.rawValue)
            }
            self.filesChanged = changes.filesChanged
            self.addedLines = changes.addedLines
            self.removedLines = changes.removedLines
            self.summary = changes.summaryLabel
        }
    }

    struct Turn: Codable, Equatable, Sendable {
        let id: String
        let userPrompt: String?
        let userAssets: [UserAsset]
        let localAssets: [LocalAsset]
        var fileReferences: [ComposerFileReference]? = nil
        var composerPayloadDigest: String? = nil
        let blocks: [Block]
        /// First-class preview cards associated with this turn. Nil/empty keeps
        /// older encoded documents and preview-free turns byte-compatible.
        let previews: [Preview]?
        let todos: [Todo]
        let extensionNodes: [ExtensionNode]
        let footer: Footer?
        let isLive: Bool
        let copyActionID: String?
        let shareActionID: String?
        let assetsActionID: String?
        let assetCount: Int
        /// 按轮 Fork 入口（`conversation_fork_through_turn_v1`）。Present only when
        /// the Runtime advertises the capability and the turn is not live.
        let forkActionID: String?
        /// Wall-clock duration of the turn ("24分40秒"). Nil while live or when
        /// the timestamps are unknown — drives the collapsed process summary.
        let elapsedText: String?
        /// `HH:mm` the turn ended, rendered next to the turn actions.
        let finishedAtClock: String?
        /// Epoch milliseconds the turn started. While the turn is live the
        /// renderer ticks "已处理 8分15秒" from this anchor; the value is also
        /// present after completion but unused then.
        var startedAtMilliseconds: Int64? = nil
        /// What this turn wrote. Nil when the Runtime reported no diffstat —
        /// absence means "unknown", never "edited 0 files".
        var changes: WebTurnChanges? = nil
        /// The model that produced the final answer (`model_request`, v1.4).
        /// Nil for old streams — the badge is omitted, never "unknown".
        var model: String? = nil
        var modelRoute: String? = nil
        var processFailureText: String? = nil
        var userCopyActionID: String? = nil
    }

    /// Presentation-only projection of a PreviewArtifact. Model-authored HTML
    /// is intentionally absent here; A4 renders only the generic card.
    struct Preview: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let artifactID: String
        let revision: Int
        let kind: String
        let title: String
        let summary: String?
        let presentationState: String
        let runtimeStatus: String
        let statusLabel: String
        let tone: String
        let capability: String
        let fallbackText: String?
        let fallbackAssetID: String?
        let fallbackAlt: String?
        let degradedReason: String?
        let errorCode: String?
        let initialState: String
        let expiresAtMilliseconds: Int64?
        let minHeight: Int?
        let preferredAspectRatio: Double?
    }

    struct UserAsset: Codable, Equatable, Sendable {
        let assetID: Int64
        let filename: String
        let mimeType: String
        let previewURL: String?
    }

    struct LocalAsset: Codable, Equatable, Sendable {
        let id: String
        let relativePath: String
        let filename: String
        let mimeType: String
        let kind: String
        let sizeBytes: Int64
        let previewURL: String?
        let transferPolicy: String
    }

    struct Block: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case markdown
            case thinking
            case toolGroup
            case artifact
            case system
            case childStream
        }

        let id: String
        let kind: Kind
        let text: String?
        let title: String?
        let status: String?
        let elapsed: String?
        let tools: [Tool]
        /// Present only for child-stream entry rows. The parent timeline uses
        /// this to distinguish task subagents from background jobs without
        /// embedding the child stream's result in the main document.
        let childStreamKind: String?
        let actionID: String?
        let actionTooltip: String?
        let inlineActions: [InlineAction]
        let codeCopyActionIDs: [String]
        /// Ordered references into tools and activityThinking. Nil denotes the
        /// legacy tool-only presentation, preserving compatibility for callers.
        var statusText: String? = nil
        var isCollecting: Bool? = nil
        var activityOrder: [String]? = nil
        var activityThinking: [Block]? = nil
        var activityJobs: [Block]? = nil
        var outcome: TurnOutcomePresentation? = nil
        var contextMaintenance: ContextMaintenancePresentation? = nil
        /// State-based activity summary used for expanded live groups and for
        /// completed groups. Unlike `title`, it never mirrors one child row.
        var activitySummary: String? = nil
        var failureText: String? = nil
        var startedAtMilliseconds: Double? = nil
        var finishedAtMilliseconds: Double? = nil
        /// Raw SystemNodeKind; absent/other kinds render as a plain system aside.
        var systemKind: String? = nil
        /// Present only for system blocks: kind-specific flags and values from
        /// the graph node payload (e.g. `ineffective`, token counts).
        var metadata: [String: String]? = nil
    }

    /// Presentation-only projection of `view_image_result.v1`. Asset order is
    /// the structured `assets[]` order; relationships are IDs, never paths.
    struct ImageView: Codable, Equatable, Sendable {
        let title: String
        let displayName: String
        let sourceAssetID: String
        let cropAssetID: String?
        let detailRequested: String
        let detailEffective: String
        let sourceRegion: ImageRegion?
        let assets: [ImageViewAsset]
    }

    struct ImageViewAsset: Codable, Equatable, Sendable, Identifiable {
        var id: String { assetID }
        let assetID: String
        let role: String
        let displayName: String
        let width: Int
        let height: Int
        let sourceAssetID: String?
        let sourceRegion: ImageRegion?
        let viewActionID: String?
    }

    struct ImageRegion: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Presentation-only projection of `ui_evidence.v1`. OCR and source-tree
    /// text remain untrusted data: the renderer only displays it as text.
    struct UIEvidence: Codable, Equatable, Sendable {
        let title: String
        let displayName: String
        let sourceAssetID: String
        let sourceTreeKind: String
        let sourceTreeNote: String?
        let producer: String
        let summary: UIEvidenceSummary
        let assets: [UIEvidenceAsset]
        let ocrPreview: [UIEvidenceTextItem]
        let repeatedGroups: [UIEvidenceGroup]
        let uncertainties: [UIEvidenceNote]
        let warnings: [String]
        let limits: [String]
        let rawActionID: String?
    }

    struct UIEvidenceSummary: Codable, Equatable, Sendable {
        let textElements: Int
        let containers: Int
        let repeatedGroups: Int
        let crops: Int
        let observed: Int
        let inferred: Int
        let uncertain: Int
        let uncertainties: Int
        let warnings: Int
    }

    struct UIEvidenceAsset: Codable, Equatable, Sendable, Identifiable {
        var id: String { assetID }
        let assetID: String
        let role: String
        let displayName: String
        let width: Int
        let height: Int
        let sourceAssetID: String?
        let sourceBBox: ImageRegion?
        let purpose: String?
        let viewActionID: String?
    }

    struct UIEvidenceTextItem: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let bbox: ImageRegion
        let confidence: Double
        let evidence: String
    }

    struct UIEvidenceGroup: Codable, Equatable, Sendable {
        let id: String
        let axis: String
        let memberIDs: [String]
        let bbox: ImageRegion
        let confidence: Double
        let evidence: String
    }

    struct UIEvidenceNote: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let reason: String?
    }

    /// Presentation-only projection of `ui_layout_result.v1`. Bound to the
    /// persisted revision and its two canonical assets; the layout JSON body
    /// itself never enters the transcript document.
    struct UILayout: Codable, Equatable, Sendable {
        let title: String
        let artifactID: String
        let revision: Int
        let revisionSHA256: String
        let sourceAssetID: String
        let sourceAssetSHA256: String
        let evidenceSHA256: String?
        let canvasWidth: Int
        let canvasHeight: Int
        let nodeCount: Int
        let assumptionCount: Int
        let targets: [String]
        let created: Bool
        let overlay: UILayoutAsset
        let layoutJSON: UILayoutAsset
        let rawActionID: String?
    }

    struct UILayoutAsset: Codable, Equatable, Sendable, Identifiable {
        var id: String { assetID }
        let assetID: String
        let role: String
        let displayName: String
        let width: Int?
        let height: Int?
        let viewActionID: String?
    }

    /// Presentation-only projection of `ui_preview_result.v1`. The result
    /// supplies mode and lineage; the correlated preview artifact supplies
    /// runtime identity. No viewer HTML or workspace path enters this model.
    struct UIPreview: Codable, Equatable, Sendable {
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
        let fallback: UIPreviewAsset
        let lineage: UIPreviewLineage?
        let layoutJSON: UIPreviewRelatedAsset?
        let evidenceJSON: UIPreviewRelatedAsset?
        let rawActionID: String?
    }

    struct UIPreviewAsset: Codable, Equatable, Sendable, Identifiable {
        var id: String { assetID }
        let assetID: String
        let role: String
        let displayName: String
        let mimeType: String?
        let width: Int?
        let height: Int?
        let sha256: String?
        let viewActionID: String?
    }

    struct UIPreviewRelatedAsset: Codable, Equatable, Sendable, Identifiable {
        var id: String { assetID }
        let assetID: String
        let displayName: String
        let viewActionID: String?
    }

    struct UIPreviewLineage: Codable, Equatable, Sendable {
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

    struct Tool: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let status: String
        let statusText: String?
        let detail: String?
        let elapsed: String?
        let changeSummary: String?
        let arguments: String?
        let output: String?
        let artifactActionID: String?
        let assetActions: [ActionItem]
        let copyOutputActionID: String?
        let argumentActions: [InlineAction]
        let outputActions: [InlineAction]
        /// Non-nil when tool output contains a DAG definition.
        let dagNodes: Int?
        /// Number of edges in the DAG (when dagNodes is non-nil).
        let dagEdges: Int?
        /// Action to open the workflow DAG detail (when workflow_id is present).
        let dagOpenActionID: String?
        var backgroundJobID: String? = nil
        var rawName: String? = nil
        var icon: String? = nil
        var labels: [String: String]? = nil
        var command: String? = nil
        var input: String? = nil
        var inputContext: String? = nil
        var hasResult: Bool? = nil
        var copyInputActionID: String? = nil
        var fullOutputActionID: String? = nil
        var inputIsPreview: Bool? = nil
        var inputIsRedacted: Bool? = nil
        var commandActions: [InlineAction]? = nil
        var resultKind: String? = nil
        var outcomeText: String? = nil
        var outcomeTone: String? = nil
        /// Generic image-view semantic derived from structured output. Nil is
        /// the safe fallback for malformed metadata or missing tool assets.
        var imageView: ImageView? = nil
        /// Generic `ui_evidence.v1` semantic selected by output schema only.
        /// Malformed documents or unregistered assets fall back to the ordinary
        /// tool card and raw structured output.
        var uiEvidence: UIEvidence? = nil
        /// Generic `ui_layout_result.v1` semantic selected by output schema
        /// only. Malformed documents or unregistered assets fall back to the
        /// ordinary tool card and raw structured output.
        var uiLayout: UILayout? = nil
        /// Generic `ui_preview_result.v1` semantic selected by output schema
        /// only. The card is shown only when a correlated preview artifact and
        /// a valid v2 lineage (for adaptation) are present.
        var uiPreview: UIPreview? = nil
    }

    struct InlineAction: Codable, Equatable, Sendable {
        let text: String
        let actionID: String
        let tooltip: String
    }

    struct ActionItem: Codable, Equatable, Sendable {
        let title: String
        let actionID: String
        let tooltip: String?
        let focusID: String?
    }

    struct ExtensionNode: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let summary: String?
        let status: String?
        let tone: String
        let badges: [ExtensionBadge]
        let sections: [ExtensionSection]
        let actions: [ActionItem]
        let footer: String?
    }

    struct ExtensionBadge: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let tone: String
    }

    struct ExtensionSection: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let summary: String?
        let status: String?
        let rows: [ExtensionRow]
        let initiallyExpanded: Bool
    }

    struct ExtensionRow: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    struct Footer: Codable, Equatable, Sendable {
        let totalTokens: String
        let contextTokens: String?
        let usageUnits: String?
        let elapsed: String
        let invocationCount: Int
        /// P8.9 — last invocation's cache-hit tokens ("12.1K"), nil when none.
        let cachedTokens: String?
    }

    struct LiveState: Codable, Equatable, Sendable {
        let isThinking: Bool
        let startedAtMilliseconds: Int64?
        let modelRetrying: ModelRetryState?
        var waitingReason: String? = nil
    }
}

@MainActor
enum ConversationWebDocumentBuilder {
    struct ReuseSource {
        let snapshot: RuntimeSnapshot
        let document: ConversationWebDocument
        let extensionContributions: [String: [TimelineWebContribution]]
    }

    /// Result of a build: the document plus the set of turn ids whose content
    /// was reused verbatim from the reuse source (content version matched).
    /// The differ uses this set to skip unchanged turns in O(1).
    struct BuildResult {
        let document: ConversationWebDocument
        let stableTurnIDs: Set<String>
    }

    static func build(
        snapshot: RuntimeSnapshot,
        composerPresentations: [String: ComposerMessagePresentation] = [:],
        conversationID: String?,
        revision: UInt64? = nil,
        extensionContributions: [String: [TimelineWebContribution]] = [:],
        reusing reuseSource: ReuseSource? = nil,
        supportsForkThroughTurn: Bool = false,
        assetIndexFactory: (ConversationTurn) -> AssetIndex = { AssetIndex(turn: $0) },
        registerAction: ((ConversationWebAction) -> String)? = nil
    ) -> ConversationWebDocument {
        buildResult(
            snapshot: snapshot,
            composerPresentations: composerPresentations,
            conversationID: conversationID,
            revision: revision,
            extensionContributions: extensionContributions,
            reusing: reuseSource,
            supportsForkThroughTurn: supportsForkThroughTurn,
            assetIndexFactory: assetIndexFactory,
            registerAction: registerAction
        ).document
    }

    /// Build and also report which turns were reused verbatim from the reuse
    /// source (content version matched). The streaming Coordinator uses this
    /// to let the differ skip unchanged turns in O(1).
    static func buildWithStableTurns(
        snapshot: RuntimeSnapshot,
        composerPresentations: [String: ComposerMessagePresentation] = [:],
        conversationID: String?,
        revision: UInt64? = nil,
        extensionContributions: [String: [TimelineWebContribution]] = [:],
        reusing reuseSource: ReuseSource? = nil,
        supportsForkThroughTurn: Bool = false,
        assetIndexFactory: (ConversationTurn) -> AssetIndex = { AssetIndex(turn: $0) },
        registerAction: ((ConversationWebAction) -> String)? = nil
    ) -> BuildResult {
        buildResult(
            snapshot: snapshot,
            composerPresentations: composerPresentations,
            conversationID: conversationID,
            revision: revision,
            extensionContributions: extensionContributions,
            reusing: reuseSource,
            supportsForkThroughTurn: supportsForkThroughTurn,
            assetIndexFactory: assetIndexFactory,
            registerAction: registerAction
        )
    }

    private static func buildResult(
        snapshot: RuntimeSnapshot,
        composerPresentations: [String: ComposerMessagePresentation],
        conversationID: String?,
        revision: UInt64?,
        extensionContributions: [String: [TimelineWebContribution]],
        reusing reuseSource: ReuseSource?,
        supportsForkThroughTurn: Bool,
        assetIndexFactory: (ConversationTurn) -> AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> BuildResult {
        var stableTurnIDs = Set<String>()
        let document = ConversationWebDocument(
            protocolVersion: ConversationWebDocument.currentProtocolVersion,
            revision: revision ?? snapshot.generation,
            conversationID: conversationID ?? "unbound",
            // Compatibility field for an already-loaded v1 shell. Task state
            // is now owned and rendered by its originating turn.
            todos: [],
            turns: snapshot.turns.enumerated().map { index, turn in
                let contributions = extensionContributions[turn.id] ?? []
                let turnPreviewArtifacts = previewArtifacts(
                    from: snapshot.previewArtifactHistory,
                    for: turn
                )
                // A ui_preview tool result renders its own card. Suppressing the
                // generic preview card for the same artifact keeps one preview
                // revision to exactly one Block, even when projection fails.
                let uiPreviewCallIDs = Self.uiPreviewResultCallIDs(in: turn)
                let previews = turnPreviewArtifacts.filter { artifact in
                    guard let callID = artifact.callID else { return true }
                    return !uiPreviewCallIDs.contains(callID)
                }.map(makePreview)
                let previousTurn = reuseSource.flatMap {
                    index < $0.snapshot.turns.count ? $0.snapshot.turns[index] : nil
                }
                let previousDocumentTurn = reuseSource.flatMap {
                    index < $0.document.turns.count ? $0.document.turns[index] : nil
                }
                let presentation = composerPresentations[turn.runtimeTurnID].flatMap { candidate -> ComposerMessagePresentation? in
                    guard let prompt = turn.userPrompt else { return nil }
                    // Stream deltas leave the user prompt unchanged. Reuse an
                    // already verified presentation instead of rehashing it.
                    if previousTurn?.id == turn.id, previousTurn?.userPrompt == prompt,
                       previousDocumentTurn?.composerPayloadDigest == candidate.payloadDigest,
                       previousDocumentTurn?.userPrompt == candidate.text,
                       previousDocumentTurn?.fileReferences == candidate.fileReferences {
                        return candidate
                    }
                    return candidate.matches(prompt.text) ? candidate : nil
                }
                // ui_preview tool cards read preview artifacts and assets from
                // outside the turn, so a reused turn could hold a stale card
                // when an artifact arrives after the tool result.
                if let previousTurn,
                   previousDocumentTurn?.id == turn.id,
                   uiPreviewCallIDs.isEmpty,
                   previousDocumentTurn?.userPrompt == (presentation?.text ?? turn.userPrompt?.text),
                   previousDocumentTurn?.fileReferences == presentation?.fileReferences,
                   (reuseSource?.extensionContributions[turn.id] ?? []) == contributions,
                   (previousDocumentTurn?.previews ?? []) == previews,
                   isContentUnchanged(previousTurn, turn) {
                    stableTurnIDs.insert(turn.id)
                    return previousDocumentTurn!
                }
                return makeTurn(
                    turn,
                    presentation: presentation,
                    previews: previews,
                    previewArtifacts: turnPreviewArtifacts,
                    allTurns: snapshot.turns,
                    extensionContributions: contributions,
                    previousTurn: previousTurn?.id == turn.id ? previousTurn : nil,
                    previousDocumentTurn: previousDocumentTurn?.id == turn.id
                        ? previousDocumentTurn
                        : nil,
                    supportsForkThroughTurn: supportsForkThroughTurn,
                    assetIndexFactory: assetIndexFactory,
                    registerAction: registerAction
                )
            },
            live: makeLiveState(snapshot)
        )
        return BuildResult(document: document, stableTurnIDs: stableTurnIDs)
    }

    /// O(1) when both turns carry a projection content version (non-zero);
    /// falls back to deep equality for hand-built turns (tests, shares) where
    /// the version is 0 and carries no meaning.
    private static func isContentUnchanged(
        _ lhs: ConversationTurn,
        _ rhs: ConversationTurn
    ) -> Bool {
        if lhs.contentVersion > 0, rhs.contentVersion > 0 {
            return lhs.contentVersion == rhs.contentVersion
        }
        return lhs == rhs
    }

    static func actionTokens(in document: ConversationWebDocument) -> Set<String> {
        var tokens = Set<String>()
        for turn in document.turns {
            if let token = turn.copyActionID { tokens.insert(token) }
            if let token = turn.userCopyActionID { tokens.insert(token) }
            if let token = turn.shareActionID { tokens.insert(token) }
            if let token = turn.assetsActionID { tokens.insert(token) }
            if let token = turn.forkActionID { tokens.insert(token) }
            for block in turn.blocks {
                if let token = block.actionID { tokens.insert(token) }
                tokens.formUnion((block.activityJobs ?? []).compactMap(\.actionID))
                tokens.formUnion(block.codeCopyActionIDs)
                tokens.formUnion(block.inlineActions.map(\.actionID))
                for tool in block.tools {
                    if let token = tool.artifactActionID { tokens.insert(token) }
                    if let token = tool.copyOutputActionID { tokens.insert(token) }
                    if let token = tool.copyInputActionID { tokens.insert(token) }
                    if let token = tool.fullOutputActionID { tokens.insert(token) }
                    tokens.formUnion((tool.commandActions ?? []).map(\.actionID))
                    if let token = tool.dagOpenActionID { tokens.insert(token) }
                    tokens.formUnion(tool.assetActions.map(\.actionID))
                    tokens.formUnion(tool.argumentActions.map(\.actionID))
                    tokens.formUnion(tool.outputActions.map(\.actionID))
                }
            }
            for node in turn.extensionNodes {
                tokens.formUnion(node.actions.map(\.actionID))
            }
        }
        return tokens
    }

    private static func makeTurn(
        _ turn: ConversationTurn,
        presentation: ComposerMessagePresentation?,
        previews: [ConversationWebDocument.Preview],
        previewArtifacts: [PreviewArtifact],
        allTurns: [ConversationTurn],
        extensionContributions: [TimelineWebContribution],
        previousTurn: ConversationTurn?,
        previousDocumentTurn: ConversationWebDocument.Turn?,
        supportsForkThroughTurn: Bool,
        assetIndexFactory: (ConversationTurn) -> AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.Turn {
        var cachedAssetIndex: AssetIndex?
        func assetIndex() -> AssetIndex {
            if let cachedAssetIndex { return cachedAssetIndex }
            let index = assetIndexFactory(turn)
            cachedAssetIndex = index
            return index
        }
        // A ui_preview tool card reads the preview artifact and related assets
        // from outside the turn. Never reuse its block or tool projections: a
        // later artifact event must be able to replace the ordinary card.
        let containsUIPreviewResults = !uiPreviewResultCallIDs(in: turn).isEmpty
        // Turn-level asset actions are hidden while live. Defer collecting and
        // deduplicating the entire turn until the terminal revision.
        let assets = turn.isLive ? [] : turnAssets(turn)
        let copyActionID = turn.isLive ? nil : registerAction.map { registerAction in
            let copyText = TranscriptCache.shared.transcript(
                for: turn,
                state: TranscriptDocumentState()
            ).copyText
            return registerAction(.transcript(
                turnID: turn.id,
                action: .copyBlock(text: copyText)
            ))
        }
        return ConversationWebDocument.Turn(
            id: turn.id,
            userPrompt: presentation?.text ?? turn.userPrompt?.text,
            userAssets: turn.userPrompt?.userAssets.map { asset in
                ConversationWebDocument.UserAsset(
                    assetID: asset.assetID,
                    filename: asset.filename,
                    mimeType: asset.mimeType,
                    previewURL: nil  // Phase 2: 宿主 app resolve gateway 签名 URL 后注入
                )
            } ?? [],
            localAssets: turn.userPrompt?.localAssets.map { asset in
                ConversationWebDocument.LocalAsset(
                    id: asset.id,
                    relativePath: asset.relativePath,
                    filename: asset.filename,
                    mimeType: asset.mimeType,
                    kind: asset.kind,
                    sizeBytes: asset.sizeBytes,
                    previewURL: nil,
                    transferPolicy: asset.transferPolicy.rawValue
                )
            } ?? [],
            fileReferences: presentation?.fileReferences,
            composerPayloadDigest: presentation?.payloadDigest,
            blocks: turn.blocks.enumerated().map { blockIndex, block in
                let previousBlock = previousTurn.flatMap {
                    blockIndex < $0.blocks.count ? $0.blocks[blockIndex] : nil
                }
                let previousWebBlock = previousDocumentTurn.flatMap {
                    blockIndex < $0.blocks.count ? $0.blocks[blockIndex] : nil
                }
                if !containsUIPreviewResults,
                   previousBlock == block,
                   previousWebBlock?.id == block.id {
                    return previousWebBlock!
                }
                return makeBlock(
                    block,
                    turn: turn,
                    previewArtifacts: previewArtifacts,
                    allTurns: allTurns,
                    previousBlock: previousBlock,
                    previousWebBlock: previousWebBlock,
                    assetIndex: assetIndex,
                    registerAction: registerAction
                )
            },
            previews: previews.isEmpty ? nil : previews,
            todos: turn.todos.map {
                ConversationWebDocument.Todo(
                    content: $0.content,
                    activeForm: $0.activeForm,
                    status: $0.status.rawValue
                )
            },
            extensionNodes: extensionContributions.map {
                makeExtensionNode($0, turnID: turn.id, registerAction: registerAction)
            },
            footer: turn.footer.map {
                ConversationWebDocument.Footer(
                    totalTokens: $0.hasTokenUsage ? String(format: "%.1fK", Double($0.totalTokens) / 1_000) : "—",
                    contextTokens: $0.contextTokens > 0 ? $0.formattedContextTokens : nil,
                    usageUnits: $0.hasUsageUnits ? $0.formattedUsageUnits : nil,
                    elapsed: $0.formattedElapsed,
                    invocationCount: $0.invocationCount,
                    cachedTokens: $0.hasCachedTokens
                        ? String(format: "%.1fK", Double($0.cachedContextTokens) / 1_000) : nil
                )
            },
            isLive: turn.isLive,
            copyActionID: copyActionID,
            shareActionID: turn.isLive ? nil : registerAction.map {
                $0(.shareTurn(turnID: turn.id))
            },
            assetsActionID: turn.isLive || assets.isEmpty ? nil : registerAction.map {
                $0(.showTurnAssets(turnID: turn.id))
            },
            assetCount: assets.count,
            forkActionID: (!supportsForkThroughTurn || turn.isLive) ? nil : registerAction.map {
                $0(.transcript(turnID: turn.id, action: .forkConversation(turnID: turn.id)))
            },
            elapsedText: turn.formattedDuration,
            finishedAtClock: turn.finishedAtClock,
            startedAtMilliseconds: turn.startedAtMilliseconds,
            changes: ConversationWebDocument.WebTurnChanges(turn.changes),
            model: turn.modelName,
            modelRoute: turn.modelRoute,
            processFailureText: turn.processFailureSummary,
            userCopyActionID: (presentation?.text ?? turn.userPrompt?.text).flatMap { text in
                registerAction?(.transcript(turnID: turn.id, action: .copyBlock(text: text)))
            }
        )
    }

    static let previewNegotiation = PreviewCapabilityNegotiation(
        hello: PreviewCapability.allCases.map(\.rawValue),
        runtime: PreviewCapability.allCases.map(\.rawValue),
        client: .previewClient
    )

    /// Tool results that own a `ui_preview_result.v1` structured output. Their
    /// correlated preview artifact is rendered by the tool card, so the turn
    /// must not render the generic preview card for the same artifact.
    private static func isUIPreviewResultTool(_ tool: ToolNodePayload) -> Bool {
        tool.structuredOutput?["schema"].string == "ui_preview_result.v1"
    }

    private static func uiPreviewResultCallIDs(in turn: ConversationTurn) -> Set<String> {
        var callIDs = Set<String>()
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools where isUIPreviewResultTool(tool) {
                callIDs.insert(tool.callID)
            }
        }
        return callIDs
    }

    private static func previewArtifacts(
        from artifacts: [PreviewArtifact],
        for turn: ConversationTurn
    ) -> [PreviewArtifact] {
        artifacts
            .filter { $0.turnID == turn.runtimeTurnID }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.artifactID < $1.artifactID
            }
    }

    private static func makePreview(_ artifact: PreviewArtifact) -> ConversationWebDocument.Preview {
        let state = artifact.presentationState(capabilities: previewNegotiation)
        let fallbackAsset = artifact.fallbackAsset
        let degradedReason: String?
        switch state {
        case .staticFallback:
            if artifact.kind == .interactiveHTML {
                degradedReason = artifact.error?.message
                    ?? "交互预览不可用，正在显示静态证据。"
            } else {
                degradedReason = artifact.error?.message
            }
        case .expired:
            degradedReason = "预览已过期，正在显示静态证据。"
        case .unavailable, .renderFailed:
            degradedReason = artifact.error?.message ?? "Preview unavailable."
        case .loading, .interactiveReady:
            degradedReason = nil
        }

        return ConversationWebDocument.Preview(
            id: artifact.artifactID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            kind: artifact.kind.rawValue,
            title: artifact.title,
            summary: artifact.summary,
            presentationState: state.rawValue,
            runtimeStatus: artifact.status.rawValue,
            statusLabel: previewStatusLabel(state),
            tone: previewTone(state),
            capability: artifact.capability,
            fallbackText: artifact.fallback?.text,
            fallbackAssetID: artifact.fallback?.assetID,
            fallbackAlt: fallbackAsset?.alt,
            degradedReason: degradedReason,
            errorCode: artifact.error?.code,
            initialState: artifact.presentation?.initialState ?? "collapsed",
            expiresAtMilliseconds: artifact.expiresAtDate.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            },
            minHeight: artifact.presentation?.minHeight,
            preferredAspectRatio: artifact.presentation?.preferredAspectRatio
        )
    }

    private static func previewStatusLabel(_ state: PreviewPresentationState) -> String {
        switch state {
        case .loading: return "生成中"
        case .interactiveReady: return "预览就绪"
        case .staticFallback: return "静态证据"
        case .unavailable: return "不可用"
        case .renderFailed: return "渲染失败"
        case .expired: return "已过期"
        }
    }

    private static func previewTone(_ state: PreviewPresentationState) -> String {
        switch state {
        case .interactiveReady: return "success"
        case .staticFallback: return "info"
        case .expired: return "warning"
        case .unavailable, .renderFailed: return "danger"
        case .loading: return "neutral"
        }
    }

    private static func makeExtensionNode(
        _ contribution: TimelineWebContribution,
        turnID: String,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.ExtensionNode {
        let node = contribution.node
        return .init(
            id: "\(contribution.extensionID):\(node.id)",
            title: node.title,
            summary: node.summary,
            status: node.status,
            tone: node.tone.rawValue,
            badges: node.badges.map {
                .init(id: $0.id, text: $0.text, tone: $0.tone.rawValue)
            },
            sections: node.sections.map { section in
                .init(
                    id: section.id,
                    title: section.title,
                    summary: section.summary,
                    status: section.status,
                    rows: section.rows.map {
                        .init(id: $0.id, label: $0.label, value: $0.value)
                    },
                    initiallyExpanded: section.initiallyExpanded
                )
            },
            actions: node.actions.compactMap { action in
                guard let registerAction else { return nil }
                let nativeAction: ConversationWebAction
                switch action.kind {
                case .extensionAction:
                    nativeAction = .timelineExtension(
                        extensionID: contribution.extensionID,
                        turnID: turnID,
                        actionID: action.id
                    )
                case .document:
                    guard let document = action.document else { return nil }
                    nativeAction = .timelineDocument(document)
                }
                return .init(
                    title: action.title,
                    actionID: registerAction(nativeAction),
                    tooltip: action.tooltip,
                    focusID: "extension:\(node.id):action:\(action.id)"
                )
            },
            footer: node.footer
        )
    }

    private static func makeBlock(
        _ block: TurnBlock,
        turn: ConversationTurn,
        previewArtifacts: [PreviewArtifact],
        allTurns: [ConversationTurn],
        previousBlock: TurnBlock?,
        previousWebBlock: ConversationWebDocument.Block?,
        assetIndex: () -> AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?,
        isGroupedJob: Bool = false
    ) -> ConversationWebDocument.Block {
        switch block {
        case .text(let id, let payload):
            return .init(
                id: id,
                kind: .markdown,
                text: payload.text,
                title: nil,
                status: payload.isStreaming ? "streaming" : nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                // The Web streaming player deliberately hides exact-text
                // actions until completion. Avoid scanning the growing text
                // and rebuilding AssetIndex for data the DOM will discard.
                inlineActions: payload.isStreaming ? [] : inlineActions(
                    text: payload.text,
                    annotations: payload.textAnnotations,
                    turnID: turn.id,
                    assetIndex: assetIndex,
                    registerAction: registerAction
                ),
                codeCopyActionIDs: payload.isStreaming ? [] : codeBlockCopyActions(
                    in: payload.text,
                    turnID: turn.id,
                    registerAction: registerAction
                )
            )

        case .thinking(let id, let payload):
            return .init(
                id: id,
                kind: .thinking,
                text: payload.text,
                title: ToolTranscriptText().thinkingTitle(streaming: payload.isStreaming),
                status: payload.isStreaming ? "streaming" : nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                inlineActions: [],
                codeCopyActionIDs: []
            )

        case .toolGroup(let group):
            let groupPresentation = ToolTranscriptPresenter.groupPresentation(for: group)
            let desktopText = ToolTranscriptText()
            let previousTools: [ToolNodePayload] = if case .toolGroup(let previousGroup) = previousBlock {
                previousGroup.tools
            } else {
                []
            }
            let previousWebTools = previousWebBlock?.kind == .toolGroup
                ? previousWebBlock?.tools ?? []
                : []
            let tools = group.tools.enumerated().map { toolIndex, tool -> ConversationWebDocument.Tool in
                if !isUIPreviewResultTool(tool),
                   toolIndex < previousTools.count,
                   toolIndex < previousWebTools.count,
                   previousTools[toolIndex] == tool,
                   previousWebTools[toolIndex].id == tool.callID {
                    return previousWebTools[toolIndex]
                }
                let previousTool = toolIndex < previousTools.count
                    ? previousTools[toolIndex]
                    : nil
                let previousWebTool = toolIndex < previousWebTools.count
                    ? previousWebTools[toolIndex]
                    : nil
                // Child rows keep the neutral action label. Running/completed
                // state belongs to the row badge and the group summary; adding
                // "running"/"done" prefixes here made expanded headers and rows
                // repeat the same information.
                let presentation = ToolTranscriptPresenter.presentation(for: tool)
                let command = ToolTranscriptPresenter.commandValue(for: tool)
                let commandForCard = command.map { value in
                    CommandDisplayRedactor.redact(value)
                }
                let resultKind: String = command != nil || presentation.family == .terminal ? "terminal"
                    : presentation.family == .search ? "search"
                    : [.read, .edit, .create].contains(presentation.family) ? "file" : "generic"
                let resultFailed = tool.status == .failed || (tool.exitCode.map { $0 != 0 } ?? false)
                let outcomeText: String? = resultFailed
                    ? tool.exitCode.map { ToolTranscriptText().text("failed.code", $0) } ?? ToolTranscriptText().text("failed")
                    : tool.status == .running && BackgroundJobPresentation.operation(tool.toolName) != "wait" ? ToolTranscriptText().text("running")
                    : resultKind == "terminal" ? ToolTranscriptText().text("run.succeeded") : nil
                let fullInput = MacToolPresentation.input(for: tool)
                let inputIsRedacted = command.map { CommandDisplayRedactor.redact($0) != $0 } ?? false
                let input = commandForCard ?? fullInput
                let fullOutputActionID: String?
                #if os(macOS)
                fullOutputActionID = registerAction.map { $0(.transcript(turnID: turn.id, action: .openToolResult(callID: tool.callID))) }
                #else
                fullOutputActionID = nil
                #endif
                let arguments = tool.args.flatMap(formattedJSON)
                let output = tool.output.isEmpty ? tool.structuredOutput.flatMap(formattedJSON) : tool.output
                // DAG detection for workflow tools (workflow_definition, etc.)
                let dag = tryParseDAG(from: tool.output)
                let dagOpenActionID: String? = dag?.workflowId.flatMap { wfID in
                    registerAction.map {
                        $0(.transcript(
                            turnID: turn.id,
                            action: .openWorkflow(workflowID: wfID)
                        ))
                    }
                }
                let uiPreview = UIPreviewActivityProjection.make(
                    tool: tool,
                    turnID: turn.id,
                    previewArtifacts: previewArtifacts,
                    turns: allTurns,
                    assetIndex: assetIndex(),
                    registerAction: registerAction
                )
                let uiLayout = uiPreview == nil ? UILayoutActivityProjection.make(
                    tool: tool,
                    turnID: turn.id,
                    assetIndex: assetIndex(),
                    registerAction: registerAction
                ) : nil
                let uiEvidence = uiPreview == nil && uiLayout == nil ? UIEvidenceActivityProjection.make(
                    tool: tool,
                    turnID: turn.id,
                    assetIndex: assetIndex(),
                    registerAction: registerAction
                ) : nil
                let imageView = uiPreview == nil && uiLayout == nil && uiEvidence == nil
                    ? ViewImageActivityProjection.make(
                        tool: tool,
                        turnID: turn.id,
                        assetIndex: assetIndex(),
                        registerAction: registerAction
                    ) : nil
                let hasStructuredActivity = imageView != nil || uiEvidence != nil
                    || uiLayout != nil || uiPreview != nil
                return ConversationWebDocument.Tool(
                    id: tool.callID,
                    name: uiPreview.map { "\($0.modeLabel): \($0.title)" }
                        ?? uiLayout?.title ?? uiEvidence?.title ?? imageView?.title
                        ?? MacToolPresentation.rowTitle(tool),
                    status: resultFailed ? "failed" : tool.status.rawValue,
                    statusText: presentation.statusText,
                    detail: hasStructuredActivity ? nil : presentation.detail,
                    elapsed: hasStructuredActivity ? nil : presentation.elapsed,
                    changeSummary: hasStructuredActivity ? nil : presentation.changeSummary,
                    arguments: arguments,
                    output: !hasStructuredActivity && dag == nil ? output : nil,
                    artifactActionID: hasStructuredActivity ? nil
                        : previousTool?.artifact == tool.artifact
                        ? previousWebTool?.artifactActionID
                        : tool.artifact.flatMap { _ in
                        registerAction.map {
                            $0(.transcript(
                                turnID: turn.id,
                                action: .openArtifact(callID: tool.callID)
                            ))
                        }
                    },
                    assetActions: hasStructuredActivity ? [] : previousTool?.assets == tool.assets
                        ? previousWebTool?.assetActions ?? []
                        : tool.assets.compactMap { asset in
                        guard let registerAction else { return nil }
                        let reference = assetIndex().reference(forStructuredAsset: asset)
                        return ConversationWebDocument.ActionItem(
                            title: asset.displayName ?? reference.display,
                            actionID: registerAction(.transcript(
                                turnID: turn.id,
                                action: .openAsset(reference)
                            )),
                            tooltip: reference.target,
                            focusID: "tool:\(tool.callID):asset:\(reference.id)"
                        )
                    },
                    copyOutputActionID: hasStructuredActivity || output == nil
                        ? nil
                        : registerAction.map {
                        $0(.transcript(
                            turnID: turn.id,
                            action: .copyBlock(text: output ?? "")
                        ))
                    },
                    argumentActions: previousTool?.args == tool.args
                        ? previousWebTool?.argumentActions ?? []
                        : arguments.map {
                        inlineActions(
                            text: $0,
                            annotations: [],
                            turnID: turn.id,
                            assetIndex: assetIndex,
                            registerAction: registerAction
                        )
                    } ?? [],
                    outputActions: hasStructuredActivity || tool.status == .running ? [] : output.map {
                        inlineActions(
                            text: $0,
                            annotations: [],
                            turnID: turn.id,
                            assetIndex: assetIndex,
                            registerAction: registerAction
                        )
                    } ?? [],
                    dagNodes: dag?.nodes.count,
                    dagEdges: dag?.edges?.count,
                    dagOpenActionID: dagOpenActionID,
                    backgroundJobID: BackgroundJobPresentation.jobID(for: tool),
                    rawName: tool.toolName,
                    icon: presentation.icon,
                    labels: ["input": ToolTranscriptText().text("input"), "output": ToolTranscriptText().text("output"),
                             "tool": ToolTranscriptText().text("tool.name"),
                             "command": ToolTranscriptText().text("command"),
                             "rawDetails": ToolTranscriptText().text("raw.details"),
                             "copy": ToolTranscriptText().text("copy"),
                             "copyOutput": ToolTranscriptText().text("copy.output"),
                             "waitGroup": ToolTranscriptText().text("job.wait.group")].merging(MacToolPresentation.labels()) { _, new in new },
                    command: commandForCard,
                    input: input,
                    inputContext: command == nil ? nil : ["workdir", "cwd"].compactMap { key -> String? in
                        guard case .string(let value)? = tool.args?[key], !value.isEmpty else { return nil }; return value
                    }.first,
                    hasResult: tool.artifact != nil || !tool.assets.isEmpty || tool.structuredOutput != nil || dag != nil,
                    copyInputActionID: input.flatMap { value in registerAction.map { $0(.transcript(turnID: turn.id, action: .copyBlock(text: value))) } },
                    fullOutputActionID: fullOutputActionID,
                    inputIsPreview: false,
                    inputIsRedacted: inputIsRedacted,
                    commandActions: previousTool?.args == tool.args ? previousWebTool?.commandActions : commandForCard.map {
                        inlineActions(text: $0, annotations: [], turnID: turn.id,
                                      assetIndex: assetIndex, registerAction: registerAction)
                    },
                    resultKind: resultKind,
                    outcomeText: outcomeText,
                    outcomeTone: resultFailed ? "failed" : tool.status == .running ? "running" : "completed",
                    imageView: imageView,
                    uiEvidence: uiEvidence,
                    uiLayout: uiLayout,
                    uiPreview: uiPreview
                )
            }
            return .init(
                id: group.id,
                kind: .toolGroup,
                text: nil,
                title: group.isActivityGroup ? MacToolPresentation.currentSummary(group) : groupPresentation.summary,
                status: MacToolPresentation.isRunning(group) ? "running" : MacToolPresentation.failureCount(group) > 0 ? "failed" : aggregateStatus(group.tools),
                elapsed: nil,
                tools: tools,
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                inlineActions: [],
                codeCopyActionIDs: [],
                statusText: ToolTranscriptText().text(MacToolPresentation.isRunning(group) ? "running" : MacToolPresentation.failureCount(group) > 0 ? "failed" : "run.succeeded"),
                isCollecting: group.isCollecting,
                activityOrder: group.isActivityGroup ? group.entries.map(\.id) : nil,
                activityThinking: group.entries.compactMap { entry in
                    if case .preMutation(let id, let payload) = entry {
                        return .init(id: id, kind: .thinking, text: payload.text,
                            title: ToolTranscriptText().text("desktop.preMutation"), status: nil,
                            elapsed: nil, tools: [], childStreamKind: nil, actionID: nil, actionTooltip: nil,
                            inlineActions: [], codeCopyActionIDs: [], systemKind: payload.kind.rawValue, metadata: payload.metadata)
                    }
                    guard case .thinking(let id, let payload) = entry else { return nil }
                    return .init(id: id, kind: .thinking, text: payload.text,
                                 title: ToolTranscriptText().thinkingTitle(streaming: payload.isStreaming),
                                 status: payload.isStreaming ? "streaming" : nil,
                                 elapsed: nil, tools: [], childStreamKind: nil,
                                 actionID: nil, actionTooltip: nil, inlineActions: [], codeCopyActionIDs: [])
                },
                activityJobs: group.entries.compactMap { entry in
                    guard case .backgroundJob(let id, let job) = entry else { return nil }
                    return makeBlock(.childStream(id: id, job), turn: turn,
                        previewArtifacts: previewArtifacts, allTurns: allTurns, previousBlock: nil,
                        previousWebBlock: nil, assetIndex: assetIndex, registerAction: registerAction, isGroupedJob: true)
                },
                activitySummary: group.isActivityGroup ? MacToolPresentation.expandedSummary(group) : nil,
                failureText: MacToolPresentation.failureCount(group) == 0 ? nil
                    : desktopText.text("desktop.failures", MacToolPresentation.failureCount(group)),
                startedAtMilliseconds: group.startedAt.map { $0.timeIntervalSince1970 * 1000 },
                finishedAtMilliseconds: group.finishedAt.map { $0.timeIntervalSince1970 * 1000 }
            )

        case .artifact(let id, let artifact):
            return .init(
                id: id,
                kind: .artifact,
                text: artifactText(artifact),
                title: SummaryRenderer.summary(for: artifact),
                status: nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: registerAction.map {
                    $0(.transcript(
                        turnID: turn.id,
                        action: .openArtifact(callID: artifact.callID)
                    ))
                },
                actionTooltip: artifact.path,
                inlineActions: [],
                codeCopyActionIDs: []
            )

        case .system(let id, let payload):
            let outcome = TurnOutcomePresentation.make(payload)
            return .init(
                id: id,
                kind: .system,
                text: outcome?.diagnostic ?? payload.text,
                title: payload.metadata["type"] == "cancelled" ? nil : payload.kind.rawValue,
                status: payload.kind == .error ? "failed" : nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: outcome?.canManageContext == true ? registerAction.map { $0(.transcript(turnID: turn.id, action: .openContextManagement)) } : nil,
                actionTooltip: nil,
                inlineActions: [],
                codeCopyActionIDs: outcome.flatMap { value in registerAction.map { [$0(.transcript(turnID: turn.id, action: .copyBlock(text: value.diagnostic)))] } } ?? [],
                outcome: outcome,
                contextMaintenance: ContextMaintenancePresentation.make(payload, live: turn.isLive),
                systemKind: payload.kind.rawValue,
                metadata: payload.metadata.isEmpty ? nil : payload.metadata
            )

        case .childStream(let id, let payload):
            return .init(
                id: id,
                kind: .childStream,
                // The child result belongs to the Inspector. Keeping it out of
                // the parent DOM also keeps cross-turn selection and VoiceOver
                // from traversing a duplicated, potentially very large result.
                text: nil,
                title: isGroupedJob ? MacToolPresentation.backgroundJobTitle(payload) : BackgroundJobPresentation.title(payload),
                status: payload.status.rawValue,
                elapsed: payload.formattedElapsed.map { payload.kind == .job
                    ? ToolTranscriptText().text("job.elapsed", $0) : $0 },
                tools: [],
                childStreamKind: payload.kind.rawValue,
                actionID: registerAction.map {
                    $0(.transcript(
                        turnID: turn.id,
                        action: .openChildStream(childID: payload.childID)
                    ))
                },
                actionTooltip: payload.childID,
                inlineActions: [],
                codeCopyActionIDs: [],
                statusText: isGroupedJob ? MacToolPresentation.backgroundJobStatus(payload)
                    : payload.status == .unavailable ? ToolTranscriptText().text("jobs.unavailable")
                    : payload.kind == .job && payload.status == .running ? ToolTranscriptText().text("jobs.status.running") : nil
            )

        case .workflow(let id, let payload):
            return .init(
                id: id,
                kind: .childStream,  // reuse childStream web rendering for now
                text: nil,
                title: payload.goal ?? payload.workflowID,
                status: payload.statusLabel,
                elapsed: nil,
                tools: [],
                childStreamKind: "workflow",
                actionID: registerAction.map {
                    $0(.transcript(
                        turnID: turn.id,
                        action: .openWorkflow(workflowID: payload.workflowID)
                    ))
                },
                actionTooltip: payload.workflowID,
                inlineActions: [],
                codeCopyActionIDs: []
            )
        }
    }

    private static func aggregateStatus(_ tools: [ToolNodePayload]) -> String? {
        if tools.contains(where: MacToolPresentation.isFailed) { return "failed" }
        if tools.contains(where: { $0.status == .running }) { return "running" }
        if tools.allSatisfy({ $0.status == .autoApproved }) { return "autoApproved" }
        return tools.isEmpty ? nil : "completed"
    }

    private static func formattedJSON(_ value: JSONValue) -> String? {
        if let pretty = value.prettyJSONString, !pretty.isEmpty {
            // JSONSerialization may escape path separators as `\/`. The workbench
            // renders arguments for people (and detects file actions in that text),
            // so keep filesystem paths readable and range-stable.
            return pretty.replacingOccurrences(of: "\\/", with: "/")
        }
        return value.stringValue.isEmpty ? nil : value.stringValue
    }

    /// 检测工具输出 JSON 是否包含 DAG 定义（workflow_definition / workflow_plan_ready 等格式）。
    private static func tryParseDAG(from jsonString: String) -> WebDAGData? {
        guard let data = jsonString.data(using: .utf8),
              let dag = try? JSONDecoder().decode(WebDAGData.self, from: data),
              !dag.nodes.isEmpty else { return nil }
        return dag
    }

    private static func artifactText(_ artifact: ArtifactNode) -> String? {
        switch artifact.content {
        case .diff(let payload):
            return payload.diffContent
        case .file(let payload):
            return payload.content
        case .directory(let payload):
            return payload.listing
        case .terminal(let payload):
            return payload.output
        }
    }

    private static func makeLiveState(_ snapshot: RuntimeSnapshot) -> ConversationWebDocument.LiveState? {
        let liveTurn = snapshot.turns.last(where: \.isLive)
        let waitingReason: String?
        if snapshot.pendingApproval != nil {
            waitingReason = "approval"
        } else if snapshot.pendingPlanApproval != nil {
            waitingReason = "plan"
        } else if snapshot.pendingAskUser != nil {
            waitingReason = "question"
        } else if snapshot.backgroundContinuation?.isWaiting == true {
            waitingReason = snapshot.backgroundContinuation?.state == "needs_attention" ? "background_attention" : "background"
        } else {
            waitingReason = nil
        }
        // isLive describes the session's stream connection, which stays open
        // between turns. Only execution or an actionable wait belongs here.
        guard snapshot.turnStartedAt != nil || liveTurn != nil || waitingReason != nil else { return nil }
        return ConversationWebDocument.LiveState(
            isThinking: snapshot.modelStartedAt != nil,
            startedAtMilliseconds: (snapshot.turnStartedAt ?? liveTurn?.startedAt).map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            modelRetrying: snapshot.modelRetrying,
            waitingReason: waitingReason
        )
    }

    private static func turnAssets(_ turn: ConversationTurn) -> [AgentAssetRef] {
        var assets: [AgentAssetRef] = []
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools { assets.append(contentsOf: tool.assets) }
        }
        return AgentAssetDisplayIndex.unique(assets)
    }

    private static func inlineActions(
        text: String,
        annotations: [AgentTextAnnotation],
        turnID: String,
        assetIndex: () -> AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> [ConversationWebDocument.InlineAction] {
        guard let registerAction else { return [] }
        let assetIndex = assetIndex()
        var consumedKeys = Set<String>()
        let resolvedAnnotations = annotations.resolvingNearbyLineNumberAssets(
            assetIndex: assetIndex
        )
        let annotationMatches = TextAnnotationReferenceDetector.matches(
            in: text,
            annotations: resolvedAnnotations,
            consumedKeys: &consumedKeys,
            assetIndex: assetIndex
        )
        let fallbackMatches = AssetReferenceDetector.matches(
            in: text,
            assetIndex: assetIndex
        ).filter { fallback in
            !annotationMatches.contains {
                NSIntersectionRange($0.range, fallback.range).length > 0
            }
        }
        let nsText = text as NSString
        return (annotationMatches + fallbackMatches)
            .sorted { $0.range.location < $1.range.location }
            .compactMap { match in
                guard match.range.location != NSNotFound,
                      NSMaxRange(match.range) <= nsText.length else { return nil }
                return ConversationWebDocument.InlineAction(
                    text: nsText.substring(with: match.range),
                    actionID: registerAction(.transcript(
                        turnID: turnID,
                        action: .openAsset(match.reference)
                    )),
                    tooltip: match.reference.target
                )
            }
    }

    private static func codeBlockCopyActions(
        in markdown: String,
        turnID: String,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> [String] {
        guard let registerAction,
              let regex = try? NSRegularExpression(
                pattern: #"(?s)(?:^|\n)```[^\n]*\n(.*?)(?:\n```|```$)"#
              ) else { return [] }
        let nsText = markdown as NSString
        return regex.matches(
            in: markdown,
            range: NSRange(location: 0, length: nsText.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { return nil }
            let code = nsText.substring(with: match.range(at: 1))
            return registerAction(.transcript(
                turnID: turnID,
                action: .copyBlock(text: code)
            ))
        }
    }
}

// MARK: - Web DAG detection

private struct WebDAGData: Decodable {
    let workflowId: String?
    let nodes: [WebDAGNode]
    let edges: [WebDAGEdge]?

    enum CodingKeys: String, CodingKey {
        case nodes, edges
        case workflowId = "workflow_id"
    }
}

private struct WebDAGNode: Decodable {
    let name: String
}

private struct WebDAGEdge: Decodable {
    let from: String
    let to: String
}
