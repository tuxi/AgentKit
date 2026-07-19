//
//  MacNativeChatTimeline.swift
//  AgentKit
//
//  The macOS chat scroll container. AppKit owns scrolling plus native Turn and
//  Thinking rows; SwiftUI remains only for compatibility extension rows.
//

#if os(macOS)
import AppKit
import SwiftUI

/// A view-based `NSTableView` timeline whose bottom-pinning happens only after
/// AppKit has calculated the updated document height. This avoids scrolling to
/// SwiftUI's temporary lazy-stack height during streaming updates.
@MainActor
struct MacNativeChatTimeline: NSViewRepresentable {
    let snapshot: RuntimeSnapshot
    let timelineExtensions: [any TimelineExtension]
    let conversationID: String?

    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ChatScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak coordinator = context.coordinator] in
            coordinator?.willHandleUserScroll()
        }
        scrollView.onUserScrollEnded = { [weak coordinator = context.coordinator] in
            coordinator?.didHandleUserScroll()
        }
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.scrollViewDidLayout()
        }

        let tableView = NSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .none
        // Row height is supplied synchronously by Coordinator. In particular,
        // Turn rows never ask NSHostingView/SwiftUI for an ideal size.
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 44
        tableView.autoresizingMask = [.width]

        let column = NSTableColumn(identifier: .chatTimelineColumn)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        scrollView.documentView = tableView

        context.coordinator.attach(tableView: tableView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Capture pin state before invalidating row heights. A row may grow by
        // many screenfuls while streaming, but its old geometry is the only
        // reliable indication of whether the user was following it.
        let wasPinnedToBottom = coordinator.isPinnedToBottom
        let change = coordinator.replaceRows(with: makeRows())

        if change.isNewConversation {
            coordinator.isPinnedToBottom = true
            coordinator.reloadForNewConversation()
        } else if change.requiresFullReload {
            coordinator.reloadAllRows(followBottom: wasPinnedToBottom)
        } else if !change.changedRows.isEmpty {
            coordinator.applyChangedRows(
                change.changedRows,
                followBottom: wasPinnedToBottom
            )
        }
    }

    private func makeRows() -> [TimelineRow] {
        var rows: [TimelineRow] = []

        for turn in snapshot.turns {
            rows.append(.turn(turn))
            for timelineExtension in timelineExtensions {
                if let content = timelineExtension.makeContent(for: turn.id) {
                    rows.append(.extensionContent(
                        turnID: turn.id,
                        extensionID: timelineExtension.id,
                        generation: snapshot.generation,
                        content: content
                    ))
                }
            }
        }

        if snapshot.isLive, snapshot.turnStartedAt != nil {
            rows.append(.thinking(
                turnStartedAt: snapshot.turnStartedAt,
                isThinking: snapshot.modelStartedAt != nil,
                modelStats: snapshot.modelStats
            ))
        }

        return rows
    }

    // MARK: - Table rows

    fileprivate enum TimelineRow {
        case turn(ConversationTurn)
        // Extension views are host-owned and do not expose an equality
        // contract. Generation intentionally invalidates these rows whenever
        // a snapshot arrives, while normal turn rows remain value-diffed.
        case extensionContent(turnID: String, extensionID: String, generation: UInt64, content: AnyView)
        case thinking(turnStartedAt: Date?, isThinking: Bool, modelStats: ModelStats?)

        var identity: String {
            switch self {
            case .turn(let turn):
                return "turn.\(turn.id)"
            case .extensionContent(let turnID, let extensionID, _, _):
                return "extension.\(extensionID).\(turnID)"
            case .thinking:
                return "thinking-timer"
            }
        }

        func hasSameContent(as other: TimelineRow) -> Bool {
            switch (self, other) {
            case (.turn(let lhs), .turn(let rhs)):
                return lhs == rhs
            case (.extensionContent(_, _, let lhs, _), .extensionContent(_, _, let rhs, _)):
                return lhs == rhs
            case (.thinking(let lhsStart, let lhsThinking, let lhsStats),
                  .thinking(let rhsStart, let rhsThinking, let rhsStats)):
                return lhsStart == rhsStart
                    && lhsThinking == rhsThinking
                    && lhsStats == rhsStats
            default:
                return false
            }
        }

        @MainActor
        func hostedView(workspaceStore: WorkspaceStore, openURL: OpenURLAction) -> AnyView {
            let content: AnyView
            switch self {
            case .turn(let turn):
                content = AnyView(TurnView(turn: turn).equatable())
            case .extensionContent(_, _, _, let extensionContent):
                content = extensionContent
            case .thinking(let turnStartedAt, let isThinking, let modelStats):
                content = AnyView(ThinkingTimerView(
                    turnStartedAt: turnStartedAt,
                    isThinking: isThinking,
                    modelStats: modelStats
                ))
            }

            return AnyView(
                TimelineRowContainer(row: self, content: content)
                    // NSTableView may hand this hosting view to a different
                    // row. Make the SwiftUI identity follow the row rather
                    // than the reusable cell, otherwise TurnView's @State can
                    // briefly render the previously visible transcript.
                    .id(identity)
                    .environment(workspaceStore)
                    .environment(\EnvironmentValues.openURL, openURL)
            )
        }
    }

    private struct TimelineRowContainer: View {
        let row: TimelineRow
        let content: AnyView

        var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
        }

        private var topPadding: CGFloat {
            6
        }

        private var bottomPadding: CGFloat {
            switch row {
            case .thinking: return 16
            default: return 6
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MacNativeChatTimeline
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        private var rows: [TimelineRow] = []
        private var conversationID: String?
        private var isPerformingProgrammaticScroll = false
        private var isHandlingUserScroll = false
        private var awaitingInitialBottomPin = false
        private var isAligningInitialBottomPin = false
        private var geometryReconciliationScheduled = false
        private var initialGeometryRetryCount = 0
        private var visibleRowRedrawScheduled = false
        private var heightCache: [String: CGFloat] = [:]
        private var heightCacheWidth: CGFloat = 0
        private var lastLaidOutWidth: CGFloat = 0
        private var isInvalidatingHeightsForWidth = false
        private var documentStates: [String: TranscriptDocumentState] = [:]
        var isPinnedToBottom = true

        init(parent: MacNativeChatTimeline) {
            self.parent = parent
        }

        func attach(tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollWillBegin),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollDidEnd),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let targetRow = rows[row]

            if case .turn(let turn) = targetRow {
                let cell: NativeTurnTableCellView
                if let reusable = tableView.makeView(
                    withIdentifier: .nativeTurnTimelineCell,
                    owner: self
                ) as? NativeTurnTableCellView {
                    cell = reusable
                } else {
                    cell = NativeTurnTableCellView(identifier: .nativeTurnTimelineCell)
                }

                configure(cell, with: turn, rowIdentity: targetRow.identity)
                return cell
            }

            if case .thinking(let startedAt, let isThinking, let modelStats) = targetRow {
                let cell: NativeThinkingTableCellView
                if let reusable = tableView.makeView(
                    withIdentifier: .nativeThinkingTimelineCell,
                    owner: self
                ) as? NativeThinkingTableCellView {
                    cell = reusable
                } else {
                    cell = NativeThinkingTableCellView(identifier: .nativeThinkingTimelineCell)
                }
                cell.configure(
                    startedAt: startedAt,
                    isThinking: isThinking,
                    modelStats: modelStats
                )
                return cell
            }

            let cell: TimelineTableCellView
            if let reusable = tableView.makeView(
                withIdentifier: .chatTimelineCell,
                owner: self
            ) as? TimelineTableCellView {
                cell = reusable
            } else {
                cell = TimelineTableCellView(identifier: .chatTimelineCell)
            }

            // Mirror UITableView's cellForRow(at:): configure the reusable
            // native cell from the model at the requested row every time.
            cell.configure(
                rowID: targetRow.identity,
                rootView: targetRow.hostedView(
                    workspaceStore: parent.workspaceStore,
                    openURL: parent.openURL
                )
            )
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            didAdd rowView: NSTableRowView,
            forRow row: Int
        ) {
            // A large wheel/trackpad delta can make a reusable cell visible
            // without an intervening layout pass. Complete its layout now that
            // NSTableView has assigned the final row frame, otherwise a tall
            // transcript can momentarily draw the previous row's small frame.
            rowView.needsLayout = true
            rowView.layoutSubtreeIfNeeded()
            if let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? NativeTurnTableCellView {
                cell.prepareForDisplay()
                cell.redrawTranscript(
                    intersecting: tableView.visibleRect,
                    from: tableView
                )
            }
        }

        /// Turn rows are updated in place instead of going through
        /// reloadData(forRowIndexes:). This keeps the same NSTextView alive,
        /// preserving selection and limiting TextKit relayout to the changed
        /// suffix. Compatibility rows still use normal AppKit reloads.
        func applyChangedRows(_ changedRows: [Int], followBottom: Bool) {
            guard let tableView else { return }
            performViewportMutation(followBottom: followBottom) {
                var compatibilityRows = IndexSet()

                for row in changedRows where rows.indices.contains(row) {
                    switch rows[row] {
                    case .turn(let turn):
                        if let cell = tableView.view(
                            atColumn: 0,
                            row: row,
                            makeIfNecessary: false
                        ) as? NativeTurnTableCellView {
                            configure(cell, with: turn, rowIdentity: rows[row].identity)
                        }
                    case .thinking(let startedAt, let isThinking, let modelStats):
                        if let cell = tableView.view(
                            atColumn: 0,
                            row: row,
                            makeIfNecessary: false
                        ) as? NativeThinkingTableCellView {
                            cell.configure(
                                startedAt: startedAt,
                                isThinking: isThinking,
                                modelStats: modelStats
                            )
                        }
                    default:
                        compatibilityRows.insert(row)
                    }
                }

                if !compatibilityRows.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: compatibilityRows,
                        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                    )
                }
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(changedRows))
            }
        }

        func reloadForNewConversation() {
            guard let tableView else { return }
            awaitingInitialBottomPin = true
            // Keep the reset position out of the rendered frame. The table is
            // revealed only after the final viewport width, every explicit row
            // height and the bottom origin have been applied together.
            tableView.alphaValue = 0
            lastLaidOutWidth = 0
            initialGeometryRetryCount = 0
            performViewportMutation(followBottom: false) {
                tableView.reloadData()
            }
            scheduleGeometryReconciliation()
        }

        func reloadAllRows(followBottom: Bool) {
            guard let tableView else { return }
            performViewportMutation(followBottom: followBottom) {
                tableView.reloadData()
                if tableView.numberOfRows > 0, stableTableWidth() != nil {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(
                        integersIn: 0..<tableView.numberOfRows
                    ))
                }
            }
        }

        private func configure(
            _ cell: NativeTurnTableCellView,
            with turn: ConversationTurn,
            rowIdentity: String
        ) {
            let dispatcher = TurnActionDispatcher(
                turn: turn,
                store: parent.workspaceStore,
                openURL: parent.openURL
            )
            cell.configure(
                turn: turn,
                state: documentStates[turn.id] ?? TranscriptDocumentState(),
                dispatcher: dispatcher,
                onStateChange: { [weak self, weak tableView] state in
                    guard let self, let tableView else { return }
                    self.documentStates[turn.id] = state
                    self.heightCache.removeValue(forKey: rowIdentity)
                    guard let currentRow = self.rows.firstIndex(where: {
                        $0.identity == rowIdentity
                    }) else { return }
                    self.performViewportMutation(followBottom: self.isPinnedToBottom) {
                        tableView.noteHeightOfRows(
                            withIndexesChanged: IndexSet(integer: currentRow)
                        )
                    }
                }
            )
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return tableView.rowHeight }
            guard let width = stableTableWidth() else {
                return heightCache[rows[row].identity] ?? tableView.rowHeight
            }
            if abs(width - heightCacheWidth) > 0.5 {
                heightCacheWidth = width
                heightCache.removeAll(keepingCapacity: true)
            }

            let timelineRow = rows[row]
            if let cached = heightCache[timelineRow.identity] { return cached }
            let measured = synchronousHeight(for: timelineRow, width: width)
            heightCache[timelineRow.identity] = measured
            return measured
        }

        func willHandleUserScroll() {
            isHandlingUserScroll = true
        }

        func didHandleUserScroll() {
            guard !isPerformingProgrammaticScroll else { return }
            isPinnedToBottom = checkIfAtBottom()
            isHandlingUserScroll = false
            redrawVisibleTranscriptRows()
            scheduleVisibleRowRedraw()
        }

        func scrollViewDidLayout() {
            // `NSScrollView.layout()` can be reached while NSTableView is
            // inside a delegate callback. Mutating columns or row heights from
            // there is reentrant and can leave the reusable-row map empty for
            // a valid scroll range (the observed white screen). Reconcile on
            // the next main-queue turn, outside the table's layout transaction.
            scheduleGeometryReconciliation()
        }

        private func refreshHeightsForCurrentWidthIfNeeded() {
            guard !isInvalidatingHeightsForWidth,
                  let tableView,
                  tableView.numberOfRows > 0,
                  let width = stableTableWidth() else { return }
            guard abs(width - lastLaidOutWidth) > 0.5 else { return }
            lastLaidOutWidth = width
            heightCacheWidth = width
            heightCache.removeAll(keepingCapacity: true)

            isInvalidatingHeightsForWidth = true
            performViewportMutation(
                followBottom: isPinnedToBottom && !awaitingInitialBottomPin
            ) {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(
                    integersIn: 0..<tableView.numberOfRows
                ))
            }
            isInvalidatingHeightsForWidth = false
        }

        @objc private func boundsDidChange() {
            redrawVisibleTranscriptRows()
            scheduleVisibleRowRedraw()
            guard isHandlingUserScroll, !isPerformingProgrammaticScroll else { return }
            isPinnedToBottom = checkIfAtBottom()
        }

        private func redrawVisibleTranscriptRows() {
            guard let tableView else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            let firstRow = max(0, visibleRows.location - 1)
            let rowLimit = min(tableView.numberOfRows, NSMaxRange(visibleRows) + 1)
            let prefetchRect = tableView.visibleRect.insetBy(dx: 0, dy: -128)
            for row in firstRow..<rowLimit {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? NativeTurnTableCellView else { continue }
                cell.prepareForDisplay()
                cell.redrawTranscript(
                    intersecting: prefetchRect,
                    from: tableView
                )
            }
            tableView.setNeedsDisplay(tableView.visibleRect)
            tableView.displayIfNeeded()
        }

        /// NSTableView updates its reusable-row map near the end of the scroll
        /// transaction. The immediate pass above covers the current frame;
        /// this coalesced pass runs after that transaction and prevents AppKit
        /// from committing an empty backing-store slice over the rendered row.
        private func scheduleVisibleRowRedraw() {
            guard !visibleRowRedrawScheduled else { return }
            visibleRowRedrawScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visibleRowRedrawScheduled = false
                self.redrawVisibleTranscriptRows()
            }
        }

        @objc private func liveScrollWillBegin() {
            isHandlingUserScroll = true
        }

        @objc private func liveScrollDidEnd() {
            didHandleUserScroll()
        }

        fileprivate func replaceRows(with newRows: [TimelineRow]) -> TimelineChange {
            let oldRows = rows
            let isNewConversation = conversationID != parent.conversationID
                || (oldRows.isEmpty && !newRows.isEmpty)
            conversationID = parent.conversationID
            rows = newRows

            guard !isNewConversation,
                  oldRows.map(\.identity) == newRows.map(\.identity) else {
                heightCache.removeAll(keepingCapacity: true)
                let liveTurnIDs = Set(newRows.compactMap { row -> String? in
                    if case .turn(let turn) = row { return turn.id }
                    return nil
                })
                documentStates = documentStates.filter { liveTurnIDs.contains($0.key) }
                return TimelineChange(
                    requiresFullReload: true,
                    changedRows: [],
                    isNewConversation: isNewConversation
                )
            }

            let changedRows = newRows.indices.filter {
                !newRows[$0].hasSameContent(as: oldRows[$0])
            }
            for row in changedRows {
                heightCache.removeValue(forKey: newRows[row].identity)
            }
            return TimelineChange(
                requiresFullReload: false,
                changedRows: changedRows,
                isNewConversation: false
            )
        }

        private func synchronousHeight(for row: TimelineRow, width: CGFloat) -> CGFloat {
            if case .turn(let turn) = row {
                let state = documentStates[turn.id] ?? TranscriptDocumentState()
                let transcript = TranscriptCache.shared.transcript(for: turn, state: state)
                // Do not reuse one TextKit layout manager across unrelated
                // turns. Its fragment cache can briefly retain the previous
                // document's geometry, producing a height that disagrees with
                // the actual cell and leaving a blank scroll range.
                let transcriptMeasurer = NativeTranscriptTextView(onAction: { _ in })
                transcriptMeasurer.apply(
                    attributedText: transcript.attributedString,
                    actions: transcript.actions,
                    onAction: { _ in }
                )
                let contentWidth = max(1, width - NativeTurnTableCellView.horizontalPadding * 2)
                let textHeight = transcriptMeasurer.sizeThatFits(width: contentWidth)?.height ?? 1
                let controlsHeight = NativeTurnTableCellView.showsControls(
                    turn: turn,
                    copyText: transcript.copyText
                ) ? NativeTurnTableCellView.controlsAreaHeight : 0
                return ceil(textHeight
                    + NativeTurnTableCellView.verticalPadding * 2
                    + controlsHeight)
            }

            if case .thinking = row {
                return NativeThinkingTableCellView.rowHeight
            }

            // Todo/host extensions remain compatibility rows for the
            // moment. Their height is frozen synchronously here, so NSTableView
            // still never enters automatic-row-height mode.
            let host = NSHostingView(rootView: row.hostedView(
                workspaceStore: parent.workspaceStore,
                openURL: parent.openURL
            ))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
            host.layoutSubtreeIfNeeded()
            return max(1, ceil(host.fittingSize.height))
        }

        func checkIfAtBottom(tolerance: CGFloat = 10) -> Bool {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return true }
            let currentY = scrollView.contentView.bounds.origin.y
            let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            return abs(currentY - maxY) <= tolerance
        }

        @discardableResult
        func scrollToLastRowImmediately() -> Bool {
            guard let tableView,
                  let scrollView,
                  scrollView.window != nil,
                  scrollView.contentView.bounds.height > 0,
                  stableTableWidth() != nil else { return false }
            let lastRow = tableView.numberOfRows - 1
            guard lastRow >= 0 else {
                scrollToBottomImmediately()
                return true
            }
            performViewportMutation(followBottom: true) {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(
                    integersIn: 0..<tableView.numberOfRows
                ))
                tableView.tile()
            }
            return true
        }

        private func alignInitialBottomIfPossible() {
            guard awaitingInitialBottomPin, !isAligningInitialBottomPin else { return }
            isAligningInitialBottomPin = true
            defer { isAligningInitialBottomPin = false }
            if scrollToLastRowImmediately() {
                awaitingInitialBottomPin = false
                initialGeometryRetryCount = 0
                tableView?.alphaValue = 1
            }
        }

        /// SwiftUI and AppKit can finish their outer and inner layout passes in
        /// either order. One coalesced main-queue reconciliation gives the
        /// table final viewport geometry without introducing a timed delay.
        private func scheduleGeometryReconciliation() {
            guard !geometryReconciliationScheduled else { return }
            geometryReconciliationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryReconciliationScheduled = false
                self.synchronizeTableWidthToViewport()
                self.refreshHeightsForCurrentWidthIfNeeded()
                self.alignInitialBottomIfPossible()
                if self.awaitingInitialBottomPin,
                   self.scrollView?.window != nil,
                   self.initialGeometryRetryCount < 3 {
                    self.initialGeometryRetryCount += 1
                    self.scheduleGeometryReconciliation()
                }
            }
        }

        func scrollToBottomImmediately() {
            performViewportMutation(followBottom: true) {}
        }

        private func stableTableWidth() -> CGFloat? {
            guard let tableView,
                  let scrollView,
                  scrollView.window != nil else { return nil }
            let columnWidth = tableView.tableColumns.first?.width ?? 0
            let viewportWidth = scrollView.contentView.bounds.width
            // The document view can retain its old bounds for one extra layout
            // turn while the column and clip view already have final geometry.
            // Measuring against the visible column is deterministic; requiring
            // all three widths to match can strand the initial pin forever.
            guard viewportWidth > 100,
                  columnWidth > 100 else { return nil }
            return min(columnWidth, viewportWidth)
        }

        private func synchronizeTableWidthToViewport() {
            guard let tableView,
                  let scrollView,
                  scrollView.window != nil else { return }
            let width = scrollView.contentView.bounds.width
            guard width > 100 else { return }

            if abs(tableView.frame.width - width) > 0.5 {
                tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
            }
            if let column = tableView.tableColumns.first,
               abs(column.width - width) > 0.5 {
                column.width = width
            }
        }

        private func layoutTableBeforeScrolling() {
            guard let scrollView, let tableView else { return }
            scrollView.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
        }

        private func scrollToBottom() {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let lastRowBottom: CGFloat
            if let tableView, tableView.numberOfRows > 0 {
                lastRowBottom = tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
            } else {
                lastRowBottom = 0
            }
            let contentHeight = max(documentView.frame.height, lastRowBottom)
            let maxY = max(0, contentHeight - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
            isPinnedToBottom = true
        }

        private func performViewportMutation(
            followBottom: Bool,
            _ changes: () -> Void
        ) {
            guard let tableView else { return }
            let wasProgrammatic = isPerformingProgrammaticScroll
            isPerformingProgrammaticScroll = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                changes()
                tableView.layoutSubtreeIfNeeded()
                if followBottom { scrollToBottom() }
            }
            isPerformingProgrammaticScroll = wasProgrammatic
        }

    }
}

