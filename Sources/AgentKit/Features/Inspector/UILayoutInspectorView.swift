//
//  UILayoutInspectorView.swift
//  AgentKit
//
//  Read-only Inspector for the metadata of one `ui_layout_result.v1` revision.
//  The canonical layout JSON and overlay open through the asset inspector.
//

import ClientToolProtocol
import SwiftUI

struct UILayoutInspectorView: View {
    let selection: UILayoutSelection

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

    private var document: UILayoutResultDocument? {
        guard let raw = payload?.structuredOutput,
              raw["schema"].string == "ui_layout_result.v1" else { return nil }
        return UILayoutResultDocument.parse(raw)
    }

    var body: some View {
        Group {
            if let payload {
                content(payload)
            } else {
                ContentUnavailableView(
                    "UI layout not found",
                    systemImage: "rectangle.3.group"
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
                    metadata(document)
                    assets(document, tool: payload)
                } else {
                    Label(
                        "The structured output is not valid ui_layout_result.v1. Raw output remains available below.",
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
                Image(systemName: "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(document?.artifactID ?? "ui_layout_result.v1")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
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

    private func metadata(_ document: UILayoutResultDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Layout revision") {
                infoRow("Schema", "ui_layout_result.v1")
                infoRow("Artifact", document.artifactID)
                infoRow("Revision", String(document.revision))
                infoRow("Created", document.created ? "yes (new revision)" : "no (reused)")
                infoRow("Revision SHA-256", document.revisionSHA256)
                infoRow("Canvas", "\(document.canvas.width) × \(document.canvas.height)")
                infoRow("Nodes", String(document.nodeCount))
                infoRow("Assumptions", String(document.assumptionCount))
                infoRow("Targets", document.targets.joined(separator: ", "))
            }
            section("Identity binding") {
                infoRow("Source asset", document.sourceAssetID)
                infoRow("Source SHA-256", document.sourceAssetSHA256)
                infoRow(
                    "Evidence SHA-256",
                    document.evidenceSHA256 ?? "none (layout has no evidence input)"
                )
            }
        }
    }

    private func assets(
        _ document: UILayoutResultDocument,
        tool: ToolNodePayload
    ) -> some View {
        section("Canonical assets") {
            let assetsByID = Dictionary(
                tool.assets.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            assetRow(
                role: document.overlayAsset.role,
                descriptor: document.overlayAsset,
                asset: assetsByID[document.overlayAsset.assetID]
            )
            assetRow(
                role: document.layoutJSONAsset.role,
                descriptor: document.layoutJSONAsset,
                asset: assetsByID[document.layoutJSONAsset.assetID]
            )
        }
    }

    private func assetRow(
        role: String,
        descriptor: UILayoutAssetDescriptor,
        asset: AgentAssetRef?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let asset {
                    Button("View asset") {
                        inspectorPath.push(.assetDetail(AssetPreviewPayload(
                            asset: asset,
                            conversationID: store.activeConversationViewModel?.conversation?.id,
                            workspace: store.activeConversationViewModel?.workspaceAnchor
                        )))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(descriptor.assetID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(descriptor.relativePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(
                "\(descriptor.mimeType) · \(descriptor.sha256)"
                    + (descriptor.width.map { " · \($0)×\(descriptor.height ?? 0)" } ?? "")
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            if asset == nil {
                Text("Asset is not registered by this tool result.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rawJSON(_ payload: ToolNodePayload) -> some View {
        section("Raw ui_layout_result.v1 JSON · read only") {
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
                .frame(width: 124, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
