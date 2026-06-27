//
//  CodeAgentApp.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/24.
//

import SwiftUI
import AgentKit

@main
struct CodeAgentApp: App {
    
    private var container: AppContainer
    private var wsClient: WebSocketClient
    
    init() {
        
        let wsClient = WebSocketClient(identifier: "com.objc.dreamlog.workflow.ws")
        self.wsClient = wsClient
        self.container = AppContainer(wsClient: wsClient)
    }
    
    var body: some Scene {
        WindowGroup {
            CodeAgentRootView()
                .environment(container)
        }
    }
}
