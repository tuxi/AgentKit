//
//  ChronologicalTimelineView.swift
//  AgentKit
//
//  Chronological agent trace renderer.
//  Reads from RuntimeSnapshot.timeline → presents via ExecutionPresenter → renders in order.
//  Replaces the old TurnCardView (grouped-by-type) with true event-order rendering.
//

import SwiftUI

// MARK: - ChronologicalTimelineView

public struct ChronologicalTimelineView: View {
    let snapshot: RuntimeSnapshot
    private let presenter = ExecutionPresenter()

    /// The currently-active (running) tool callID. Only one tool card is
    /// expanded at a time — matching Claude Code behaviour.
    @State private var activeToolCallID: String? = nil

    public init(snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let presentations = presenter.present(snapshot.timeline)

        // Collapse all tools once the assistant answer appears in the live turn.
        // History replay: always false (isLive = false), tools stay collapsed.
        let hasAssistant = snapshot.isLive && snapshot.timeline.contains { node in
            if case .message(let p) = node.kind, p.role == .assistant { return true }
            return false
        }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Sticky todo panel — shows agent's current task plan
                    if !snapshot.latestTodos.isEmpty {
                        TodoPanel(todos: snapshot.latestTodos)
                            .id("todo_panel")
                            .padding(.bottom, 6)
                    }

                    ForEach(presentations) { presentation in
                        ExecutionNodeCardView(
                            presentation: presentation,
                            activeToolCallID: $activeToolCallID,
                            hasAssistant: hasAssistant
                        )
                        .id(presentation.id)
                    }

                    // Thinking timer — live counter while model is processing
                    if snapshot.modelStartedAt != nil || snapshot.modelStats != nil {
                        ThinkingTimerView(
                            modelStartedAt: snapshot.modelStartedAt,
                            modelStats: snapshot.modelStats,
                            isLive: snapshot.isLive
                        )
                        .id("thinking_timer")
                        .padding(.top, 4)
                    }

                    // Model stats bar (token usage + timing)
                    if let stats = snapshot.modelStats {
                        HStack(spacing: 8) {
                            Label("\(stats.formattedTokens) tokens", systemImage: "text.word.spacing")
                            Label(stats.formattedElapsed, systemImage: "clock")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    }

                    // Streaming indicator when live and no explicit streaming nodes
                    if snapshot.isLive, let last = snapshot.timeline.last {
                        let hasStreaming = isNodeStreaming(last)
                        if !hasStreaming, !snapshot.timeline.isEmpty {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: snapshot.generation) { _, _ in
                // Auto-scroll on every snapshot update during live streaming.
                // generation increments even when timeline.count is unchanged (token_delta updates).
                if snapshot.isLive {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = snapshot.timeline.last {
            withAnimation {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func isNodeStreaming(_ node: ExecutionNode) -> Bool {
        switch node.kind {
        case .message(let p): return p.isStreaming
        case .thinking(let p): return p.isStreaming
        case .tool(let p): return p.status == .running
        default: return false
        }
    }
}
