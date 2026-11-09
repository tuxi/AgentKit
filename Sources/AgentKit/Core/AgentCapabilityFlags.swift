//
//  AgentCapabilityFlags.swift
//  AgentKit
//
//  Backend runtime capability declaration.
//  UI reads this to adapt rendering — no hardcoded backend assumptions.
//
//  Protocol: AgentKit Runtime Protocol v1.1 §AgentCapabilityFlags
//

import Foundation
import ClientToolProtocol

// MARK: - Preview capabilities

/// Canonical preview capability strings shared by runtime `hello`,
/// `client_capabilities`, and `/v1/runtime/capabilities`.
public enum PreviewCapability: String, Sendable, Hashable, CaseIterable {
    case contract = "preview_contract_v1"
    case interactiveHTML = "preview_interactive_html_v1"
    case staticAsset = "preview_static_asset_v1"
    case replay = "preview_replay_v1"
}

public enum PreviewCapabilityWarning: String, Sendable, Hashable, CaseIterable {
    case contractUnavailable
    case helloRuntimeMismatch
    case runtimeInteractiveWithoutStatic
    case clientInteractiveWithoutStatic
    case replayUnavailable
}

/// Pure negotiation result for the four preview capabilities.
///
/// `hello` is the active-connection authority, while
/// `/v1/runtime/capabilities` must agree with it. A preview flag absent from
/// either source is never treated as available. Interactive HTML requires the
/// static surface on both runtime and client; an invalid interactive-only
/// advertisement degrades to static instead of being silently repaired into an
/// interactive renderer.
public struct PreviewCapabilityNegotiation: Sendable, Equatable {
    public let hello: Set<PreviewCapability>
    public let runtime: Set<PreviewCapability>
    public let client: Set<PreviewCapability>
    public let effective: Set<PreviewCapability>
    public let helloRuntimeMismatch: Set<PreviewCapability>
    public let warnings: Set<PreviewCapabilityWarning>

    public init(
        hello: [String],
        runtime: [String],
        client: AgentCapabilityFlags = .previewClient
    ) {
        self.init(
            hello: Set(hello.compactMap(PreviewCapability.init(rawValue:))),
            runtime: Set(runtime.compactMap(PreviewCapability.init(rawValue:))),
            client: client.previewCapabilities
        )
    }

    public init(hello: [String], runtime: [String], client: [String]) {
        self.init(
            hello: Set(hello.compactMap(PreviewCapability.init(rawValue:))),
            runtime: Set(runtime.compactMap(PreviewCapability.init(rawValue:))),
            client: Set(client.compactMap(PreviewCapability.init(rawValue:)))
        )
    }

    public init(
        hello: Set<PreviewCapability>,
        runtime: Set<PreviewCapability>,
        client: Set<PreviewCapability>
    ) {
        self.hello = hello
        self.runtime = runtime
        self.client = client
        self.helloRuntimeMismatch = hello.symmetricDifference(runtime)

        var effective = Set<PreviewCapability>()
        var warnings = Set<PreviewCapabilityWarning>()
        if !helloRuntimeMismatch.isEmpty {
            warnings.insert(.helloRuntimeMismatch)
        }

        let contract = hello.contains(.contract) && runtime.contains(.contract)
        if contract {
            effective.insert(.contract)
        } else {
            warnings.insert(.contractUnavailable)
        }

        let runtimeInvalidInteractive = runtime.contains(.interactiveHTML)
            && !runtime.contains(.staticAsset)
        let clientInvalidInteractive = client.contains(.interactiveHTML)
            && !client.contains(.staticAsset)
        if runtimeInvalidInteractive { warnings.insert(.runtimeInteractiveWithoutStatic) }
        if clientInvalidInteractive { warnings.insert(.clientInteractiveWithoutStatic) }

        // Interactive implies static. Preserve the implied static surface for
        // degraded presentation while withholding interactive rendering when
        // either advertisement is invalid.
        let runtimeStatic = runtime.contains(.staticAsset) || runtime.contains(.interactiveHTML)
        let clientStatic = client.contains(.staticAsset) || client.contains(.interactiveHTML)
        if contract && runtimeStatic && clientStatic {
            effective.insert(.staticAsset)
        }

        if contract,
           runtime.contains(.interactiveHTML), runtime.contains(.staticAsset),
           client.contains(.interactiveHTML), client.contains(.staticAsset) {
            effective.insert(.interactiveHTML)
        }

        if contract && hello.contains(.replay) && runtime.contains(.replay) && client.contains(.replay) {
            effective.insert(.replay)
        } else if contract {
            warnings.insert(.replayUnavailable)
        }

        self.effective = effective
        self.warnings = warnings
    }

