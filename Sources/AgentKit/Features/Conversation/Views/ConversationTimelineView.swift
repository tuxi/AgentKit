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

    public init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TurnTimelineView(snapshot: viewModel.snapshot)
    }
}
