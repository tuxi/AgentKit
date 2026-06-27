//
//  AgentDependencies.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/6/25.
//

import Foundation

/// UI 层依赖容器。ViewModel 通过此结构拿到协议实例，不感知具体实现。
public struct AgentDependencies {
    /// 与 CodeAgent Runtime 通信的客户端（agent-wire v1）。
    public let client: RuntimeClient

    public init(client: RuntimeClient) {
        self.client = client
    }
}
