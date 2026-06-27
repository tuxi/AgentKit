//
//  AppContainer.swift
//  CodeAgent
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation
import AgentKit


@Observable
final class AppContainer {
    
    let wsClient: WebSocketClient
    
    init(wsClient: WebSocketClient) {
        self.wsClient = wsClient
    }
    
    func makeAgentClient() -> RuntimeClient {
        return DefaultAgentClient()
    }
    
    func makeAgentDependencies() -> AgentDependencies {
        AgentDependencies(client: makeAgentClient())
    }
}
