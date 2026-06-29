//
//  TurnTimelineView.swift
//  AgentKit
//
//  Turn → Block renderer. Projects RuntimeSnapshot.graph into [ConversationTurn]
//  and renders each as one continuous message. Replaces the flat, per-event
//  ChronologicalTimelineView. See docs/conversation_turn_ui_design.md.
//

import SwiftUI

public struct TurnTimelineView: View {
    let snapshot: RuntimeSnapshot
    private let projection = TimelineProjection()

    public init(snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        // Natural-order Turn → Block projection (live ⇔ history identical path).
        let turns = projection.projectTurns(snapshot.graph, isLive: snapshot.isLive)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Sticky todo panel — agent's current task plan.
                    if !snapshot.latestTodos.isEmpty {
                        TodoPanel(todos: snapshot.latestTodos)
                            .id("todo_panel")
                            .padding(.bottom, 6)
                    }

                    ForEach(turns) { turn in
                        TurnView(turn: turn)
                            .id(turn.id)
                    }

                    // Live "agent working" indicator — only while a turn is
                    // actively running. Disappears when the turn finishes (no
                    // "thinking finished" line); completed stats are in the footer.
                    if snapshot.isLive, snapshot.turnStartedAt != nil {
                        ThinkingTimerView(
                            turnStartedAt: snapshot.turnStartedAt,
                            isThinking: snapshot.modelStartedAt != nil,
                            modelStats: snapshot.modelStats
                        )
                        .id("thinking_timer")
                    }
                }
                .padding()
            }
            .onChange(of: snapshot.generation) { _, _ in
                // Keep the latest turn's bottom in view during live streaming.
                // Scroll to the real last turn (a laid-out element) rather than a
                // zero-height anchor — the anchor sits after a lazily-laid-out
                // timer and overshoots into blank space when a tool card expands.
                // No animation: generation bumps ~60fps on token deltas; animating
                // each one makes the content (esp. a running tool) jitter.
                guard snapshot.isLive, let lastID = turns.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}
