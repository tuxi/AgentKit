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
    /// Marks a table's header row — the renderer draws a hairline under it.
    static let transcriptTableHeader = NSAttributedString.Key("agentkit.transcriptTableHeader")
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
    /// Thematic break — no fill; the renderer draws a centered hairline.
    case divider
    /// User prompt bubble — right-anchored snug fill, not full width.
    case userPrompt
    /// Model reasoning/thinking card — muted, indented, left-bordered.
    case thinking
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
///
/// Colors MUST be `static let` singletons: provider-based dynamic colors
/// compare by identity, and both the transcript cache and the incremental
/// (selection-preserving) text-storage updates rely on rebuilt attributed
/// strings comparing equal when nothing changed.
enum TranscriptTheme {

    // MARK: Text

    static let primaryText: TranscriptPlatformColor = dynamic(
        light: color(0.15, 0.15, 0.14),
        dark: color(0.88, 0.86, 0.82)
    )

    static let secondaryText: TranscriptPlatformColor = dynamic(
        light: color(0.42, 0.41, 0.38),
        dark: color(0.67, 0.65, 0.60)
    )

    static let tertiaryText: TranscriptPlatformColor = dynamic(
        light: color(0.60, 0.59, 0.55),
        dark: color(0.46, 0.45, 0.42)
    )

    /// Blockquote body text.
    static let quoteText: TranscriptPlatformColor = secondaryText

    // MARK: Links

    /// External URLs — the only links that keep an underline.
    static let urlLink: TranscriptPlatformColor = dynamic(
        light: color(0.20, 0.42, 0.76),
        dark: color(0.56, 0.70, 0.93)
    )

    /// Workspace file paths and assets.
    static let pathLink: TranscriptPlatformColor = dynamic(
        light: color(0.10, 0.46, 0.44),
        dark: color(0.52, 0.78, 0.74)
    )

    /// Artifact rows share the path tint so "local resource" reads as one color.
    static let artifactLink: TranscriptPlatformColor = pathLink

    // MARK: Status

    static let running: TranscriptPlatformColor = dynamic(
        light: color(0.80, 0.48, 0.14),
        dark: color(0.87, 0.57, 0.32)
    )

    static let failed: TranscriptPlatformColor = dynamic(
        light: color(0.77, 0.25, 0.25),
        dark: color(1.00, 0.42, 0.42)
    )

    // MARK: Blocks & chips
    // Backgrounds are translucent warm tints so they adapt to whatever
    // surface the turn card sits on.

    static let codeBlockBackground: TranscriptPlatformColor = dynamic(
        light: color(0.36, 0.33, 0.24, alpha: 0.07),
        dark: color(0.92, 0.90, 0.84, alpha: 0.07)
    )

    static let tableBackground: TranscriptPlatformColor = codeBlockBackground

    static let errorBackground: TranscriptPlatformColor = dynamic(
        light: color(0.77, 0.25, 0.25, alpha: 0.08),
        dark: color(1.00, 0.42, 0.42, alpha: 0.12)
    )

    static let inlineCodeBackground: TranscriptPlatformColor = dynamic(
        light: color(0.36, 0.33, 0.24, alpha: 0.10),
        dark: color(0.92, 0.90, 0.84, alpha: 0.11)
    )

    static let inlineCodeText: TranscriptPlatformColor = dynamic(
        light: color(0.68, 0.30, 0.20),
        dark: color(0.92, 0.64, 0.48)
    )

    static let toolSurface: TranscriptPlatformColor = dynamic(
        light: color(0.36, 0.33, 0.24, alpha: 0.07),
        dark: color(1.00, 1.00, 1.00, alpha: 0.08)
    )

    static let quoteBar: TranscriptPlatformColor = dynamic(
        light: color(0.36, 0.33, 0.24, alpha: 0.28),
        dark: color(0.92, 0.90, 0.84, alpha: 0.25)
    )

    /// User prompt bubble fill.
    static let userBubble: TranscriptPlatformColor = dynamic(
        light: color(0.36, 0.33, 0.24, alpha: 0.09),
        dark: color(0.92, 0.90, 0.84, alpha: 0.10)
    )

    /// Thinking card accent and background.
    static let thinkingAccent: TranscriptPlatformColor = dynamic(
        light: color(0.50, 0.36, 0.62),
        dark: color(0.72, 0.60, 0.82)
    )

