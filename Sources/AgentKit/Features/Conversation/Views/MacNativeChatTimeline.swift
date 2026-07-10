//
//  MacNativeChatTimeline.swift
//  AgentKit
//
//  The macOS chat scroll container.  SwiftUI remains responsible for each
//  timeline item, while AppKit owns row reuse, measurement and scrolling.
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

        guard let tableView = coordinator.tableView else { return }
        if change.requiresFullReload {
            tableView.reloadData()

            // Re-query every explicit height after a structural change so the
            // document frame is complete before the initial bottom pin.
            if tableView.numberOfRows > 0 {
                let allRows = IndexSet(integersIn: 0..<tableView.numberOfRows)
                tableView.noteHeightOfRows(withIndexesChanged: allRows)
            }
            tableView.tile() // 强迫 AppKit 重新刷新文档视图树的总物理高度

        } else if !change.changedRows.isEmpty {
            coordinator.applyChangedRows(change.changedRows)
        }

        if change.isNewConversation {
            coordinator.isPinnedToBottom = true
            // 非 ignoresSafeArea 状态下，首帧需要推迟到下个循环，
            // 确保安全边距与新会话清空后的高度已经被系统接受，然后坚决探底
            DispatchQueue.main.async {
                coordinator.requestInitialBottomPin()
            }
        } else if wasPinnedToBottom, change.hasVisibleUpdate {
            coordinator.scrollToBottomImmediately()
        }
    }

    private func makeRows() -> [TimelineRow] {
        var rows: [TimelineRow] = []

        if !snapshot.latestTodos.isEmpty {
            rows.append(.todo(snapshot.latestTodos))
        }

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
        case todo([TodoItem])
        case turn(ConversationTurn)
        // Extension views are host-owned and do not expose an equality
        // contract. Generation intentionally invalidates these rows whenever
        // a snapshot arrives, while normal turn rows remain value-diffed.
        case extensionContent(turnID: String, extensionID: String, generation: UInt64, content: AnyView)
        case thinking(turnStartedAt: Date?, isThinking: Bool, modelStats: ModelStats?)

        var identity: String {
            switch self {
            case .todo:
                return "todo-panel"
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
            case (.todo(let lhs), .todo(let rhs)):
                return lhs == rhs
            case (.turn(let lhs), .turn(let rhs)):
                return lhs == rhs
            case (.extensionContent(_, _, let lhs, _), .extensionContent(_, _, let rhs, _)):
                return lhs == rhs
            case (.thinking(let lhsStart, let lhsThinking, let lhsStats),
                  .thinking(let rhsStart, let rhsThinking, let rhsStats)):
                return lhsStart == rhsStart
                    && lhsThinking == rhsThinking
                    && lhsStats?.promptTokens == rhsStats?.promptTokens
                    && lhsStats?.elapsedMs == rhsStats?.elapsedMs
            default:
                return false
            }
        }

        @MainActor
        func hostedView(workspaceStore: WorkspaceStore, openURL: OpenURLAction) -> AnyView {
            let content: AnyView
            switch self {
            case .todo(let todos):
                content = AnyView(TodoPanel(todos: todos))
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
            switch row {
            case .todo: return 16
            default: return 6
            }
        }

        private var bottomPadding: CGFloat {
            switch row {
            case .thinking: return 16
            case .todo: return 6
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
        private var awaitingInitialBottomPin = false
        private var isAligningInitialBottomPin = false
        private var heightCache: [String: CGFloat] = [:]
        private var heightCacheWidth: CGFloat = 0
        private var lastLaidOutWidth: CGFloat = 0
        private var isInvalidatingHeightsForWidth = false
        private var documentStates: [String: TranscriptDocumentState] = [:]
        private lazy var transcriptMeasurer = NativeTranscriptTextView(onAction: { _ in })
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

        /// Turn rows are updated in place instead of going through
        /// reloadData(forRowIndexes:). This keeps the same NSTextView alive,
        /// preserving selection and limiting TextKit relayout to the changed
        /// suffix. Compatibility rows still use normal AppKit reloads.
        func applyChangedRows(_ changedRows: [Int]) {
            guard let tableView else { return }
            var compatibilityRows = IndexSet()

            for row in changedRows where rows.indices.contains(row) {
                if case .turn(let turn) = rows[row] {
                    if let cell = tableView.view(
                        atColumn: 0,
                        row: row,
                        makeIfNecessary: false
                    ) as? NativeTurnTableCellView {
                        configure(cell, with: turn, rowIdentity: rows[row].identity)
                    }
                } else {
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
                    let wasPinned = self.isPinnedToBottom
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: currentRow))
                    if wasPinned { self.scrollToBottomImmediately() }
                }
            )
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return tableView.rowHeight }
            let width = max(1, tableView.tableColumns.first?.width ?? tableView.bounds.width)
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
            // This is called before NSScrollView changes the clip-view bounds;
            // the notification then samples the user's resulting position.
            isPerformingProgrammaticScroll = false
        }

        /// The representable's first update can occur before the scroll view
        /// is attached to a window. In that phase its clip view has a zero
        /// height, so a bottom offset is indistinguishable from the top. Keep
        /// the request pending until AppKit has performed a real layout.
        func requestInitialBottomPin() {
            awaitingInitialBottomPin = true
            alignInitialBottomIfPossible()

            // Automatic row heights can settle one main-loop layout after the
            // scroll view is installed. This is not a timed delay or animated
            // scroll; it is a single post-layout reconciliation using AppKit's
            // measured document frame.
            DispatchQueue.main.async { [weak self] in
                self?.finishInitialBottomPinIfPossible()
            }
        }

        func scrollViewDidLayout() {
            refreshHeightsForCurrentWidthIfNeeded()
            alignInitialBottomIfPossible()
        }

        private func refreshHeightsForCurrentWidthIfNeeded() {
            guard !isInvalidatingHeightsForWidth,
                  let tableView,
                  tableView.numberOfRows > 0 else { return }
            let width = max(1, tableView.tableColumns.first?.width ?? tableView.bounds.width)
            guard abs(width - lastLaidOutWidth) > 0.5 else { return }
            lastLaidOutWidth = width
            heightCacheWidth = width
            heightCache.removeAll(keepingCapacity: true)

            isInvalidatingHeightsForWidth = true
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(
                integersIn: 0..<tableView.numberOfRows
            ))
            isInvalidatingHeightsForWidth = false
            if isPinnedToBottom { scrollToBottomImmediately() }
        }

        @objc private func boundsDidChange() {
            guard !isPerformingProgrammaticScroll else { return }
            isPinnedToBottom = checkIfAtBottom()
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

            // Todo/thinking/host extensions remain compatibility rows for the
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

        func scrollToLastRowImmediately() {
            guard let tableView,
                  let scrollView,
                  scrollView.window != nil,
                  scrollView.contentView.bounds.height > 0 else { return }
            layoutTableBeforeScrolling()
            let lastRow = tableView.numberOfRows - 1
            guard lastRow >= 0 else {
                scrollToBottomImmediately()
                return
            }
            performWithoutScrollAnimation {
                tableView.scrollRowToVisible(lastRow)
                // `scrollRowToVisible` is intentionally used for the first
                // population: it lets AppKit include the final row's measured
                // height before the clip view is positioned.
                scrollToBottom()
            }
        }

        private func alignInitialBottomIfPossible() {
            guard awaitingInitialBottomPin, !isAligningInitialBottomPin else { return }
            isAligningInitialBottomPin = true
            defer { isAligningInitialBottomPin = false }
            scrollToLastRowImmediately()
        }

        private func finishInitialBottomPinIfPossible() {
            guard awaitingInitialBottomPin,
                  !isAligningInitialBottomPin,
                  let scrollView,
                  scrollView.window != nil,
                  scrollView.contentView.bounds.height > 0 else { return }
            isAligningInitialBottomPin = true
            defer { isAligningInitialBottomPin = false }
            scrollToLastRowImmediately()
            awaitingInitialBottomPin = false
        }

        func scrollToBottomImmediately() {
            layoutTableBeforeScrolling()
            performWithoutScrollAnimation {
                scrollToBottom()
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
            let maxY = max(0, documentView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
            isPinnedToBottom = true
        }

        private func performWithoutScrollAnimation(_ work: () -> Void) {
            isPerformingProgrammaticScroll = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                work()
            }
            isPerformingProgrammaticScroll = false
        }
    }
}