// MARK: - Supporting AppKit views

private extension NSUserInterfaceItemIdentifier {
    static let chatTimelineColumn = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.Column")
    static let chatTimelineCell = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.Cell")
    static let nativeTurnTimelineCell = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.NativeTurnCell")
    static let nativeThinkingTimelineCell = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.NativeThinkingCell")
}

/// A fully native Turn row. Its TextKit view is updated incrementally and its
/// frame is derived from the same synchronous measurement used by the table's
/// height delegate—there is no SwiftUI host or automatic-height negotiation.
private final class NativeTurnTableCellView: NSTableCellView {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 6
    static let controlsAreaHeight: CGFloat = 28

    override var isFlipped: Bool { true }

    private let transcriptView = NativeTranscriptTextView(onAction: { _ in })
    private lazy var copyButton = NSButton(frame: .zero)
    private lazy var shareButton = NSButton(frame: .zero)
    private lazy var assetsButton = NSButton(frame: .zero)
    private var representedTurnID: String?
    private var turn: ConversationTurn?
    private var state = TranscriptDocumentState()
    private var transcript: AttributedTranscript?
    private var dispatcher: TurnActionDispatcher?
    private var onStateChange: ((TranscriptDocumentState) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        transcriptView.autoresizingMask = []
        addSubview(transcriptView)
        
        configureButton(copyButton, imageName: "doc.on.doc", toolTip: "复制回复")
        copyButton.target = self
        copyButton.action = #selector(copyReply)
        addSubview(copyButton)
        copyButton.title = ""

        configureButton(shareButton, imageName: "square.and.arrow.up", toolTip: "分享本轮对话")
        shareButton.target = self
        shareButton.action = #selector(showShareMenu)
        addSubview(shareButton)
        shareButton.title = ""

        configureButton(assetsButton, imageName: "tray.full", toolTip: "查看本轮资产")
        assetsButton.target = self
        assetsButton.action = #selector(showAssets)
        addSubview(assetsButton)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        turn: ConversationTurn,
        state: TranscriptDocumentState,
        dispatcher: TurnActionDispatcher,
        onStateChange: @escaping (TranscriptDocumentState) -> Void
    ) {
        if representedTurnID != turn.id {
            transcriptView.resetForReuse()
            self.state = state
        } else {
            self.state = state
        }
        representedTurnID = turn.id
        self.turn = turn
        self.dispatcher = dispatcher
        self.onStateChange = onStateChange
        rebuildTranscript()
    }

