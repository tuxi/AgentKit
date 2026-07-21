//
//  InspectorPathState.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import SwiftUI
import Observation

/// 环境中的导航栈控制。
/// Inspector 内部的子视图可以通过此环境值 push 新的 destination。
@Observable
public final class InspectorPathState: @unchecked Sendable {
    public var path: [InspectorDestination] = []

    /// 标记当前是否在 InspectorNavigationView 的 NavigationStack 中。
    /// true → 使用 push/pop 导航；false → 回退到 store.showInspector（旧行为）。
    public var isActive: Bool = false

    public init() {}

    public func push(_ destination: InspectorDestination) {
        path.append(destination)
    }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    public func popToRoot() {
        path.removeAll()
    }
}

// MARK: - Environment Key

/// 自定义环境键，提供默认空状态以避免在未嵌入 InspectorNavigationView 时崩溃。
private struct InspectorPathStateKey: EnvironmentKey {
    static let defaultValue: InspectorPathState = InspectorPathState()
}

public extension EnvironmentValues {
    var inspectorPathState: InspectorPathState {
        get { self[InspectorPathStateKey.self] }
        set { self[InspectorPathStateKey.self] = newValue }
    }
}
