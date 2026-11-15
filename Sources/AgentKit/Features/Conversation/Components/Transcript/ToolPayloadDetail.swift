//
//  ToolPayloadDetail.swift
//  AgentKit
//
//  Bounded presentation of tool inputs and outputs for the iOS transcript and
//  the Inspector. The transcript shows a cheap summary first; the complete
//  JSON/text is formatted off the main actor, on demand, and cached per tool
//  call. This mirrors the P1-F.2 acceptance target: a large failed
//  `ui_preview` payload must not synchronously encode JSON or lay out its full
//  text when the tool group expands.
//

import ClientToolProtocol
import Foundation
import SwiftUI

// MARK: - Summary

/// Cheap descriptor of one payload. Building it never encodes JSON and never
/// creates attributed text; it only walks the raw strings to count bytes.
struct ToolPayloadSummary: Equatable, Sendable {
    let byteCount: Int
    let lineCount: Int?
    let topLevelKeys: [String]
    let previewText: String

    var isEmpty: Bool { byteCount == 0 }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var isInlineFriendly: Bool { byteCount <= ToolPayloadDetailMetrics.smallPayloadBytes }
}

struct ToolPayloadDetailSummary: Equatable, Sendable {
    let input: ToolPayloadSummary?
    let output: ToolPayloadSummary?
}

enum ToolPayloadDetailMetrics {
    /// Payloads at or below this size can render inline once, lazily, without
    /// the user opening a disclosure: the formatted text stays small enough
    /// that SwiftUI layout is bounded.
    static let smallPayloadBytes = 4 * 1024
    /// Upper bound for the transcript's on-demand preview. Anything larger is
    /// truncated there and remains available in the Inspector.
    static let transcriptPreviewBytes = 64 * 1024
    /// Upper bound for the first Inspector render. The complete payload stays
    /// one button away instead of being formatted on appearance.
    static let inspectorPreviewBytes = 128 * 1024
    /// A hard ceiling for the explicitly requested complete Inspector payload.
    /// Above this the Inspector offers copy and explains the omission rather
    /// than attempting an unbounded Text layout.
    static let inspectorCompleteBytes = 4 * 1024 * 1024
}

enum ToolPayloadSummaryBuilder {
    static func make(tool: ToolNodePayload) -> ToolPayloadDetailSummary {
        ToolPayloadDetailSummary(
            input: tool.args.flatMap { make(json: $0) },
            output: tool.output.isEmpty ? nil : make(text: tool.output)
        )
    }

    static func make(json value: JSONValue) -> ToolPayloadSummary? {
        let byteCount = approximateByteCount(value)
        guard byteCount > 0 else { return nil }
        return ToolPayloadSummary(
            byteCount: byteCount,
            lineCount: nil,
            topLevelKeys: topLevelKeys(value),
            previewText: previewJSON(value)
        )
    }

    static func make(text: String) -> ToolPayloadSummary? {
        let bytes = text.utf8.count
        guard bytes > 0 else { return nil }
        return ToolPayloadSummary(
            byteCount: bytes,
            lineCount: lineCount(text),
            topLevelKeys: [],
            previewText: preview(text)
        )
    }

    private static func approximateByteCount(_ value: JSONValue) -> Int {
        switch value {
        case .string(let string):
            return string.utf8.count
        case .object(let object):
            return object.reduce(object.count) { $0 + $1.key.utf8.count + approximateByteCount($1.value) }
        case .array(let array):
            return array.reduce(array.count) { $0 + approximateByteCount($1) }
        case .number, .integer, .bool, .null:
            return 1
        }
    }

    private static func topLevelKeys(_ value: JSONValue) -> [String] {
        guard case .object(let object) = value else { return [] }
        return object.keys.sorted()
    }

    private static func previewJSON(_ value: JSONValue) -> String {
        switch value {
        case .object(let object):
            let keys = object.keys.sorted().prefix(12)
            return keys.joined(separator: ", ")
        case .array(let array):
            return "array · \(array.count) items"
        case .string(let string):
            return preview(string, limit: 200)
        case .number(let number):
            return "\(number)"
        case .integer(let integer):
            return "\(integer)"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func preview(_ text: String, limit: Int = 400) -> String {
        guard text.utf8.count > limit * 2 else { return text }
        let prefix = String(text.prefix(limit))
        return prefix + "…"
    }

    private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
    }
}

// MARK: - Formatting

enum ToolPayloadKind: String, Sendable, Hashable, CaseIterable {
    case inputJSON
    case outputText
    case structuredOutput
}

struct FormattedToolPayload: Equatable, Sendable {
    let text: String
    let isTruncated: Bool
    let totalByteCount: Int
}

enum ToolPayloadFormatter {
    static func make(
        tool: ToolNodePayload,
        kind: ToolPayloadKind,
        limit: Int
    ) -> FormattedToolPayload? {
        switch kind {
        case .inputJSON:
            return tool.args.map { json($0, limit: limit) }
        case .structuredOutput:
            return tool.structuredOutput.map { json($0, limit: limit) }
        case .outputText:
            return tool.output.isEmpty ? nil : text(tool.output, limit: limit)
        }
    }