    override func layout() {
        super.layout()
        guard transcript != nil else { return }
        let contentWidth = max(1, bounds.width - Self.horizontalPadding * 2)
        let textHeight = transcriptView.sizeThatFits(width: contentWidth)?.height ?? 1
        transcriptView.frame = NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: contentWidth,
            height: textHeight
        )

        guard !copyButton.isHidden || !shareButton.isHidden || !assetsButton.isHidden else { return }
        let controlsY = Self.verticalPadding + textHeight + 4
        var x = Self.horizontalPadding
        if !copyButton.isHidden {
            copyButton.frame = NSRect(x: x, y: controlsY, width: 22, height: 20)
            x += 30
        }
        if !shareButton.isHidden {
            shareButton.frame = NSRect(x: x, y: controlsY, width: 22, height: 20)
            x += 30
        }
        if !assetsButton.isHidden {
            assetsButton.frame = NSRect(x: x, y: controlsY, width: 46, height: 20)
        }
    }

    func prepareForDisplay() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func redrawTranscript(intersecting visibleRect: NSRect, from ancestor: NSView) {
        var dirtyRect = transcriptView.convert(visibleRect, from: ancestor)
        dirtyRect = dirtyRect.insetBy(
            dx: -2,
            dy: -TranscriptTheme.userBubbleVerticalPadding
        ).intersection(transcriptView.bounds)
        guard !dirtyRect.isEmpty else { return }
        if let layoutManager = transcriptView.layoutManager,
           let textContainer = transcriptView.textContainer {
            layoutManager.ensureLayout(forBoundingRect: dirtyRect, in: textContainer)
        }
        transcriptView.setNeedsDisplay(dirtyRect)
        transcriptView.displayIfNeeded()
    }

    static func showsControls(turn: ConversationTurn, copyText: String) -> Bool {
        (!copyText.isEmpty && !isAnswerStreaming(turn)) || !assets(in: turn).isEmpty
    }

    private func rebuildTranscript() {
        guard let turn else { return }
        let transcript = TranscriptCache.shared.transcript(for: turn, state: state)
        self.transcript = transcript
        transcriptView.apply(
            attributedText: transcript.attributedString,
            actions: transcript.actions,
            onAction: { [weak self] action in self?.handle(action) }
        )

        copyButton.isHidden = transcript.copyText.isEmpty || Self.isAnswerStreaming(turn)
        shareButton.isHidden = copyButton.isHidden
        let assetCount = Self.assets(in: turn).count
        assetsButton.isHidden = assetCount == 0
        assetsButton.title = assetCount == 0 ? "" : "\(assetCount)"
        needsLayout = true
    }

    private func handle(_ action: TranscriptAction) {
        switch action {
        case .toggleTool(let callID):
            state.toggleTool(callID: callID)
            rebuildTranscript()
            onStateChange?(state)
        case .toggleThinking(let id):
            state.toggleThinking(id: id)
            rebuildTranscript()
            onStateChange?(state)
        default:
            dispatcher?.handle(action)
        }
    }

    @objc private func copyReply() {
        guard let text = transcript?.copyText, !text.isEmpty else { return }
        Clipboard.copy(text)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
        }
    }

    @objc private func showShareMenu() {
        let menu = NSMenu(title: "分享本轮对话")
        for format in ConversationShareFormat.allCases {
            let item = NSMenuItem(
                title: format.title,
                action: #selector(shareTurn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = format.rawValue
            item.image = NSImage(systemSymbolName: format.systemImage, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: shareButton.bounds.maxY + 2),
            in: shareButton
        )
    }

    @objc private func shareTurn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let format = ConversationShareFormat(rawValue: raw) else { return }
        dispatcher?.shareTurn(as: format, sourceView: shareButton)
    }

    @objc private func showAssets() {
        dispatcher?.showTurnAssets()
    }

    private func configureButton(_ button: NSButton, imageName: String, toolTip: String) {
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.toolTip = toolTip
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.contentTintColor = .secondaryLabelColor
    }

    private static func isAnswerStreaming(_ turn: ConversationTurn) -> Bool {
        for block in turn.blocks.reversed() {
            if case .text(_, let payload) = block { return payload.isStreaming }
        }
        return false
    }

    private static func assets(in turn: ConversationTurn) -> [AgentAssetRef] {
        var result: [AgentAssetRef] = []
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools { result.append(contentsOf: tool.assets) }
        }
        return AgentAssetDisplayIndex.unique(result)
    }
}