// MARK: - Supporting AppKit views

private extension NSUserInterfaceItemIdentifier {
    static let chatTimelineColumn = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.Column")
    static let chatTimelineCell = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.Cell")
    static let nativeTurnTimelineCell = NSUserInterfaceItemIdentifier("AgentKit.ChatTimeline.NativeTurnCell")
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
    private let copyButton = NSButton(frame: .zero)
    private let assetsButton = NSButton(frame: .zero)
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
            transcriptView.string = ""
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

        guard !copyButton.isHidden || !assetsButton.isHidden else { return }
        let controlsY = Self.verticalPadding + textHeight + 4
        var x = Self.horizontalPadding
        if !copyButton.isHidden {
            copyButton.frame = NSRect(x: x, y: controlsY, width: 22, height: 20)
            x += 30
        }
        if !assetsButton.isHidden {
            assetsButton.frame = NSRect(x: x, y: controlsY, width: 46, height: 20)
        }
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
        let assetCount = Self.assets(in: turn).count
        assetsButton.isHidden = assetCount == 0
        assetsButton.title = assetCount == 0 ? "" : "\(assetCount)"
        needsLayout = true
    }

    private func handle(_ action: TranscriptAction) {
        if case .toggleTool(let callID) = action {
            state.toggleTool(callID: callID)
            rebuildTranscript()
            onStateChange?(state)
        } else {
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
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

private struct TimelineChange {
    let requiresFullReload: Bool
    let changedRows: [Int]
    let isNewConversation: Bool

    var hasVisibleUpdate: Bool {
        requiresFullReload || !changedRows.isEmpty
    }
}
#endif
