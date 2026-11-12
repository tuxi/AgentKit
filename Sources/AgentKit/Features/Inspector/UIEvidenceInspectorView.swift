//
//  UIEvidenceInspectorView.swift
//  AgentKit
//
//  Read-only Inspector for raw `ui_evidence.v1` and its structured fields.
//

import ClientToolProtocol
import SwiftUI

struct UIEvidenceInspectorView: View {
    let selection: UIEvidenceSelection

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

    private var document: UIEvidenceDocument? {
        guard let raw = payload?.structuredOutput,
              raw["schema"].string == "ui_evidence.v1" else { return nil }
        return UIEvidenceDocument.parse(raw)
    }

    var body: some View {
        Group {
            if let payload {
                content(payload)
            } else {
                ContentUnavailableView(
                    "UI evidence not found",
                    systemImage: "doc.text.magnifyingglass"
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
                    ocrElements(document)
                    repeatedGroups(document)
                    uncertaintiesAndLimits(document)
                } else {
                    Label(
                        "The structured output is not valid ui_evidence.v1. Raw output remains available below.",
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
                Image(systemName: "viewfinder.rectangular")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(document?.source.assetID ?? "ui_evidence.v1")
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

    private func metadata(_ document: UIEvidenceDocument) -> some View {
        section("Evidence") {
            infoRow("Schema", "ui_evidence.v1")
            infoRow("Producer", "\(document.producer.name)/\(document.producer.version)")
            infoRow("Source kind", document.source.sourceKind.rawValue)
            infoRow("MIME type", document.source.mimeType)
            infoRow("Pixels", "\(document.source.width) × \(document.source.height)")
            infoRow("SHA-256", document.source.sha256)
            infoRow("Source tree", document.sourceTree.kind.rawValue)
            if let note = document.sourceTreeNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func assets(_ document: UIEvidenceDocument, tool: ToolNodePayload) -> some View {
        section("Source and crop assets") {
            let assetsByID = Dictionary(
                tool.assets.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let source = assetsByID[document.source.assetID]
            assetRow(
                role: "source",
                id: document.source.assetID,
                bbox: nil,
                asset: source
            )
            ForEach(Array(document.crops.enumerated()), id: \.element.assetID) { _, crop in
                assetRow(
                    role: "crop · \(crop.purpose.rawValue)",
                    id: crop.assetID,
                    bbox: crop.sourceBBox,
                    asset: assetsByID[crop.assetID]
                )
            }
        }
    }

    private func assetRow(
        role: String,
        id: String,
        bbox: UIEvidenceBBox?,
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
            Text(id)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let asset {
                Text(asset.workspaceRelativePath ?? asset.absolutePath ?? asset.uri ?? asset.displayName ?? "No path")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let mimeType = asset.mimeType {
                    Text(mimeType)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Asset is not registered by this tool result.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let bbox {
                Text(formatBBox(bbox))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func ocrElements(_ document: UIEvidenceDocument) -> some View {
        section("OCR and geometry elements (\(document.elements.count))") {
            if document.elements.isEmpty {
                Text("No elements were reported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(document.elements, id: \.id) { element in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(element.kind.rawValue)
                            .font(.caption.weight(.semibold))
                        evidenceBadge(element.evidence)
                        if let role = element.role {
                            Text(role)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.3f", element.confidence))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(element.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    if let text = element.text, !text.isEmpty {
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    Text(formatBBox(element.bbox))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(9)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func repeatedGroups(_ document: UIEvidenceDocument) -> some View {
        section("Repeated groups (\(document.repeatedGroups.count))") {
            if document.repeatedGroups.isEmpty {
                Text("No repeated groups were reported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(document.repeatedGroups, id: \.id) { group in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(group.id)
                            .font(.caption.monospaced().weight(.semibold))
                        evidenceBadge(group.evidence)
                        Spacer()
                        Text(group.axis.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.3f", group.confidence))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("Members: \(group.memberIDs.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Text(formatBBox(group.bbox))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(9)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func uncertaintiesAndLimits(_ document: UIEvidenceDocument) -> some View {
        VStack(alignment: .leading, spacing: 18) {
        section("Uncertainties (\(document.uncertainties.count))") {
            if document.uncertainties.isEmpty {
                Text("No uncertainties were reported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(document.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                VStack(alignment: .leading, spacing: 4) {
                    Text(uncertainty.description)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let reason = uncertainty.reason {
                        Text(reason)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !uncertainty.relatedElementIDs.isEmpty {
                        Text("Related: \(uncertainty.relatedElementIDs.joined(separator: ", "))")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }

        section("Limits") {
            infoRow("Element count", "\(document.limits.elementCount)")
            infoRow("Elements truncated", document.limits.elementsTruncated ? "yes" : "no")
            infoRow("Tree nodes truncated", document.limits.treeNodesTruncated ? "yes" : "no")
            infoRow("Source tree truncated", document.sourceTree.truncated ? "yes" : "no")
        }
        }
    }

    private func rawJSON(_ payload: ToolNodePayload) -> some View {
        section("Raw ui_evidence.v1 JSON · read only") {
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
            if !payload.output.isEmpty {
                DisclosureGroup("Raw tool text") {
                    Text(payload.output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
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
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func evidenceBadge(_ evidence: UIEvidenceEvidence) -> some View {
        Text(evidence.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color(for: evidence))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color(for: evidence).opacity(0.12))
            .clipShape(Capsule())
    }

    private func color(for evidence: UIEvidenceEvidence) -> Color {
        switch evidence {
        case .observed: .green
        case .inferred: .blue
        case .uncertain: .orange
        }
    }

    private func formatBBox(_ bbox: UIEvidenceBBox) -> String {
        String(
            format: "bbox x=%.4f y=%.4f w=%.4f h=%.4f",
            bbox.x,
            bbox.y,
            bbox.width,
            bbox.height
        )
    }
}