/// Fixed-height native working indicator. Only its label string changes on the
/// timer; it never participates in row-height invalidation while tokens stream.
private final class NativeThinkingTableCellView: NSTableCellView {
    static let rowHeight: CGFloat = 38

    override var isFlipped: Bool { true }

    private lazy var iconView = NSImageView(frame: .zero)
    private lazy var label = NSTextField(labelWithString: "")
    private var startedAt: Date?
    private var isThinking = false
    private var modelStats: ModelStats?
    private var timer: Timer?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        iconView.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func configure(startedAt: Date?, isThinking: Bool, modelStats: ModelStats?) {
        let startChanged = self.startedAt != startedAt
        self.startedAt = startedAt
        self.isThinking = isThinking
        self.modelStats = modelStats
        updateLabel()

        if startChanged || timer == nil {
            timer?.invalidate()
            if startedAt != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                    [weak self] timer in
                    guard self != nil else {
                        timer.invalidate()
                        return
                    }
                    MainActor.assumeIsolated {
                        self?.updateLabel()
                    }
                }
            }
        }
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 16, y: 11, width: 13, height: 13)
        label.frame = NSRect(x: 35, y: 8, width: max(1, bounds.width - 51), height: 18)
    }

    private func updateLabel() {
        guard let startedAt else {
            label.stringValue = ""
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        var parts = ["Code Agent", formatSeconds(elapsed)]
        if let stats = modelStats {
            if stats.hasUsageUnits { parts.append("\(stats.formattedUsageUnits) units") }
            if stats.invocationCount > 0 { parts.append("\(stats.invocationCount)x") }
            if stats.totalTokens > 0 { parts.append("累计 \(stats.formattedTotalTokens) tokens") }
            if stats.contextTokens > 0 { parts.append("ctx \(stats.formattedContextTokens)") }
        }
        if isThinking { parts.append("thinking…") }
        label.stringValue = parts.joined(separator: " · ")
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return String(format: "%.1fs", seconds)
        case 10..<60: return String(format: "%.0fs", seconds)
        default: return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
        }
    }
}

