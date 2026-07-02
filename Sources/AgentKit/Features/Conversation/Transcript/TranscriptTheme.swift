//
//  TranscriptTheme.swift
//  AgentKit
//
//  Shared light/dark palette and block-decoration attributes for the
//  native transcript. The builder tags block-level content (code, tables,
//  quotes, diffs, errors) with `.transcriptBlock`; NativeTranscriptView's
//  layout manager draws the full-width rounded backgrounds those tags
//  describe. Glyph-level `.backgroundColor` can't produce block visuals —
//  it only paints behind glyph runs — so all block chrome lives here.
//

import Foundation

#if os(macOS)
import AppKit
typealias TranscriptPlatformColor = NSColor
#else
import UIKit
typealias TranscriptPlatformColor = UIColor
#endif

// MARK: - Block decoration attributes

extension NSAttributedString.Key {
    /// Marks a run as part of a full-width decorated block (code, table, …).
    static let transcriptBlock = NSAttributedString.Key("agentkit.transcriptBlock")
    /// Marks a run as an inline chip (inline code, nested tool title).
    static let transcriptChip = NSAttributedString.Key("agentkit.transcriptChip")
}

enum TranscriptBlockKind: Int {
    case code
    case table
    case quote
    case error
    case diffAdded
    case diffRemoved
    case diffHunk
    /// Unchanged context lines inside a diff — code-tinted, but tiled edge
    /// to edge with the added/removed stripes around them.
    case diffContext
}

enum TranscriptChipKind: Int {
    case inlineCode
    case nestedTool
}

/// Attribute value for `.transcriptBlock`. `runID` keeps adjacent but
/// distinct blocks (e.g. two consecutive diff runs) from merging when the
/// layout manager enumerates attribute runs.
final class TranscriptBlockValue: NSObject {
    let kind: TranscriptBlockKind
    let runID: Int

    init(kind: TranscriptBlockKind, runID: Int) {
        self.kind = kind
        self.runID = runID
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptBlockValue else { return false }
        return other.kind == kind && other.runID == runID
    }

    override var hash: Int { kind.rawValue &* 31 &+ runID }
}

final class TranscriptChipValue: NSObject {
    let kind: TranscriptChipKind

    init(kind: TranscriptChipKind) {
        self.kind = kind
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? TranscriptChipValue)?.kind == kind
    }

    override var hash: Int { kind.rawValue }
}

// MARK: - Theme

/// Single source of truth for transcript colors, light and dark.
/// Dark values keep the warm Claude-style tones already in use; light
/// values are a matching warm-paper palette instead of bare system colors.
enum TranscriptTheme {

    // MARK: Text

    static var primaryText: TranscriptPlatformColor {
        dynamic(
            light: color(0.15, 0.15, 0.14),
            dark: color(0.88, 0.86, 0.82)
        )
    }

    static var secondaryText: TranscriptPlatformColor {
        dynamic(
            light: color(0.42, 0.41, 0.38),
            dark: color(0.67, 0.65, 0.60)
        )
    }

    static var tertiaryText: TranscriptPlatformColor {
        dynamic(
            light: color(0.60, 0.59, 0.55),
            dark: color(0.46, 0.45, 0.42)
        )
    }

    /// Blockquote body text.
    static var quoteText: TranscriptPlatformColor { secondaryText }

    // MARK: Links

    /// External URLs — the only links that keep an underline.
    static var urlLink: TranscriptPlatformColor {
        dynamic(
            light: color(0.20, 0.42, 0.76),
            dark: color(0.56, 0.70, 0.93)
        )
    }

    /// Workspace file paths and assets.
    static var pathLink: TranscriptPlatformColor {
        dynamic(
            light: color(0.10, 0.46, 0.44),
            dark: color(0.52, 0.78, 0.74)
        )
    }

    /// Artifact rows share the path tint so "local resource" reads as one color.
    static var artifactLink: TranscriptPlatformColor { pathLink }

    // MARK: Status

    static var running: TranscriptPlatformColor {
        dynamic(
            light: color(0.80, 0.48, 0.14),
            dark: color(0.87, 0.57, 0.32)
        )
    }

    static var failed: TranscriptPlatformColor {
        dynamic(
            light: color(0.77, 0.25, 0.25),
            dark: color(1.00, 0.42, 0.42)
        )
    }

    // MARK: Blocks & chips
    // Backgrounds are translucent warm tints so they adapt to whatever
    // surface the turn card sits on.

