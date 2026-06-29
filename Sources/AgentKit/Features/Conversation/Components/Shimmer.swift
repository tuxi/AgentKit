//
//  Shimmer.swift
//  AgentKit
//
//  A light sweep across text/content to signal live activity — used on the
//  currently-running tool line (Claude Code style: the line animates instead of
//  the tool expanding). Purely an overlay: no layout change, so it never causes
//  the height jitter that auto-expansion did.
//

import SwiftUI

private struct ShimmerModifier: ViewModifier {
    var active: Bool
    /// Seconds per sweep.
    var period: Double = 1.4

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period) // 0…1
                    GeometryReader { proxy in
                        let w = max(proxy.size.width, 1)
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.5)
                        .offset(x: -w * 0.5 + phase * w * 1.5)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Sweep a highlight across this view while `active`. No-op otherwise.
    func shimmering(active: Bool, period: Double = 1.4) -> some View {
        modifier(ShimmerModifier(active: active, period: period))
    }
}
