//
//  TurnDisplaySplit.swift
//  AgentKit
//
//  L1 split shared by every renderer that folds a completed turn: everything
//  before the last non-empty answer block is "process", the answer (plus
//  trailing artifacts and any failures pulled forward) stays visible.
//
//  Mirrors the Web renderer's splitTurnForDisplay — the two platforms must fold
//  the same blocks, or the same turn reads differently depending on where you
//  open it.
//

import Foundation

public struct TurnDisplaySplit: Sendable, Equatable {
    /// Thinking / tools / workflow cards — hidden behind the collapsed header.
    public let process: [TurnBlock]
    /// What the user came for: the reply, plus failures that must not hide.
    public let answer: [TurnBlock]

    public init(process: [TurnBlock], answer: [TurnBlock]) {
        self.process = process
        self.answer = answer
    }

    /// Nothing to fold — the header would be a no-op affordance.
    public var hasProcess: Bool { !process.isEmpty }

    /// Blocks in display order for the expanded state.
    public var allBlocks: [TurnBlock] { process + answer }
}

extension TurnBlock {
    /// A failed tool / errored system line is never hidden by the process fold —
    /// an error the user cannot see is worse than a noisy timeline.
    public var isFailure: Bool {
        switch self {
        case .toolGroup(let group):
            return group.tools.contains { $0.status == .failed }
        case .system(_, let payload):
            return payload.kind == .error
        case .childStream(_, let payload):
            return payload.status == .failed || payload.status == .canceled
        case .workflow(_, let payload):
            return payload.status == .failed || payload.status == .canceled
        case .text, .thinking, .artifact:
            return false
        }
    }

    /// New activity groups fold as a whole; their failures are surfaced in the
    /// always-visible turn header. Legacy error rows keep their existing placement.
    var staysOutsideProcess: Bool {
        if case .toolGroup(let group) = self, group.isActivityGroup { return false }
        return isFailure
    }

    /// Only spoken answer text counts as "the answer": thinking, tools and
    /// artifacts stay on the process side even when they trail the reply.
    public var isAnswerText: Bool {
        guard case .text(_, let payload) = self else { return false }
        return !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ConversationTurn {
    /// Live turns never split — the work is the content while it runs, and
    /// folding it would leave an empty screen.
    public var displaySplit: TurnDisplaySplit {
        guard !isLive else {
            return TurnDisplaySplit(process: [], answer: blocks)
        }

        var answerIndex: Int?
        for index in blocks.indices.reversed() where blocks[index].isAnswerText {
            answerIndex = index
            break
        }

        // Tool-only turn: fold the work. Activity failures remain visible in
        // the header count; standalone legacy errors keep their existing rows.
        guard let answerIndex else {
            return TurnDisplaySplit(
                process: blocks.filter { !$0.staysOutsideProcess },
                answer: blocks.filter(\.staysOutsideProcess)
            )
        }

        let leading = blocks[..<answerIndex]
        return TurnDisplaySplit(
            process: leading.filter { !$0.staysOutsideProcess },
            answer: leading.filter(\.staysOutsideProcess) + blocks[answerIndex...]
        )
    }

    /// The "用时 24分40秒 · 编辑 3 个文件" line above a completed answer.
    /// Nil when neither half is known, so the header never renders as a stub.
    public var processSummaryLabel: String? {
        var parts: [String] = []
        if let duration = formattedDuration { parts.append("用时 \(duration)") }
        if let changes = changes?.summaryLabel { parts.append(changes) }
        if let failures = processFailureSummary { parts.append(failures) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var processFailureSummary: String? {
        let failed = displaySplit.process.reduce(0) { count, block in
            guard case .toolGroup(let group) = block else { return count }
            return count + group.tools.filter { $0.status == .failed }.count
        }
        return failed > 0 ? ToolTranscriptText().text(failed == 1 ? "failures.one" : "failures.many", failed) : nil
    }

    /// Header text for the fold affordance. Facts when we have them, otherwise
    /// the generic label — nil only when there is nothing to fold *and* nothing
    /// to report, because a folded trace with no visible header would be
    /// unreachable (old history has no wall clock).
    public func processHeaderLabel(hasProcess: Bool) -> String? {
        if let label = processSummaryLabel { return label }
        return hasProcess ? "查看执行过程" : nil
    }
}

// MARK: - Duration text

/// Compact human duration — "48秒" / "24分40秒" / "1小时5分" / "2小时".
///
/// Shared by the finished header (`formattedDuration`) and the live clock, so a
/// turn can never read "24分40秒" while running and something else once done.
public enum TurnDurationText {
    public static func string(seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 {
            return "\(total)秒"
        }
        if total < 3600 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes)分" : "\(minutes)分\(rest)秒"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours)小时" : "\(hours)小时\(minutes)分"
    }
}
