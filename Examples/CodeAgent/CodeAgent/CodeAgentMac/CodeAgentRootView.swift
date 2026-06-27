//
//  CodeAgentRootView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

#if os(macOS)

import SwiftUI
import AgentKit

struct CodeAgentRootView: View {

    @Environment(AppContainer.self) private var container

    var body: some View {
        WorkspaceView(dependencies: container.makeAgentDependencies())
    }
}

#Preview {
    CodeAgentRootView()
}

#endif
