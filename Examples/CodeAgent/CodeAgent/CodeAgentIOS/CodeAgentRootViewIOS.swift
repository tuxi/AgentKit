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
    
    @Environment(\.scenePhase) private var scenePhase
    let agentRuntime = AgentRuntime.shared

    @Environment(AppContainer.self) private var container

    var body: some View {
        WorkspaceView(dependencies: container.makeAgentDependencies())
            .onChange(of: scenePhase) { oldValue, newValue in
                switch newValue {
                case .active:
                    try? agentRuntime.start()
                case .background:
                    agentRuntime.stop()
                case .inactive:
                    break
                default:
                    break
                }
            }
    }
}

#endif
