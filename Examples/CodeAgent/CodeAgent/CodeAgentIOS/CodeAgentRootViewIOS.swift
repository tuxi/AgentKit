//
//  CodeAgentRootView.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

#if os(iOS)

import SwiftUI
import AgentKit
#if DEBUG
import DebugSwift
#endif


struct CodeAgentRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let agentRuntime = AgentRuntime.shared
    @Environment(AppContainer.self) private var container
#if DEBUG
    let debugSwift = DebugSwift()
#endif
    
    init() {
#if DEBUG
        debugSwift
            .setup(enableBetaFeatures: [.swiftUIRenderTracking])
            .show()
#endif
    }

    var body: some View {
        WorkspaceView(dependencies: container.makeAgentDependencies())
            .onChange(of: scenePhase) { oldValue, newValue in
                switch newValue {
                case .active:
                   _ = try? agentRuntime.start()
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
