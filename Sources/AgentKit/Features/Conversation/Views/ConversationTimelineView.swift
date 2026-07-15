//
//  ConversationTimelineView.swift
//  CodeAgent
//
//  v2 chronological agent trace renderer.
//  Reads from ConversationViewModel.snapshot (RuntimeSnapshot) — event-order timeline.
//  Replaces the old TurnCardView (grouped-by-type) with true chronological rendering.
//

import SwiftUI

public struct ConversationTimelineView: View {

    @Environment(WorkspaceStore.self) private var store
    let viewModel: ConversationViewModel
    let isVisible: Bool

    public init(viewModel: ConversationViewModel, isVisible: Bool = true) {
        self.viewModel = viewModel
        self.isVisible = isVisible
    }

    public var body: some View {
        TurnTimelineView(
            snapshot: viewModel.snapshot,
            timelineExtensions: viewModel.timelineExtensions,
            conversationID: viewModel.conversation?.id,
            rendererMode: store.conversationRendererMode,
            isVisible: isVisible
        )
            // Scope identity to this resident session. The view remains mounted
            // across ordinary selection changes, so returning preserves its DOM
            // and viewport; only its first mount starts at the bottom.
            .id(viewModel.conversation?.id)
    }
}
