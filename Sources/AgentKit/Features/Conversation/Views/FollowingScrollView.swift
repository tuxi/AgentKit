//
//  FollowingScrollView.swift
//  AgentKit
//
//  Chat-style "follow the bottom" scroll container, shared by the main
//  conversation timeline and the child-stream inspector panels.
//
//  Behavior contract (Claude Code parity):
//    - Starts anchored at the bottom.
//    - While pinned at the bottom, ALL content growth follows — token
//      streaming and full tool cards alike. Growth is followed by the
//      framework's sizeChanges anchoring (adjusts the offset inside the
//      layout pass, so it can never overshoot into blank space).
//    - Pin state changes ONLY from user gestures: scrolling away from the
//      bottom unpins (streaming never disturbs a reader), returning to the
//      bottom re-pins.
//    - Programmatic scrolls never run while the user owns the viewport.
//    - `repinTrigger` change (e.g. the user sent a message) unconditionally
//      scrolls to the bottom and resumes following.
//
//  Requires the macOS 15 / iOS 18 scroll APIs (scrollPosition,
//  onScrollPhaseChange, onScrollGeometryChange).
//

import SwiftUI

struct FollowingScrollView<Content: View>: View {

    /// When this value changes, unconditionally scroll to the bottom and
    /// re-pin — pass the last turn's id so sending a message brings it
    /// into view regardless of where the viewport was.
    var repinTrigger: String? = nil

    /// Show the floating "jump to latest" button while unpinned.
    var showsJumpButton: Bool = true

    @ViewBuilder var content: () -> Content

    /// Follow mode: true while the viewport is glued to the bottom.
    @State private var isPinnedToBottom = true
    /// True from gesture start until the scroll settles — blocks all
    /// programmatic scrolling while the user (or momentum) owns the viewport.
    @State private var isUserScrolling = false
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            content()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Content-growth following is delegated to the framework: sizeChanges
        // anchoring adjusts the offset INSIDE the layout pass, atomically.
        // A manual scrollTo would compute its target mid-layout and overshoot
        // past the content into blank space.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .interacting, .decelerating, .tracking:
                // The user owns the viewport — auto-follow yields immediately.
                isUserScrolling = true
            case .idle:
                isUserScrolling = false
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .onScrollGeometryChange(for: FollowScrollMetrics.self) { geometry in
            FollowScrollMetrics(
                distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { old, new in
            if isUserScrolling {
                // Pin state changes ONLY from user-driven movement. Content
                // growth also increases the distance, but that must never
                // unpin — a tool card landing in one frame is not the user
                // scrolling away.
                if new.distanceFromBottom < 10 {
                    isPinnedToBottom = true
                } else if new.distanceFromBottom > old.distanceFromBottom + 1 {
                    isPinnedToBottom = false
                }
                return
            }

            guard isPinnedToBottom else { return }

            if new.bottomInset > old.bottomInset {
                // Approval / plan bar slid in: keep the conversation glued to
                // the bottom, animated in step with the bar (0.25s easeOut).
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else if new.contentHeight > old.contentHeight,
                      new.distanceFromBottom > 1 {
                // Content grew while pinned but NOT exactly at the edge, so
                // the framework's sizeChanges anchoring didn't engage (it only
                // follows from the exact edge). Catch up after the layout
                // settles — scrolling synchronously from inside this callback
                // would target mid-layout geometry and overshoot into blank.
                Task { @MainActor in
                    guard isPinnedToBottom, !isUserScrolling else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
        }
        .onChange(of: repinTrigger) { _, _ in
            // A new turn appeared — i.e. the user just sent a message. Always
            // bring it into view and resume following.
            isPinnedToBottom = true
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsJumpButton && !isPinnedToBottom {
                jumpToLatestButton
            }
        }
    }

    private var jumpToLatestButton: some View {
        Button {
            isPinnedToBottom = true
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
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
}

// MARK: - Scroll metrics

/// The slice of ScrollGeometry the follow logic cares about. Equatable so
/// `onScrollGeometryChange` only fires the action when something relevant moved.
private struct FollowScrollMetrics: Equatable {
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var bottomInset: CGFloat
}
