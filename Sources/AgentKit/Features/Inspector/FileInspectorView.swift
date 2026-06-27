//
//  FileInspectorView.swift
//  CodeAgent
//
//  P5.0: Full-panel file inspector — header (filename + path + badges) + scrollable code body.
//

import SwiftUI

struct FileInspectorView: View {

    let payload: FilePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            VStack(alignment: .leading, spacing: 4) {
                Text(shortFileName)
                    .font(.title2)

                Text(payload.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if let lang = payload.language {
                        Text(lang)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    Text("\(lineCount) lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if payload.isNew {
                        Text("New")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding()

            Divider()

            // MARK: - Body (full-panel, no height cap)
            FileArtifactBody(
                filePath: payload.filePath,
                content: payload.content,
                language: payload.language,
                maxHeight: nil
            )
        }
    }

    private var shortFileName: String {
        (payload.filePath as NSString).lastPathComponent
    }

    private var lineCount: Int {
        payload.content.components(separatedBy: "\n").count
    }
}
