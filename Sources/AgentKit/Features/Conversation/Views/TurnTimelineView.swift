//
//  TurnTimelineView.swift
//  AgentKit
//
//  Turn → Block renderer. Renders RuntimeSnapshot.turns (projected once on the
//  engine actor — this view never re-projects). See docs/conversation_turn_ui_design.md.
//
//  Scroll behavior lives in FollowingScrollView: follow the stream only while
//  the user is at the bottom, never fight a user gesture, and re-pin
//  unconditionally when a new turn appears (the user sent a message).
//

import SwiftUI

public struct TurnTimelineView: View {
    let snapshot: RuntimeSnapshot
    let timelineExtensions: [any TimelineExtension]

    public init(snapshot: RuntimeSnapshot, timelineExtensions: [any TimelineExtension] = []) {
        self.snapshot = snapshot
        self.timelineExtensions = timelineExtensions
    }
    
    // 获取当前排在最底部的view的id
    private var actualLastItemId: String? {
        if snapshot.isLive, snapshot.turnStartedAt != nil {
            return "thinking_timer"
        }
        return snapshot.turns.last?.id
    }

    public var body: some View {
        FollowingScrollView(
            lastItemId: actualLastItemId,
            repinTrigger: snapshot.turns.last?.id
        ) {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Sticky todo panel — agent's current task plan.
                if !snapshot.latestTodos.isEmpty {
                    TodoPanel(todos: snapshot.latestTodos)
                        .id("todo_panel")
                        .padding(.bottom, 6)
                }

                ForEach(snapshot.turns) { turn in
                    TurnView(turn: turn)
                        .equatable()
                        .id(turn.id)

                    ForEach(timelineExtensions, id: \.id) { timelineExtension in
                        if let content = timelineExtension.makeContent(for: turn.id) {
                            content.id("\(timelineExtension.id).\(turn.id)")
                        }
                    }
                }

                // Live "agent working" indicator — only while a turn is
                // actively running. Disappears when the turn finishes.
                if snapshot.isLive, snapshot.turnStartedAt != nil {
                    ThinkingTimerView(
                        turnStartedAt: snapshot.turnStartedAt,
                        isThinking: snapshot.modelStartedAt != nil,
                        modelStats: snapshot.modelStats
                    )
                    .id("thinking_timer") // 如果它存在，它就是最底部
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(timelineBackground.ignoresSafeArea())
    }

    private var timelineBackground: Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.12, blue: 0.11, alpha: 1)
                : .systemBackground
        })
        #else
        Color.clear
        #endif
    }
}
