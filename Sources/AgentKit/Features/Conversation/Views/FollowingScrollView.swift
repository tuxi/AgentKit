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
    
    /// 当前列表最后一个有效元素的 ID（可以是最新消息 ID，或者是 "thinking_timer"）
    var lastItemId: String? = nil
    
    /// 我们把 repinTrigger 的定义明确为：只有当“同一个会话内产生新 Turn”时才传入新 ID
    // When this value changes, unconditionally scroll to the bottom and
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
    /// Debounced snap-to-bottom after a viewport resize settles.
    @State private var resizeSettleTask: Task<Void, Never>?

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
                // How far the viewport rests BEYOND the legitimate bottom
                // (content bottom + bottom inset). Positive = blank space:
                // scrolling to the bottom of a freshly opened conversation
                // targets LazyVStack's estimated height, and when rows
                // measure shorter than the estimate the viewport is left
                // stranded past the real content with nothing to pull it back.
                overshootBeyondBottom: geometry.visibleRect.maxY
                    - geometry.contentSize.height - geometry.contentInsets.bottom,
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom,
                containerSize: geometry.containerSize
            )
        } action: { old, new in
            // 窗口尺寸改变的处理
            if new.containerSize != old.containerSize {
                // Viewport is being resized (window drag / inspector toggle).
                // Row heights are re-wrapping every frame, so any animated
                // scroll would chase a stale target and bounce the list.
                // Pin state must not change either. Once the size settles,
                // snap back to the bottom if we were following — re-wrapping
                // can leave the viewport a few points shy of the edge.
                resizeSettleTask?.cancel()
                if isPinnedToBottom, !isUserScrolling {
                    resizeSettleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard !Task.isCancelled, isPinnedToBottom, !isUserScrolling else { return }
                        performScrollToBottom()
                    }
                }
                return
            }

            // 核心修复：Stranded 兜底逻辑。如果换聊天导致悬空，这里的 Task 增加微小延迟，等 LazyVStack 坍塌稳定
            if !isUserScrolling,
               new.contentHeight > new.containerSize.height,
               new.overshootBeyondBottom > 1 {
                // Stranded past the real bottom (lazy height estimates,
                // shrinking insets, …) — snap back immediately, no animation:
                // the viewport is showing blank space, there is nothing to
                // animate from. Gated on scrollable content so a short
                // conversation (viewport taller than content) never loops.
                Task { @MainActor in
                    guard !isUserScrolling else { return }
                    // 给 LazyVStack 释放 1~2 帧的测绘时间/
                    try? await Task.sleep(nanoseconds: 30_00_000)
                    guard !isUserScrolling else { return }
                    // 精准收回，拒绝空白
                    performScrollToBottom()
                }
                return
            }

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

            // 内容生长时的追随
            if new.bottomInset > old.bottomInset {
                // Approval / plan bar slid in: keep the conversation glued to
                // the bottom, animated in step with the bar (0.25s easeOut).
                withAnimation(.easeOut(duration: 0.25)) {
                    performScrollToBottom()
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
                        performScrollToBottom()
                    }
                }
            }
        }
        .onChange(of: repinTrigger) { oldValue, newValue in
            // 核心修复：如果 oldValue 存在，且 newValue 存在，说明是从旧 Turn 变到新 Turn（同会话内生长）
            // 如果你是切换会话，建议在外部控制：切换会话时先把 repinTrigger 设为 nil，或者不触发此处的动画
            guard oldValue != nil, newValue != nil else {
                // 属于初次载入（比如切换会话首屏），靠 defaultScrollAnchor 自动定位即可，严禁动画滚动！
                isPinnedToBottom = true
                return
            }
            
            // A new turn appeared — i.e. the user just sent a message. Always
            // bring it into view and resume following.
            isPinnedToBottom = true
            // nil → id is the FIRST population (history import on open), not
            // a send. The initial-offset anchor + overshoot correction handle
            // that; an animated scroll here would chase LazyVStack's height
            // estimates and strand the viewport past the real bottom.
            withAnimation(.easeOut(duration: 0.25)) {
                performScrollToBottom()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsJumpButton && !isPinnedToBottom {
                jumpToLatestButton
            }
        }
    }
    
    // 通用的滚动方法
    private func performScrollToBottom() {
        if let lastItemId {
            scrollPosition.scrollTo(id: lastItemId, anchor: .bottom)
        } else {
            scrollPosition.scrollTo(edge: .bottom)
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
    var overshootBeyondBottom: CGFloat
    var contentHeight: CGFloat
    var bottomInset: CGFloat
    var containerSize: CGSize
}
