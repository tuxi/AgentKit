//
//  TurnChanges.swift
//  AgentKit
//
//  What one turn wrote to disk, reported by the Runtime on the terminal event.
//  The Runtime is the only side that can know this: write tools answer with
//  prose, and writes performed inside a workflow node never reach the client's
//  event stream. See code-agent docs/turn-diffstat-v1.md.
//
//  Lives in Core (not Features): the reducer stores it on the ExecutionGraph
//  and the projection layer reads it back, so it must sit below both.
//

import Foundation

/// Per-turn file change summary (`turn_finished.diffstat`).
///
/// The counts are **per-call sums**, not net changes: a file edited three times
/// contributes all three edits. The contract calls this out as deliberate — the
/// workspace is not guaranteed to be a git repository, so netting would need a
/// snapshot at turn start.
public struct TurnChanges: Sendable, Equatable {
    /// Kind of change for one path. `unknown` keeps a future server-side status
    /// from breaking decoding — it renders as a plain modified file.
    public enum Status: String, Sendable, Equatable {
        case added
        case modified
        case deleted
        case unknown

        public init(wire: String) {
            self = Status(rawValue: wire) ?? .unknown
        }
    }

    public struct FileChange: Sendable, Equatable, Identifiable {
        /// Workspace-relative, slash separated. Absolute when the write landed
        /// outside the workspace root.
        public let path: String
        public let added: Int
        public let removed: Int
        public let status: Status

        public var id: String { path }

        public init(path: String, added: Int, removed: Int, status: Status) {
            self.path = path
            self.added = added
            self.removed = removed
            self.status = status
        }
    }

    /// Files touched by this turn. The Runtime caps this list (200) while the
    /// three totals below stay full-turn, so `files.count` may be smaller than
    /// `filesChanged`; never derive the count from the array.
    public let files: [FileChange]
    /// Distinct paths written this turn — the contract's `files_changed`.
    public let filesChanged: Int
    public let addedLines: Int
    public let removedLines: Int

    public init(files: [FileChange], filesChanged: Int,
                addedLines: Int, removedLines: Int) {
        self.files = files
        self.filesChanged = filesChanged
        self.addedLines = addedLines
        self.removedLines = removedLines
    }

    /// Reports nothing — a turn that only read. The Runtime omits the field
    /// entirely in that case, so this only guards hand-built values.
    public var isEmpty: Bool { filesChanged <= 0 && files.isEmpty }

    /// "编辑 3 个文件" — the fragment appended to the collapsed turn summary.
    /// Nil when the turn wrote nothing, so callers never render "编辑 0 个文件".
    public var summaryLabel: String? {
        guard filesChanged > 0 else { return nil }
        return "编辑 \(filesChanged) 个文件"
    }

    /// One page of the change card, with the two counts a fold needs.
    public struct Preview: Sendable, Equatable {
        /// Rows to render, largest change first.
        public let rows: [FileChange]
        /// Shipped rows that stay behind "再显示 N 个文件".
        public let hiddenCount: Int
        /// Files the Runtime never sent because it clips the list — these need a
        /// "另有 N 个文件未列出" line, they can never be unfolded.
        public let withheldCount: Int
    }

    /// Fold math for the change card. It lives here, next to the data, because
    /// `rows.count + hiddenCount + withheldCount` must always equal
    /// `filesChanged` — a card whose parts don't add up is what this guards.
    ///
    /// Ties are broken by path so the order is deterministic: `sorted(by:)` is
    /// not stable in Swift, and rows that reshuffle between renders look like
    /// the turn is still running.
    public func preview(limit: Int) -> Preview {
        let ordered = files.sorted { lhs, rhs in
            let lhsSize = lhs.added + lhs.removed
            let rhsSize = rhs.added + rhs.removed
            return lhsSize == rhsSize ? lhs.path < rhs.path : lhsSize > rhsSize
        }
        let shown = max(0, min(limit, ordered.count))
        return Preview(
            rows: Array(ordered.prefix(shown)),
            hiddenCount: ordered.count - shown,
            withheldCount: max(0, filesChanged - ordered.count)
        )
    }
}

// MARK: - Wire decoding

extension TurnChanges {
    /// Decode the `diffstat` object. Missing totals fall back to the visible
    /// list, so a truncated or partial payload still renders a sane count
    /// instead of "0".
    init(wire: WireDiffStat) {
        let files = wire.files
            .filter { !$0.path.isEmpty }
            .map {
                FileChange(path: $0.path,
                           added: $0.added ?? 0,
                           removed: $0.removed ?? 0,
                           status: Status(wire: $0.status ?? "modified"))
            }
        self.files = files
        self.filesChanged = wire.filesChanged ?? files.count
        self.addedLines = wire.addedLines ?? files.reduce(0) { $0 + $1.added }
        self.removedLines = wire.removedLines ?? files.reduce(0) { $0 + $1.removed }
    }
}
