//
//  ConversationShareService.swift
//  AgentKit
//
//  Semantic, renderer-independent conversation export and system sharing.
//

import CoreGraphics
import CoreText
import Foundation
import OSLog

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ConversationShareFormat: String, CaseIterable, Identifiable {
    case image
    case pdf
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "分享图片"
        case .pdf: "分享 PDF"
        case .markdown: "分享 Markdown"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .markdown: "text.document"
        }
    }
}

struct ConversationShareDocument: Sendable {
    struct Turn: Sendable {
        let userPrompt: String?
        let assistantTranscript: String
    }

    let title: String
    let turns: [Turn]
    let webDocument: ConversationWebDocument?

    init(
        title: String,
        turns: [Turn],
        webDocument: ConversationWebDocument? = nil
    ) {
        self.title = title
        self.turns = turns
        self.webDocument = webDocument
    }

    var markdown: String {
        var parts = ["# \(title)"]
        for (index, turn) in turns.enumerated() {
            if turns.count > 1 {
                parts.append("## 第 \(index + 1) 轮")
            }
            if let prompt = turn.userPrompt, !prompt.isEmpty {
                parts.append("### You\n\n\(prompt)")
            }
            if !turn.assistantTranscript.isEmpty {
                parts.append("### Agent\n\n\(turn.assistantTranscript)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

@MainActor
enum ConversationShareService {
    private static let logger = Logger(subsystem: "AgentKit", category: "ConversationShare")
    private static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)

    static func document(for turn: ConversationTurn, title: String) -> ConversationShareDocument {
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn], generation: 1)
        return ConversationShareDocument(
            title: title,
            turns: [shareTurn(from: turn)],
            webDocument: ConversationWebDocumentBuilder.build(
                snapshot: snapshot,
                conversationID: "share-turn-\(turn.id)",
                revision: 1
            )
        )
    }

    static func document(for snapshot: RuntimeSnapshot, title: String) -> ConversationShareDocument {
        ConversationShareDocument(
            title: title,
            turns: snapshot.turns.map(shareTurn(from:)),
            webDocument: ConversationWebDocumentBuilder.build(
                snapshot: snapshot,
                conversationID: "share-conversation",
                revision: 1
            )
        )
    }

    static func share(
        _ document: ConversationShareDocument,
        as format: ConversationShareFormat,
        sourceView: AnyObject? = nil
    ) {
        Task { @MainActor in
            do {
                let url = try await export(document, as: format)
                present(url, sourceView: sourceView)
            } catch {
                logger.error("Unable to prepare conversation share: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func export(
        _ document: ConversationShareDocument,
        as format: ConversationShareFormat
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = safeFileName(document.title)
        let url = directory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(fileExtension(for: format))

        let data: Data
        switch format {
        case .image:
            if let webDocument = document.webDocument {
                data = try await ConversationStyledExportRenderer.render(
                    document: webDocument,
                    title: document.title,
                    output: .image
                )
            } else {
                data = try renderPNG(document)
            }
        case .pdf:
            if let webDocument = document.webDocument {
                data = try await ConversationStyledExportRenderer.render(
                    document: webDocument,
                    title: document.title,
                    output: .pdf
                )
            } else {
                data = try renderPDF(document)
            }
        case .markdown:
            data = Data(document.markdown.utf8)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func shareTurn(from turn: ConversationTurn) -> ConversationShareDocument.Turn {
        let prompt = turn.userPrompt?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTranscript = TranscriptCache.shared.transcript(
            for: turn,
            state: TranscriptDocumentState()
        ).copyText
        return .init(
            userPrompt: prompt.map(redactingLocalHome(in:)),
            assistantTranscript: redactingLocalHome(
                in: assistantText(from: fullTranscript, userPrompt: prompt)
            )
        )
    }

    private static func assistantText(from transcript: String, userPrompt: String?) -> String {
        var result = transcript
        if let userPrompt, result.hasPrefix(userPrompt) {
            result.removeFirst(userPrompt.count)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result == "Agent" { return "" }
        if result.hasPrefix("Agent\n") {
            result.removeFirst("Agent\n".count)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redactingLocalHome(in text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    private static func renderPNG(_ document: ConversationShareDocument) throws -> Data {
        let width = 1200
        let margin: CGFloat = 72
        let attributed = attributedContent(document, scale: 2)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: CGFloat(width) - margin * 2, height: .greatestFiniteMagnitude),
            nil
        )
        // Keep bitmap exports accepted by common share targets. PDF remains
        // available for unusually long turns.
        let height = min(12_000, max(640, Int(ceil(measured.height + margin * 2))))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ShareError.renderFailed
        }

        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(rect: CGRect(
            x: margin,
            y: margin,
            width: CGFloat(width) - margin * 2,
            height: CGFloat(height) - margin * 2
        ), transform: nil)
        CTFrameDraw(
            CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil),
            context
        )
        guard let image = context.makeImage() else { throw ShareError.renderFailed }

        #if os(macOS)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ShareError.renderFailed
        }
        return data
        #else
        guard let data = UIImage(cgImage: image).pngData() else { throw ShareError.renderFailed }
        return data
        #endif
    }

    private static func renderPDF(_ document: ConversationShareDocument) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ShareError.renderFailed
        }
        var mediaBox = pageRect
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw ShareError.renderFailed
        }

        let attributed = attributedContent(document, scale: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = pageRect.insetBy(dx: 46, dy: 52)
        var location = 0
        while location < CFAttributedStringGetLength(attributed) {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pageRect)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw ShareError.renderFailed }
            location += visible.length
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func attributedContent(
        _ document: ConversationShareDocument,
        scale: CGFloat
    ) -> CFAttributedString {
        let result = NSMutableAttributedString()
        let titleFont = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 24 * scale, nil)
        let bodyFont = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 11 * scale, nil)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): titleFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): bodyFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.13, alpha: 1)
        ]
        result.append(NSAttributedString(string: document.title + "\n\n", attributes: titleAttributes))
        result.append(NSAttributedString(string: visualText(document), attributes: bodyAttributes))
        return result
    }

    private static func visualText(_ document: ConversationShareDocument) -> String {
        var parts: [String] = []
        for (index, turn) in document.turns.enumerated() {
            if document.turns.count > 1 { parts.append("第 \(index + 1) 轮") }
            if let prompt = turn.userPrompt, !prompt.isEmpty {
                parts.append("YOU\n\(prompt)")
            }
            if !turn.assistantTranscript.isEmpty {
                parts.append("AGENT\n\(turn.assistantTranscript)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func fileExtension(for format: ConversationShareFormat) -> String {
        switch format {
        case .image: "png"
        case .pdf: "pdf"
        case .markdown: "md"
        }
    }

    private static func safeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Conversation" : cleaned).prefix(80))
    }

    private static func present(_ url: URL, sourceView: AnyObject?) {
        #if os(macOS)
        let providedAnchor = sourceView as? NSView
        let anchor = (providedAnchor?.window == nil ? nil : providedAnchor)
            ?? NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
        guard let anchor else { return }
        NSSharingServicePicker(items: [url]).show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY
        )
        #else
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 1,
                width: 1,
                height: 1
            )
        }
        presenter.present(controller, animated: true)
        #endif
    }

    private enum ShareError: Error {
        case renderFailed
    }
}
