//
//  UIPreviewInspectorView.swift
//  AgentKit
//
//  Read-only Inspector for the classification and lineage of one
//  `ui_preview_result.v1` record. Artifact identity and related layout and
//  evidence assets are re-read from the resident conversation.
//

import ClientToolProtocol
import SwiftUI

struct UIPreviewInspectorView: View {
    let selection: UIPreviewSelection

    @Environment(WorkspaceStore.self) private var store
    @Environment(\.inspectorPathState) private var inspectorPath

    private var payload: ToolNodePayload? {
        store.activeConversationViewModel?.snapshot.timeline
            .lazy
            .compactMap { node -> ToolNodePayload? in
                guard case .tool(let payload) = node.kind,
                      payload.callID == selection.callID else { return nil }
                return payload
            }
            .first
    }

    private var document: UIPreviewResultDocument? {
        guard let raw = payload?.structuredOutput,
              raw["schema"].string == "ui_preview_result.v1" else { return nil }
        return UIPreviewResultDocument.parse(raw)
    }

    private var previewArtifact: PreviewArtifact? {
        guard let snapshot = store.activeConversationViewModel?.snapshot,
              let turn = snapshot.turns.first(where: { turn in
                  turn.blocks.contains { block in
                      guard case .toolGroup(let group) = block else { return false }
                      return group.tools.contains { $0.callID == selection.callID }
                  }
              }) else {
            return nil
        }
        return snapshot.previewArtifactHistory
            .filter { $0.turnID == turn.runtimeTurnID && $0.callID == selection.callID }
            .max { $0.revision < $1.revision }
    }

    private var relatedAssets: UIPreviewActivityProjection.RelatedAssets? {
        guard let lineage = document?.lineage,
              let turns = store.activeConversationViewModel?.snapshot.turns else {
            return nil
        }
        return UIPreviewActivityProjection.resolveRelatedAssets(
            lineage: lineage,
            turns: turns
        )
    }

    var body: some View {
        Group {
            if let payload {
                content(payload)
            } else {
                ContentUnavailableView(
                    "UI preview not found",
                    systemImage: "rectangle.on.rectangle"
                )
            }
        }
        .navigationTitle(selection.title)
    }

    private func content(_ payload: ToolNodePayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(payload)

                if let document {
                    identity(document)
                    if let lineage = document.lineage {
                        lineageSection(lineage)
                        relatedSection(lineage)
                    } else {
                        Label(
                            "Explore Preview: standalone, with no layout lineage.",
                            systemImage: "sparkle.magnifyingglass"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    fallbackSection(document.fallbackAsset, tool: payload)
                } else {
                    Label(
                        "The structured output is not a valid ui_preview_result.v1, or an adaptation preview is missing its v2 lineage. This cannot be shown as a formal preview. Raw output remains available below.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                rawJSON(payload)
            }
            .padding()
        }
    }

    private func header(_ payload: ToolNodePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: document?.isAdaptation == true
                    ? "rectangle.on.rectangle"
                    : "sparkle.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(document?.modeLabel ?? "ui_preview_result.v1")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let document {
                Text(document.title)
                    .font(.headline)
                    .textSelection(.enabled)
            }
            Text(payload.toolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Tool result: \(payload.callID)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func identity(_ document: UIPreviewResultDocument) -> some View {
        section("Preview identity") {
            infoRow("Mode", document.modeLabel)
            infoRow("Artifact key", document.artifactKey)
            infoRow("Kind", document.kind)
            if let artifact = previewArtifact {
                infoRow("Artifact", artifact.artifactID)
                infoRow("Revision", String(artifact.revision))
                infoRow("Revision SHA-256", artifact.revisionSHA256)
                infoRow("Runtime status", artifact.status.rawValue)
                infoRow(
                    "Presentation",
                    artifact.presentationState(
                        capabilities: ConversationWebDocumentBuilder.previewNegotiation
                    ).rawValue
                )
            } else {
                Label(
                    "No preview artifact is correlated with this tool result.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func lineageSection(_ lineage: UIPreviewLineage) -> some View {
        section("Lineage") {
            infoRow("Layout artifact", lineage.layoutArtifactID)
            infoRow("Layout revision", String(lineage.layoutRevision))
            infoRow("Layout revision SHA-256", lineage.layoutRevisionSHA256)
            infoRow("Source asset", lineage.sourceAssetID)
            infoRow("Source SHA-256", lineage.sourceAssetSHA256)
            infoRow(
                "Evidence SHA-256",
                lineage.evidenceSHA256 ?? "none (layout has no evidence input)"
            )
            infoRow("Target", lineage.target)
            infoRow("State", lineage.state)
            infoRow("Target matrix", lineage.targetMatrix.id)
            infoRow(
                "Matrix targets",
                lineage.targetMatrix.targets.joined(separator: ", ")
            )
            infoRow("Approval", lineage.approval.state.rawValue)
            if let evidenceRef = lineage.approval.evidenceRef {
                infoRow("Approval evidence", evidenceRef)
            }
        }
    }

    private func relatedSection(_ lineage: UIPreviewLineage) -> some View {
        section("Bound documents") {
            if let layoutJSON = relatedAssets?.layoutJSON {
                assetLink(layoutJSON, label: "Open layout JSON")
            } else {
                Text("Layout JSON is not resident in this conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let evidenceJSON = relatedAssets?.evidenceJSON {
                assetLink(evidenceJSON, label: "Open evidence JSON")
            } else if lineage.evidenceSHA256 != nil {
                Text("Evidence JSON is not resident in this conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fallbackSection(
        _ fallback: UIPreviewFallbackAsset,
        tool: ToolNodePayload
    ) -> some View {
        section("Fallback asset") {
            if let asset = tool.assets.first(where: { $0.id == fallback.assetID }) {
                assetLink(asset, label: "Open fallback image")
                infoRow("Asset", fallback.assetID)
                infoRow("MIME type", fallback.mimeType)
                infoRow("Size", "\(fallback.width) × \(fallback.height)")
                infoRow("SHA-256", fallback.sha256)
            } else {
                Text("The fallback asset is not registered by this tool result.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func assetLink(_ asset: AgentAssetRef, label: String) -> some View {
        HStack(spacing: 10) {
            Button(label) {
                inspectorPath.push(.assetDetail(AssetPreviewPayload(
                    asset: asset,
                    conversationID: store.activeConversationViewModel?.conversation?.id,
                    workspace: store.activeConversationViewModel?.workspaceAnchor
                )))
            }
            .buttonStyle(.bordered)
            Text(asset.displayName ?? asset.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func rawJSON(_ payload: ToolNodePayload) -> some View {
        section("Raw ui_preview_result.v1 JSON · read only") {
            if let raw = payload.structuredOutput?.prettyJSONString {
                Text(raw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("No structured JSON is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