    static var codeBlockBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.36, 0.33, 0.24, alpha: 0.07),
            dark: color(0.92, 0.90, 0.84, alpha: 0.07)
        )
    }

    static var tableBackground: TranscriptPlatformColor { codeBlockBackground }

    static var errorBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.77, 0.25, 0.25, alpha: 0.08),
            dark: color(1.00, 0.42, 0.42, alpha: 0.12)
        )
    }

    static var inlineCodeBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.36, 0.33, 0.24, alpha: 0.10),
            dark: color(0.92, 0.90, 0.84, alpha: 0.11)
        )
    }

    static var inlineCodeText: TranscriptPlatformColor {
        dynamic(
            light: color(0.68, 0.30, 0.20),
            dark: color(0.92, 0.64, 0.48)
        )
    }

    static var toolSurface: TranscriptPlatformColor {
        dynamic(
            light: color(0.36, 0.33, 0.24, alpha: 0.07),
            dark: color(1.00, 1.00, 1.00, alpha: 0.08)
        )
    }

    static var quoteBar: TranscriptPlatformColor {
        dynamic(
            light: color(0.36, 0.33, 0.24, alpha: 0.28),
            dark: color(0.92, 0.90, 0.84, alpha: 0.25)
        )
    }

    // MARK: Diff

    static var diffAddedText: TranscriptPlatformColor {
        dynamic(
            light: color(0.13, 0.50, 0.24),
            dark: color(0.45, 0.80, 0.50)
        )
    }

    static var diffRemovedText: TranscriptPlatformColor {
        dynamic(
            light: color(0.75, 0.22, 0.22),
            dark: color(0.95, 0.45, 0.45)
        )
    }

    static var diffHunkText: TranscriptPlatformColor {
        dynamic(
            light: color(0.30, 0.42, 0.70),
            dark: color(0.55, 0.68, 0.92)
        )
    }

    static var diffAddedBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.13, 0.60, 0.24, alpha: 0.10),
            dark: color(0.45, 0.80, 0.50, alpha: 0.13)
        )
    }

    static var diffRemovedBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.75, 0.22, 0.22, alpha: 0.09),
            dark: color(0.95, 0.45, 0.45, alpha: 0.12)
        )
    }

    static var diffHunkBackground: TranscriptPlatformColor {
        dynamic(
            light: color(0.30, 0.42, 0.70, alpha: 0.08),
            dark: color(0.55, 0.68, 0.92, alpha: 0.10)
        )
    }

    // MARK: Syntax highlight

    static var codeKeyword: TranscriptPlatformColor {
        dynamic(
            light: color(0.62, 0.17, 0.51),
            dark: color(0.86, 0.55, 0.72)
        )
    }

    static var codeString: TranscriptPlatformColor {
        dynamic(
            light: color(0.63, 0.30, 0.11),
            dark: color(0.82, 0.66, 0.45)
        )
    }

    static var codeComment: TranscriptPlatformColor {
        dynamic(
            light: color(0.45, 0.50, 0.42),
            dark: color(0.52, 0.56, 0.47)
        )
    }

    static var codeNumber: TranscriptPlatformColor {
        dynamic(
            light: color(0.14, 0.43, 0.60),
            dark: color(0.56, 0.74, 0.86)
        )
    }

    // MARK: Renderer lookup

    static func blockFill(for kind: TranscriptBlockKind) -> TranscriptPlatformColor? {
        switch kind {
        case .code: return codeBlockBackground
        case .table: return tableBackground
        case .error: return errorBackground
        case .quote: return nil // quote draws a bar, not a fill
        case .diffAdded: return diffAddedBackground
        case .diffRemoved: return diffRemovedBackground
        case .diffHunk: return diffHunkBackground
        case .diffContext: return codeBlockBackground
        }
    }

    static func blockCornerRadius(for kind: TranscriptBlockKind) -> CGFloat {
        switch kind {
        case .code, .table, .error: return 6
        case .diffAdded, .diffRemoved, .diffHunk, .diffContext: return 3
        case .quote: return 0
        }
    }

    static func chipFill(for kind: TranscriptChipKind) -> TranscriptPlatformColor {
        switch kind {
        case .inlineCode: return inlineCodeBackground
        case .nestedTool: return toolSurface
        }
    }

    // MARK: Helpers

    private static func color(
        _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1
    ) -> TranscriptPlatformColor {
        TranscriptPlatformColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func dynamic(
        light: TranscriptPlatformColor,
        dark: TranscriptPlatformColor
    ) -> TranscriptPlatformColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        #endif
    }
}