    static let thinkingBackground: TranscriptPlatformColor = dynamic(
        light: color(0.50, 0.36, 0.62, alpha: 0.06),
        dark: color(0.72, 0.60, 0.82, alpha: 0.08)
    )

    /// Thematic breaks and the rule under table headers.
    static let hairline: TranscriptPlatformColor = dynamic(
        light: color(0.15, 0.15, 0.14, alpha: 0.16),
        dark: color(0.92, 0.90, 0.84, alpha: 0.18)
    )

    /// Horizontal padding inside decorated blocks — shared between the
    /// builder (paragraph indents) and the renderer (hairline insets).
    static var blockHorizontalPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 8
        #endif
    }

    /// Left/right padding inside the user message lane.
    static var userBubbleHorizontalPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 12
        #endif
    }

    /// Vertical padding around the glyph bounds for the drawn user bubble.
    /// The text view also uses this as its outer inset so first/last bubbles
    /// are not clipped.
    static var userBubbleVerticalPadding: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 7
        #endif
    }

    /// Width of the right-side user-message lane for the current text
    /// container. It leaves a stable leading gutter on desktop while capping
    /// very wide windows so long prompts remain readable.
    static func userBubbleLaneWidth(for containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        let gutter = userBubbleLeadingGutter(for: containerWidth)
        return max(0, min(userBubbleMaximumWidth, containerWidth - gutter))
    }

    private static func userBubbleLeadingGutter(for containerWidth: CGFloat) -> CGFloat {
        #if os(iOS)
        let minimum: CGFloat = 48
        let maximum: CGFloat = 120
        #else
        let minimum: CGFloat = 160
        let maximum: CGFloat = 360
        #endif
        return min(maximum, max(minimum, containerWidth * 0.26))
    }

    private static var userBubbleMaximumWidth: CGFloat {
        #if os(iOS)
        return 560
        #else
        return 760
        #endif
    }

    static var userBubbleMinimumWidth: CGFloat {
        #if os(iOS)
        return 64
        #else
        return 72
        #endif
    }

    // MARK: Diff

    static let diffAddedText: TranscriptPlatformColor = dynamic(
        light: color(0.13, 0.50, 0.24),
        dark: color(0.45, 0.80, 0.50)
    )

    static let diffRemovedText: TranscriptPlatformColor = dynamic(
        light: color(0.75, 0.22, 0.22),
        dark: color(0.95, 0.45, 0.45)
    )

    static let diffHunkText: TranscriptPlatformColor = dynamic(
        light: color(0.30, 0.42, 0.70),
        dark: color(0.55, 0.68, 0.92)
    )

    static let diffAddedBackground: TranscriptPlatformColor = dynamic(
        light: color(0.13, 0.60, 0.24, alpha: 0.10),
        dark: color(0.45, 0.80, 0.50, alpha: 0.13)
    )

    static let diffRemovedBackground: TranscriptPlatformColor = dynamic(
        light: color(0.75, 0.22, 0.22, alpha: 0.09),
        dark: color(0.95, 0.45, 0.45, alpha: 0.12)
    )

    static let diffHunkBackground: TranscriptPlatformColor = dynamic(
        light: color(0.30, 0.42, 0.70, alpha: 0.08),
        dark: color(0.55, 0.68, 0.92, alpha: 0.10)
    )

    // MARK: Syntax highlight

    static let codeKeyword: TranscriptPlatformColor = dynamic(
        light: color(0.62, 0.17, 0.51),
        dark: color(0.86, 0.55, 0.72)
    )

    static let codeString: TranscriptPlatformColor = dynamic(
        light: color(0.63, 0.30, 0.11),
        dark: color(0.82, 0.66, 0.45)
    )

    static let codeComment: TranscriptPlatformColor = dynamic(
        light: color(0.45, 0.50, 0.42),
        dark: color(0.52, 0.56, 0.47)
    )

    static let codeNumber: TranscriptPlatformColor = dynamic(
        light: color(0.14, 0.43, 0.60),
        dark: color(0.56, 0.74, 0.86)
    )

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
        case .divider: return nil // renderer draws a centered hairline
        case .userPrompt: return userBubble
        case .thinking: return thinkingBackground
        }
    }

    static func blockCornerRadius(for kind: TranscriptBlockKind) -> CGFloat {
        switch kind {
        case .code, .table, .error: return 6
        case .diffAdded, .diffRemoved, .diffHunk, .diffContext: return 3
        case .quote, .divider: return 0
        case .userPrompt: return 12
        case .thinking: return 6
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
