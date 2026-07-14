//
//  CodeAgentApp.swift
//  CodeAgent
//
//  轻量示例入口。完整功能版见独立 CodeAgent 仓库。
//

import SwiftUI
import AgentKit

@main
struct CodeAgentApp: App {

    private var container: AppContainer

    init() {
        self.container = AppContainer()
    }

    var body: some Scene {
        WindowGroup {
            CodeAgentRootView(dependencies: container.makeAgentDependencies())
                .environment(container)
                .environment(container.modelSettings)
        }
    }
}
