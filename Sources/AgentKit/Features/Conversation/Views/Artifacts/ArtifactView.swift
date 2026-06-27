//
//  ArtifactView.swift
//  AgentKit
//
//  Artifact 分发器 — 根据 ArtifactPayload 分发到对应子视图。
//  纯渲染层，不包含任何解析/mapping 逻辑。
//

import SwiftUI

/// Artifact 渲染入口。根据 `ArtifactNode.content` 分发到具体视图。
/// v4: Artifact 是唯一的 UI 语义输出层 — ToolCardView 不再展示 observation。
struct ArtifactView: View {
    let artifact: ArtifactNode

    var body: some View {
        switch artifact.content {
        case .diff(let payload):
            DiffArtifactView(
                filePath: payload.filePath,
                diffContent: payload.diffContent
            )

        case .file(let payload):
            FileArtifactView(
                filePath: payload.filePath,
                content: payload.content,
                language: payload.language
            )

        case .terminal(let payload):
            TerminalArtifactView(
                command: payload.command,
                output: payload.output,
                exitCode: payload.exitCode
            )
        }
    }
}
