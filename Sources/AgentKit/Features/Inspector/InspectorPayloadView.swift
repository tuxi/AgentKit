//
//  InspectorPayloadView.swift
//  AgentKit
//
//  On-demand view of a tool's complete input/output in the Inspector. The
//  first render is bounded; the complete payload is formatted only when the
//  user asks for it, off the main actor, and copied in full without ever
//  appearing in the transcript's inline layout.
//

import ClientToolProtocol
import SwiftUI

struct InspectorPayloadView: View {
    let tool: ToolNodePayload
    let kind: ToolPayloadKind
    let title: String

    @StateObject private var model = ToolPayloadDetailModel()
    @State private var limit = ToolPayloadDetailMetrics.inspectorPreviewBytes
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.loadingKinds.contains(kind) {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if let payload = model.payloads[kind], payload.isTruncated {
                    Button("Show complete") {
                        limit = ToolPayloadDetailMetrics.inspectorCompleteBytes
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(copied ? "Copied" : "Copy complete") {
                    copyCompletePayload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let payload = model.payloads[kind] {
                Text(payload.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                if payload.isTruncated {
                    Text(
                        "Showing \(ByteCountFormatter.string(fromByteCount: Int64(payload.text.utf8.count), countStyle: .file))"
                            + " of \(ByteCountFormatter.string(fromByteCount: Int64(payload.totalByteCount), countStyle: .file))."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: limit) {
            model.load(kind, tool: tool, limit: limit)
        }
    }

    private func copyCompletePayload() {
        let key = ToolPayloadTextCache.Key(
            callID: tool.callID,
            kind: kind,
            limit: Int.max
        )
        Task {
            let payload = await ToolPayloadTextCache.shared.payload(for: key) {
                ToolPayloadFormatter.make(tool: tool, kind: kind, limit: Int.max)
            }
            guard let payload else { return }
            Clipboard.copy(payload.text)
            copied = true
        }
    }
}
