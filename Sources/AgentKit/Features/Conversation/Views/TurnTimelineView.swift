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
    /// Stable conversation identity. The native macOS timeline uses this to
    /// distinguish a newly opened conversation from a streaming update.
    let conversationID: String?
    let rendererMode: ConversationRendererMode
    @State private var didWebRendererFail = false

    public init(
        snapshot: RuntimeSnapshot,
        timelineExtensions: [any TimelineExtension] = [],
        conversationID: String? = nil,
        rendererMode: ConversationRendererMode = .auto
    ) {
        self.snapshot = snapshot
        self.timelineExtensions = timelineExtensions
        self.conversationID = conversationID
        self.rendererMode = rendererMode
    }
    
    // 获取当前排在最底部的view的id
    private var actualLastItemId: String? {
        if snapshot.isLive, snapshot.turnStartedAt != nil {
            return "thinking_timer"
        }
        return snapshot.turns.last?.id
    }

    public var body: some View {
        #if os(macOS)
        switch didWebRendererFail ? .native : rendererMode.resolved(
            hasLegacyTimelineExtensions: hasLegacyTimelineExtensions
        ) {
        case .web:
            ConversationWebWorkbenchView(
                snapshot: snapshot,
                conversationID: conversationID,
                extensionContributions: webExtensionContributions,
                timelineExtensions: timelineExtensions,
                onFatalFailure: { didWebRendererFail = true }
            )
        case .native, .auto:
            // AppKit owns the native scroll container. TurnView itself remains
            // unchanged, preserving the TextKit behavior reference and rollback.
            MacNativeChatTimeline(
                snapshot: snapshot,
                timelineExtensions: timelineExtensions,
                conversationID: conversationID
            )
        }
        #else
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
        #endif
    }

    #if os(macOS)
    private var hasLegacyTimelineExtensions: Bool {
        timelineExtensions.contains { !($0 is any WebTimelineExtension) }
    }

    private var webExtensionContributions: [String: [TimelineWebContribution]] {
        var result: [String: [TimelineWebContribution]] = [:]
        for turn in snapshot.turns {
            var contributions: [TimelineWebContribution] = []
            for timelineExtension in timelineExtensions {
                guard let webExtension = timelineExtension as? any WebTimelineExtension else {
                    continue
                }
                contributions.append(contentsOf: webExtension.makeWebNodes(for: turn.id).map {
                    TimelineWebContribution(extensionID: timelineExtension.id, node: $0)
                })
            }
            if !contributions.isEmpty { result[turn.id] = contributions }
        }
        return result
    }
    #endif

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
