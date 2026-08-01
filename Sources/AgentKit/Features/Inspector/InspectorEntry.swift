//
//  InspectorEntry.swift
//  AgentKit
//
//  Created by Codex on 2026/8/1.
//

import Foundation

/// Inspector 工作台的稳定主入口。
///
/// `InspectorEntry` 表示用户主动打开的长期工作区；它不同于
/// `InspectorSelection`（时间线中选中的某个产物）和
/// `InspectorDestination`（Inspector 内部的纵深导航目标）。
public enum InspectorEntry: String, CaseIterable, Identifiable, Sendable, Hashable {
    case review
    case terminal
    case browser
    case files
    case sideChat

    public var id: Self { self }

    public var title: String {
        switch self {
        case .review: "审阅"
        case .terminal: "终端"
        case .browser: "浏览器"
        case .files: "文件"
        case .sideChat: "侧边聊天"
        }
    }

    public var systemImage: String {
        switch self {
        case .review: "doc.text.magnifyingglass"
        case .terminal: "terminal"
        case .browser: "globe"
        case .files: "folder"
        case .sideChat: "plus.bubble"
        }
    }
}
