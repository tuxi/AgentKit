//
//  EmbeddedRuntimeCoordinator.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/8/19.
//

import Foundation

actor EmbeddedRuntimeCoordinator {
    static let shared = EmbeddedRuntimeCoordinator()

    // The body of this method deliberately contains no `await`. Actor
    // isolation therefore makes the whole operation one indivisible critical
    // section. AgentRuntime keeps the gomobile object; this actor only owns the
    // lifecycle gate, which avoids moving a non-Sendable MobileServer across
    // the Swift concurrency boundary.
    func run<T: Sendable>(
        _ operation: @Sendable () throws -> T
    ) rethrows -> T {
        try operation()
    }
}
