//
//  CodeBlockView.swift
//  AgentKit
//
//  Renders a syntax-highlighted code block with dark background,
//  language tag, and copy button. Cross-platform (macOS + iOS).
//

import SwiftUI

/// Renders a syntax-highlighted code block with language header and copy button.
struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    Label(
                        showCopied ? "Copied" : "Copy",
                        systemImage: showCopied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption2)
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.codeBlockHeaderBackground)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                let highlighted = SyntaxHighlighter.highlight(code, language: language)
                Text(highlighted)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.codeBlockBorder, lineWidth: 1)
        )
    }

    // MARK: - Clipboard

    private func copyToClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}
