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

    private var displayLanguage: String? {
        let trimmed = language.trimmingCharacters(in: .whitespaces).lowercased()
        return (trimmed.isEmpty || trimmed == "text") ? nil : language
    }

    private var copyButton: some View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar — language label (when known) + copy button
            HStack {
                if let lang = displayLanguage {
                    Text(lang.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                copyButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // Code content — horizontally scrollable, never wraps.
            // fixedSize prevents Text from line-wrapping inside the ScrollView;
            // minWidth ensures the block doesn't collapse below a usable width
            // when the outer container is narrow (e.g. iOS split-screen).
            ScrollView(.horizontal, showsIndicators: false) {
                let highlighted = SyntaxHighlighter.highlight(code, language: language)
                Text(highlighted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .frame(minWidth: 200)
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
