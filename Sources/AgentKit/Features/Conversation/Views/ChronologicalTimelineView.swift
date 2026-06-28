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

    public init(snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let presentations = presenter.present(snapshot.timeline)

        // Single source of truth for "which tool is expanded": the parent
        // derives the currently-running tool from the snapshot and hands the
        // same value to every card. Cards never coordinate with each other —
        // that's what broke before (sibling @Binding writes don't propagate
        // within a render pass). When no tool is running this is nil and all
        // cards collapse, matching the Claude Code mac app behaviour.
        let activeToolCallID = activeToolCallID(in: presentations)

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
                            activeToolCallID: activeToolCallID
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

    /// The callID of the tool that should be expanded — the most recent tool
    /// still in `.running`. Returns nil when no tool is running, collapsing all
    /// cards. Scanning in reverse means the latest-invoked tool wins when
    /// several run in parallel.
    private func activeToolCallID(in presentations: [ExecutionPresentation]) -> String? {
        for presentation in presentations.reversed() {
            if case .tool(let payload) = presentation.node.kind, payload.status == .running {
                return payload.callID
            }
        }
        return nil
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
