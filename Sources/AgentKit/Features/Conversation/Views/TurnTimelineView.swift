//
//  TurnTimelineView.swift
//  AgentKit
//
//  Turn → Block renderer. Projects RuntimeSnapshot.graph into [ConversationTurn]
//  and renders each as one continuous message. Replaces the flat, per-event
//  ChronologicalTimelineView. See docs/conversation_turn_ui_design.md.
//
//  Auto-scroll follows the stream ONLY while the user is at the bottom
//  ("follow mode"). Scrolling up pauses it (so the user isn't yanked back);
//  a "jump to latest" button brings them back and re-pins.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct TurnTimelineView: View {
    let snapshot: RuntimeSnapshot
    private let projection = TimelineProjection()

    /// Follow mode: true while the user is at/near the bottom.
    @State private var isPinnedToBottom = true
    @State private var viewportHeight: CGFloat = 0

    private let bottomID = "__timeline_bottom__"

    public init(snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        // Natural-order Turn → Block projection (live ⇔ history identical path).
        let turns = projection.projectTurns(snapshot.graph, isLive: snapshot.isLive)

        GeometryReader { outer in
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
                        // actively running. Disappears when the turn finishes.
                        if snapshot.isLive, snapshot.turnStartedAt != nil {
                            ThinkingTimerView(
                                turnStartedAt: snapshot.turnStartedAt,
                                isThinking: snapshot.modelStartedAt != nil,
                                modelStats: snapshot.modelStats
                            )
                            .id("thinking_timer")
                        }

                        // Bottom sentinel: scroll target + follow-mode probe.
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: BottomOffsetKey.self,
                                        value: g.frame(in: .named("turnScroll")).maxY
                                    )
                                }
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .background(timelineBackground)
                .coordinateSpace(name: "turnScroll")
                .onChange(of: snapshot.generation) { _, _ in
                    // Follow the stream only while pinned — never yank a user
                    // who has scrolled up. No animation: generation bumps ~60fps.
                    guard isPinnedToBottom else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onPreferenceChange(BottomOffsetKey.self) { bottomMaxY in
                    updatePin(bottomMaxY: bottomMaxY)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isPinnedToBottom {
                        jumpToLatestButton(proxy: proxy)
                    }
                }
            }
            .onAppear { viewportHeight = outer.size.height }
            .onChange(of: outer.size.height) { _, h in viewportHeight = h }
        }
        .background(timelineBackground.ignoresSafeArea())
    }

    /// Distance of the bottom sentinel below the visible viewport bottom.
    /// ~0 → at bottom; large → user scrolled up. Hysteresis avoids flicker.
    private func updatePin(bottomMaxY: CGFloat) {
        guard viewportHeight > 0 else { return }
        let distance = bottomMaxY - viewportHeight
        if distance > 120 {
            if isPinnedToBottom { isPinnedToBottom = false }
        } else if distance < 40 {
            if !isPinnedToBottom { isPinnedToBottom = true }
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            isPinnedToBottom = true
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .scale))
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

// MARK: - Follow-mode probe

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
