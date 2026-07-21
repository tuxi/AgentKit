//
//  InspectorDestination.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import Foundation

/// Inspector 内的导航目标。
/// 用于 NavigationStack path，支持 Hashable 以便 push/pop。
public enum InspectorDestination: Hashable {
    /// Tool 调用结果详情
    case toolResult(callID: String)

    /// 文件预览
    case filePreview(filePath: String)

    /// 文件变更对比
    case diffPreview(filePath: String, baseRef: String?)

    /// Agent 状态详情
    case agentStateDetail

    /// 资产详情预览（从资产列表 push 进入）
    case assetDetail(AssetPreviewPayload)
}