    public var contractAvailable: Bool { effective.contains(.contract) }
    public var interactiveAvailable: Bool { effective.contains(.interactiveHTML) }
    public var staticAvailable: Bool { effective.contains(.staticAsset) }
    public var replayAvailable: Bool { effective.contains(.replay) }
    public var runtimeAdvertisementInvalid: Bool {
        warnings.contains(.runtimeInteractiveWithoutStatic)
    }
    public var clientAdvertisementInvalid: Bool {
        warnings.contains(.clientInteractiveWithoutStatic)
    }

    public var effectiveFlags: AgentCapabilityFlags {
        AgentCapabilityFlags(previewCapabilities: effective)
    }
}

// MARK: - AgentCapabilityFlags

/// Backend runtime 能力声明。
///
/// 用 `OptionSet` 而非固定 struct：未来新增能力只需加 `static let`，
/// 不破坏 API 兼容性。
///
/// ```swift
/// let caps = await transport.capabilities()
/// if caps.contains(.toolStreaming) { showLiveStdout() }
/// ```
public struct AgentCapabilityFlags: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: - Capabilities

    /// 支持 `token_delta` 实时流式推送。
    public static let streaming = AgentCapabilityFlags(rawValue: 1 << 0)
    /// 支持 `thinking` 完整推理快照事件（持久化、REPLACE 语义）。
    public static let thinking = AgentCapabilityFlags(rawValue: 1 << 1)
    /// 支持 `tool_stdout` / `tool_stderr` 实时 IO。
    public static let toolStreaming = AgentCapabilityFlags(rawValue: 1 << 2)
    /// 支持 `AgentInput` 携带 image。
    public static let imageInput = AgentCapabilityFlags(rawValue: 1 << 3)
    /// 支持 `plan_approval_request`。
    public static let planMode = AgentCapabilityFlags(rawValue: 1 << 4)
    /// 支持 `task_started` / `task_finished` 子 agent 事件。
    public static let subagents = AgentCapabilityFlags(rawValue: 1 << 5)
    /// 支持 wire-level session resume。
    public static let sessionResume = AgentCapabilityFlags(rawValue: 1 << 6)
    /// 支持客户端工具执行（tool_started executor: "client" + tool_result 回传）。
    public static let clientToolExecution = AgentCapabilityFlags(rawValue: 1 << 7)
    /// Runtime guarantees safe execution of turns from multiple sessions.
    public static let multiSessionExecution = AgentCapabilityFlags(rawValue: 1 << 8)
    /// Pending client-tool requests survive socket replacement and are session scoped.
    public static let sessionScopedClientTools = AgentCapabilityFlags(rawValue: 1 << 9)
    /// Runtime exposes an ownership-filtered activity snapshot.
    public static let activitySnapshot = AgentCapabilityFlags(rawValue: 1 << 10)
    /// Runtime enforces a declared workspace/worktree execution policy.
    public static let workspaceExecutionPolicy = AgentCapabilityFlags(rawValue: 1 << 11)
    /// Runtime activity includes durable terminal sequence and broker attention.
    public static let sessionAttentionSnapshot = AgentCapabilityFlags(rawValue: 1 << 12)
    /// Runtime supports cursor-based incremental session attention snapshots.
    public static let sessionAttentionDelta = AgentCapabilityFlags(rawValue: 1 << 13)
    /// Runtime can explicitly provision, recover and safely remove Git worktrees.
    public static let managedWorktree = AgentCapabilityFlags(rawValue: 1 << 14)
    /// Runtime persistently partitions conversations into active and archived lists.
    public static let conversationArchive = AgentCapabilityFlags(rawValue: 1 << 15)
    /// Runtime can safely clone unauthenticated public HTTPS Git repositories.
    public static let publicGitClone = AgentCapabilityFlags(rawValue: 1 << 16)
    /// 支持 `reasoning_delta` 实时推理流式推送。
    public static let reasoningStreaming = AgentCapabilityFlags(rawValue: 1 << 17)
    /// 支持 task / multi-agent 通用只读 child-stream WS。
    public static let childStreaming = AgentCapabilityFlags(rawValue: 1 << 18)
    /// Runtime can list, create and checkout local branches in an authorized workspace.
    public static let workspaceGitBranch = AgentCapabilityFlags(rawValue: 1 << 19)
    /// 支持按轮 Fork 对话（conversation_fork_through_turn_v1）。
    public static let conversationForkThroughTurn = AgentCapabilityFlags(rawValue: 1 << 20)
    public static let historyPagination = AgentCapabilityFlags(rawValue: 1 << 21)
    public static let conversationListPagination = AgentCapabilityFlags(rawValue: 1 << 22)
    public static let backgroundJobControl = AgentCapabilityFlags(rawValue: 1 << 23)
    public static let backgroundContinuation = AgentCapabilityFlags(rawValue: 1 << 24)

    /// Canonical preview.artifact.v1 capability flags.
    public static let previewContractV1 = AgentCapabilityFlags(rawValue: 1 << 25)
    public static let previewInteractiveHTMLV1 = AgentCapabilityFlags(rawValue: 1 << 26)
    public static let previewStaticAssetV1 = AgentCapabilityFlags(rawValue: 1 << 27)
    public static let previewReplayV1 = AgentCapabilityFlags(rawValue: 1 << 28)

    /// Surfaces implemented by AgentKit's preview data plane.
    public static let previewClient: AgentCapabilityFlags = [
        .previewContractV1,
        .previewInteractiveHTMLV1,
        .previewStaticAssetV1,
        .previewReplayV1,
    ]

    public init(previewCapabilities: Set<PreviewCapability>) {
        var flags: AgentCapabilityFlags = []
        for capability in previewCapabilities {
            switch capability {
            case .contract: flags.insert(.previewContractV1)
            case .interactiveHTML: flags.insert(.previewInteractiveHTMLV1)
            case .staticAsset: flags.insert(.previewStaticAssetV1)
            case .replay: flags.insert(.previewReplayV1)
            }
        }
        self = flags
    }

    public var previewCapabilities: Set<PreviewCapability> {
        var result = Set<PreviewCapability>()
        if contains(.previewContractV1) { result.insert(.contract) }
        if contains(.previewInteractiveHTMLV1) { result.insert(.interactiveHTML) }
        if contains(.previewStaticAssetV1) { result.insert(.staticAsset) }
        if contains(.previewReplayV1) { result.insert(.replay) }
        return result
    }

    public var previewWireNames: [String] {
        PreviewCapability.allCases
            .filter { previewCapabilities.contains($0) }
            .map(\.rawValue)
            .sorted()
    }

    public func replacingPreviewCapabilities(with capabilities: Set<PreviewCapability>) -> AgentCapabilityFlags {
        var result = self
        for flag in [
            AgentCapabilityFlags.previewContractV1,
            .previewInteractiveHTMLV1,
            .previewStaticAssetV1,
            .previewReplayV1,
        ] {
            result.remove(flag)
        }
        result.formUnion(AgentCapabilityFlags(previewCapabilities: capabilities))
        return result
    }

    // MARK: - Presets

    /// CodeAgent v1 默认能力集。
    public static let `default`: AgentCapabilityFlags = [.streaming, .thinking, .reasoningStreaming]
}
