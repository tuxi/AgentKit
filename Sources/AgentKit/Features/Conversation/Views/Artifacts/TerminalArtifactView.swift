//
//  TerminalArtifactView.swift
//  AgentKit
//
//  Terminal artifact 渲染 — 终端风格（深色背景、等宽字体、exit code）。
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - TerminalArtifactBody (content only, used by UnifiedToolCard)

/// 终端输出渲染体 — 无标题栏、无折叠控件，纯内容。
/// 由 `UnifiedToolCard` 或 `TerminalArtifactView` 内嵌使用。
struct TerminalArtifactBody: View {
    let command: String
    let output: String
    let exitCode: Int?
    var maxHeight: CGFloat? = 300

    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let scroll = ScrollView([.horizontal, .vertical]) {
                Text(output)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let maxHeight {
                scroll.frame(maxHeight: maxHeight)
            } else {
                scroll
            }

            HStack {
                Spacer()
                Button {
                    copyToClipboard(output)
                    showCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showCopied = false
                    }
                } label: {
                    Label(
                        showCopied ? "Copied!" : "Copy",
                        systemImage: showCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showCopied ? .green : .secondary)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - TerminalArtifactView (standalone, with chrome)

/// 终端输出 artifact 的独立渲染视图（带标题栏和折叠控件）。
struct TerminalArtifactView: View {
    let command: String
    let output: String
    let exitCode: Int?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption)
                    Text("$ \(command)")
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                    if let code = exitCode {
                        Text(code == 0 ? "✓ 0" : "✗ \(code)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(code == 0 ? .green : .red)
                            .padding(.horizontal, 4)
                            .background(code == 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                TerminalArtifactBody(command: command, output: output, exitCode: exitCode)
            } else {
                let preview = output.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(5)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
