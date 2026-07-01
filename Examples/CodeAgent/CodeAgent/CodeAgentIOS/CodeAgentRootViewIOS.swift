//
//  CodeAgentRootView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

#if os(iOS)

import SwiftUI
import AgentKit


struct CodeAgentRootView: View {
    @Environment(AppContainer.self) private var container
    
    init() {

    }

    var body: some View {
        WorkspaceView(dependencies: container.makeAgentDependencies())
    }
}

#endif