    static func json(_ value: JSONValue, limit: Int) -> FormattedToolPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let rendered = String(data: data, encoding: .utf8) else {
            return self.text(String(describing: value), limit: limit)
        }
        return self.text(rendered, limit: limit)
    }

    static func text(_ raw: String, limit: Int) -> FormattedToolPayload {
        let total = raw.utf8.count
        guard total > limit else {
            return FormattedToolPayload(text: raw, isTruncated: false, totalByteCount: total)
        }
        let prefix = String(decoding: raw.utf8.prefix(limit), as: UTF8.self)
        return FormattedToolPayload(text: prefix, isTruncated: true, totalByteCount: total)
    }
}

// MARK: - Cache

/// Caches formatted payloads by call identity. Formatting runs on the cache's
/// executor, never on the main actor, and identical requests do not re-encode.
actor ToolPayloadTextCache {
    static let shared = ToolPayloadTextCache()

    struct Key: Hashable, Sendable {
        let callID: String
        let kind: ToolPayloadKind
        let limit: Int
    }

    private var entries: [Key: FormattedToolPayload] = [:]
    private var order: [Key] = []
    private var totalBytes = 0
    private let capacity = 24
    private let byteBudget = 32 * 1024 * 1024

    func payload(
        for key: Key,
        make: @Sendable () -> FormattedToolPayload?
    ) -> FormattedToolPayload? {
        if let cached = entries[key] { return cached }
        guard let value = make() else { return nil }
        while totalBytes + value.text.utf8.count > byteBudget,
              let oldest = order.first {
            evict(oldest)
        }
        if order.count >= capacity, let oldest = order.first {
            evict(oldest)
        }
        entries[key] = value
        order.append(key)
        totalBytes += value.text.utf8.count
        return value
    }

    private func evict(_ key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes -= removed.text.utf8.count
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
    }
}

// MARK: - Main-actor state

@MainActor
final class ToolPayloadDetailModel: ObservableObject {
    @Published private(set) var summary: ToolPayloadDetailSummary?
    @Published private(set) var payloads: [ToolPayloadKind: FormattedToolPayload] = [:]
    @Published private(set) var loadingKinds: Set<ToolPayloadKind> = []

    private var preparedKey: String?
    private var prepareTask: Task<Void, Never>?
    private var loadedLimits: [ToolPayloadKind: Int] = [:]

    func prepare(tool: ToolNodePayload) {
        let key = Self.contentKey(tool)
        guard preparedKey != key else { return }
        preparedKey = key
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) {
                ToolPayloadSummaryBuilder.make(tool: tool)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.summary = summary
        }
    }

    func load(
        _ kind: ToolPayloadKind,
        tool: ToolNodePayload,
        limit: Int
    ) {
        guard loadedLimits[kind] != limit, !loadingKinds.contains(kind) else { return }
        let key = ToolPayloadTextCache.Key(
            callID: tool.callID,
            kind: kind,
            limit: limit
        )
        loadingKinds.insert(kind)
        Task { [weak self] in
            let payload = await ToolPayloadTextCache.shared.payload(for: key) {
                ToolPayloadFormatter.make(tool: tool, kind: kind, limit: limit)
            }
            guard let self else { return }
            self.loadingKinds.remove(kind)
            if let payload {
                self.loadedLimits[kind] = limit
                self.payloads[kind] = payload
            }
        }
    }

    static func contentKey(_ tool: ToolNodePayload) -> String {
        "\(tool.callID)|\(tool.status.rawValue)|\(tool.output.utf8.count)"
    }
}

// MARK: - Transcript section

/// One disclosure section for a tool payload. The summary line renders
/// immediately; the full text is formatted only after the section opens.
struct ToolPayloadDetailSection: View {
    let title: String
    let kind: ToolPayloadKind
    let summary: ToolPayloadSummary
    let tool: ToolNodePayload
    @ObservedObject var model: ToolPayloadDetailModel
    @Binding var isExpanded: Bool
    let maxHeight: CGFloat
    let horizontalScroll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.caption2)
                    Text(title)
                        .font(.caption2.weight(.semibold))
                    Text(summaryLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                payloadBody
            } else if !summary.previewText.isEmpty {
                Text(summary.previewText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .task(id: isExpanded) {
            if isExpanded {
                model.load(
                    kind,
                    tool: tool,
                    limit: ToolPayloadDetailMetrics.transcriptPreviewBytes
                )
            }
        }
    }

    @ViewBuilder
    private var payloadBody: some View {
        if let payload = model.payloads[kind] {
            VStack(alignment: .leading, spacing: 2) {
                if horizontalScroll {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(payload.text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: maxHeight)
                } else {
                    Text(payload.text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .frame(maxHeight: maxHeight, alignment: .topLeading)
                }
                if payload.isTruncated {
                    Text("Truncated preview. Use the Inspector for the complete payload.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryLine: String {
        var parts = [summary.sizeLabel]
        if let lineCount = summary.lineCount {
            parts.append("\(lineCount) lines")
        } else if !summary.topLevelKeys.isEmpty {
            parts.append("\(summary.topLevelKeys.count) keys")
        }
        return parts.joined(separator: " · ")
    }
}
