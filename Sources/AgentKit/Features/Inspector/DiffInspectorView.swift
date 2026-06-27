//
//  DiffInspectorView.swift
//  CodeAgent
//
//  P5.0: Full-panel diff inspector — header (+X/-Y badges) + scrollable colored diff body.
//

import SwiftUI

struct DiffInspectorView: View {

    let payload: DiffPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.title2)

                if let path = payload.filePath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    if payload.addedLines > 0 {
                        Text("+\(payload.addedLines)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if payload.removedLines > 0 {
                        Text("-\(payload.removedLines)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding()

            Divider()

            // MARK: - Body (full-panel, no height cap)
            DiffArtifactBody(
                filePath: payload.filePath,
                diffContent: payload.diffContent,
                maxHeight: nil
            )
        }
    }

    private var titleText: String {
        let name = payload.filePath.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        return "Edited \(name)"
    }
}
