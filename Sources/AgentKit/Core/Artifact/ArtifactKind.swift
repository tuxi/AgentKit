//
//  ArtifactKind.swift
//  AgentKit
//
//  P4.4: ArtifactKind = Rendering Layer discriminator。
//  决定使用哪个 View（Diff/File/Terminal），与 WorkProductKind（语义层）共存。
//

import Foundation

// MARK: - ArtifactKind

/// Artifact 渲染种类 — 决定 UI 渲染策略（DiffArtifactBody / FileArtifactBody / TerminalArtifactBody）。
/// 与 `WorkProductKind`（语义层）正交：同一个 fileEdited 可能渲染为 diff 或 file。
public enum ArtifactKind: String, Sendable, Hashable, CaseIterable {
    case diff
    case file
    case terminal
    case files
}