private final class TimelineTableCellView: NSTableCellView {
    /// NSHostingView retains its SwiftUI state tree even when rootView is
    /// reassigned. Keep that tree for streaming changes to the same row, but
    /// replace it entirely when NSTableView assigns this cell to another row.
    private var representedRowID: String?
    private var hostingView: NSHostingView<AnyView>?
    private var hostingConstraints: [NSLayoutConstraint] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Same row = incremental root update; different row = a fresh host. This
    /// is the missing reset boundary that a UIKit-style reusable cell gets
    /// when it is configured with another indexPath's model.
    func configure(rowID: String, rootView: AnyView) {
        if representedRowID == rowID, let hostingView {
            hostingView.rootView = rootView
            return
        }

        NSLayoutConstraint.deactivate(hostingConstraints)
        hostingConstraints.removeAll()
        
        hostingView?.removeFromSuperview()
        
        let newHostingView = NSHostingView(rootView: rootView)
        newHostingView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(newHostingView)
        hostingConstraints = [
            newHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            newHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            newHostingView.topAnchor.constraint(equalTo: topAnchor),
            newHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostingConstraints)

        representedRowID = rowID
        hostingView = newHostingView
    }
}

private final class ChatScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var onUserScrollEnded: (() -> Void)?
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
        onUserScrollEnded?()
    }
}

private struct TimelineChange {
    let requiresFullReload: Bool
    let changedRows: [Int]
    let isNewConversation: Bool
}
#endif
