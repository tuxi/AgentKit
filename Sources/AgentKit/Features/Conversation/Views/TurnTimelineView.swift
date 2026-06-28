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

                    // Live "model is thinking" indicator between/after turns.
                    if snapshot.modelStartedAt != nil || snapshot.modelStats != nil {
                        ThinkingTimerView(
                            modelStartedAt: snapshot.modelStartedAt,
                            modelStats: snapshot.modelStats,
                            isLive: snapshot.isLive
                        )
                        .id("thinking_timer")
                    }

                    // Bottom anchor for live auto-scroll.
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding()
            }
            .onChange(of: snapshot.generation) { _, _ in
                // Auto-scroll on every snapshot update during live streaming.
                if snapshot.isLive {
                    withAnimation {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
    }
}
