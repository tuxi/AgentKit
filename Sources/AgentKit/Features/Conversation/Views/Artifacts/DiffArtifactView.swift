//
//  DiffArtifactView.swift
//  AgentKit
//
//  Diff artifact 渲染 — 等宽字体、+/- 行着色。
//

import SwiftUI

// MARK: - DiffArtifactBody (content only, used by UnifiedToolCard)

/// Diff 内容渲染体 — 无标题栏、无折叠控件，纯内容。
/// 由 `UnifiedToolCard` 或 `DiffArtifactView` 内嵌使用。
struct DiffArtifactBody: View {
    let filePath: String?
    let diffContent: String
    var maxHeight: CGFloat? = 300

    var body: some View {
        let scroll = ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines) { line in
                    Text(line.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.color)
                        .textSelection(.enabled)
                }
            }
        }

        if let maxHeight {
            scroll.frame(maxHeight: maxHeight)
        } else {
            scroll
        }
    }

    private struct DiffLine: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
    }

    private var diffLines: [DiffLine] {
        diffContent.components(separatedBy: "\n").map { line in
            let color: Color
            if line.hasPrefix("+") { color = .green }
            else if line.hasPrefix("-") { color = .red }
            else if line.hasPrefix("@@") { color = .blue }
            else { color = .secondary }
            return DiffLine(text: line, color: color)
        }
    }
}

// MARK: - DiffArtifactView (standalone, with chrome)

/// Diff/patch artifact 的独立渲染视图（带标题栏和折叠控件）。
struct DiffArtifactView: View {
    let filePath: String?
    let diffContent: String

    @State private var isExpanded = false

    private let maxCollapsedLines = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.caption)
                    Text("Diff: \(filePath ?? "unknown")")
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                DiffArtifactBody(filePath: filePath, diffContent: diffContent)
            } else {
                let preview = diffContent.components(separatedBy: "\n").prefix(maxCollapsedLines).joined(separator: "\n")
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(maxCollapsedLines)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
