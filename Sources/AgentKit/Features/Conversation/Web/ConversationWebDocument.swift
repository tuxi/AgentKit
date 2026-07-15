//
//  ConversationWebDocument.swift
//  AgentKit
//
//  Versioned, presentation-only payload sent to the bundled Web renderer.
//

import Foundation

struct ConversationWebDocument: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let revision: UInt64
    let conversationID: String
    let todos: [Todo]
    let turns: [Turn]
    let live: LiveState?

    struct Todo: Codable, Equatable, Sendable {
        let content: String
        let activeForm: String?
        let status: String
    }

    struct Turn: Codable, Equatable, Sendable {
        let id: String
        let userPrompt: String?
        let blocks: [Block]
        let extensionNodes: [ExtensionNode]
        let footer: Footer?
        let isLive: Bool
        let copyActionID: String?
        let assetsActionID: String?
        let assetCount: Int
    }

    struct Block: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case markdown
            case toolGroup
            case artifact
            case system
            case childStream
        }

        let id: String
        let kind: Kind
        let text: String?
        let title: String?
        let status: String?
        let elapsed: String?
        let tools: [Tool]
        /// Present only for child-stream entry rows. The parent timeline uses
        /// this to distinguish task subagents from background jobs without
        /// embedding the child stream's result in the main document.
        let childStreamKind: String?
        let actionID: String?
        let actionTooltip: String?
        let inlineActions: [InlineAction]
        let codeCopyActionIDs: [String]
    }

    struct Tool: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let status: String
        let statusText: String?
        let detail: String?
        let elapsed: String?
        let changeSummary: String?
        let arguments: String?
        let output: String?
        let artifactActionID: String?
        let assetActions: [ActionItem]
        let copyOutputActionID: String?
        let argumentActions: [InlineAction]
        let outputActions: [InlineAction]
    }

    struct InlineAction: Codable, Equatable, Sendable {
        let text: String
        let actionID: String
        let tooltip: String
    }

    struct ActionItem: Codable, Equatable, Sendable {
        let title: String
        let actionID: String
        let tooltip: String?
        let focusID: String?
    }

    struct ExtensionNode: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let summary: String?
        let status: String?
        let tone: String
        let badges: [ExtensionBadge]
        let sections: [ExtensionSection]
        let actions: [ActionItem]
        let footer: String?
    }

    struct ExtensionBadge: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let tone: String
    }

    struct ExtensionSection: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let summary: String?
        let status: String?
        let rows: [ExtensionRow]
        let initiallyExpanded: Bool
    }

    struct ExtensionRow: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    struct Footer: Codable, Equatable, Sendable {
        let totalTokens: String
        let contextTokens: String?
        let usageUnits: String?
        let elapsed: String
        let invocationCount: Int
    }

    struct LiveState: Codable, Equatable, Sendable {
        let isThinking: Bool
        let startedAtMilliseconds: Int64?
    }
}

@MainActor
enum ConversationWebDocumentBuilder {
    struct ReuseSource {
        let snapshot: RuntimeSnapshot
        let document: ConversationWebDocument
        let extensionContributions: [String: [TimelineWebContribution]]
    }

    static func build(
        snapshot: RuntimeSnapshot,
        conversationID: String?,
        revision: UInt64? = nil,
        extensionContributions: [String: [TimelineWebContribution]] = [:],
        reusing reuseSource: ReuseSource? = nil,
        registerAction: ((ConversationWebAction) -> String)? = nil
    ) -> ConversationWebDocument {
        ConversationWebDocument(
            protocolVersion: ConversationWebDocument.currentProtocolVersion,
            revision: revision ?? snapshot.generation,
            conversationID: conversationID ?? "unbound",
            todos: snapshot.latestTodos.map {
                ConversationWebDocument.Todo(
                    content: $0.content,
                    activeForm: $0.activeForm,
                    status: $0.status.rawValue
                )
            },
            turns: snapshot.turns.enumerated().map { index, turn in
                let contributions = extensionContributions[turn.id] ?? []
                if let reuseSource,
                   index < reuseSource.snapshot.turns.count,
                   index < reuseSource.document.turns.count,
                   reuseSource.snapshot.turns[index] == turn,
                   reuseSource.document.turns[index].id == turn.id,
                   reuseSource.extensionContributions[turn.id] ?? [] == contributions {
                    return reuseSource.document.turns[index]
                }
                return makeTurn(
                    turn,
                    extensionContributions: contributions,
                    registerAction: registerAction
                )
            },
            live: makeLiveState(snapshot)
        )
    }

    static func actionTokens(in document: ConversationWebDocument) -> Set<String> {
        var tokens = Set<String>()
        for turn in document.turns {
            if let token = turn.copyActionID { tokens.insert(token) }
            if let token = turn.assetsActionID { tokens.insert(token) }
            for block in turn.blocks {
                if let token = block.actionID { tokens.insert(token) }
                tokens.formUnion(block.codeCopyActionIDs)
                tokens.formUnion(block.inlineActions.map(\.actionID))
                for tool in block.tools {
                    if let token = tool.artifactActionID { tokens.insert(token) }
                    if let token = tool.copyOutputActionID { tokens.insert(token) }
                    tokens.formUnion(tool.assetActions.map(\.actionID))
                    tokens.formUnion(tool.argumentActions.map(\.actionID))
                    tokens.formUnion(tool.outputActions.map(\.actionID))
                }
            }
            for node in turn.extensionNodes {
                tokens.formUnion(node.actions.map(\.actionID))
            }
        }
        return tokens
    }

    private static func makeTurn(
        _ turn: ConversationTurn,
        extensionContributions: [TimelineWebContribution],
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.Turn {
        let assets = turnAssets(turn)
        let copyActionID = registerAction.map { registerAction in
            let copyText = TranscriptCache.shared.transcript(
                for: turn,
                state: TranscriptDocumentState()
            ).copyText
            return registerAction(.transcript(
                turnID: turn.id,
                action: .copyBlock(text: copyText)
            ))
        }
        return ConversationWebDocument.Turn(
            id: turn.id,
            userPrompt: turn.userPrompt?.text,
            blocks: turn.blocks.map {
                makeBlock($0, turn: turn, registerAction: registerAction)
            },
            extensionNodes: extensionContributions.map {
                makeExtensionNode($0, turnID: turn.id, registerAction: registerAction)
            },
            footer: turn.footer.map {
                ConversationWebDocument.Footer(
                    totalTokens: $0.formattedTotalTokens,
                    contextTokens: $0.contextTokens > 0 ? $0.formattedContextTokens : nil,
                    usageUnits: $0.hasUsageUnits ? $0.formattedUsageUnits : nil,
                    elapsed: $0.formattedElapsed,
                    invocationCount: $0.invocationCount
                )
            },
            isLive: turn.isLive,
            copyActionID: copyActionID,
            assetsActionID: assets.isEmpty ? nil : registerAction.map {
                $0(.showTurnAssets(turnID: turn.id))
            },
            assetCount: assets.count
        )
    }

    private static func makeExtensionNode(
        _ contribution: TimelineWebContribution,
        turnID: String,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.ExtensionNode {
        let node = contribution.node
        return .init(
            id: "\(contribution.extensionID):\(node.id)",
            title: node.title,
            summary: node.summary,
            status: node.status,
            tone: node.tone.rawValue,
            badges: node.badges.map {
                .init(id: $0.id, text: $0.text, tone: $0.tone.rawValue)
            },
            sections: node.sections.map { section in
                .init(
                    id: section.id,
                    title: section.title,
                    summary: section.summary,
                    status: section.status,
                    rows: section.rows.map {
                        .init(id: $0.id, label: $0.label, value: $0.value)
                    },
                    initiallyExpanded: section.initiallyExpanded
                )
            },
            actions: node.actions.compactMap { action in
                guard let registerAction else { return nil }
                let nativeAction: ConversationWebAction
                switch action.kind {
                case .extensionAction:
                    nativeAction = .timelineExtension(
                        extensionID: contribution.extensionID,
                        turnID: turnID,
                        actionID: action.id
                    )
                case .document:
                    guard let document = action.document else { return nil }
                    nativeAction = .timelineDocument(document)
                }
                return .init(
                    title: action.title,
                    actionID: registerAction(nativeAction),
                    tooltip: action.tooltip,
                    focusID: "extension:\(node.id):action:\(action.id)"
                )
            },
            footer: node.footer
        )
    }

    private static func makeBlock(
        _ block: TurnBlock,
        turn: ConversationTurn,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.Block {
        switch block {
        case .text(let id, let payload):
            return .init(
                id: id,
                kind: .markdown,
                text: payload.text,
                title: nil,
                status: payload.isStreaming ? "streaming" : nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                inlineActions: inlineActions(
                    text: payload.text,
                    annotations: payload.textAnnotations,
                    turn: turn,
                    registerAction: registerAction
                ),
                codeCopyActionIDs: codeBlockCopyActions(
                    in: payload.text,
                    turnID: turn.id,
                    registerAction: registerAction
                )
            )

        case .toolGroup(let group):
            let groupPresentation = ToolTranscriptPresenter.groupPresentation(for: group)
            let tools = group.tools.map { tool in
                let presentation = ToolTranscriptPresenter.presentation(for: tool)
                let arguments = tool.args.flatMap(formattedJSON)
                let output = tool.output.isEmpty ? nil : tool.output
                return ConversationWebDocument.Tool(
                    id: tool.callID,
                    name: presentation.title,
                    status: tool.status.rawValue,
                    statusText: presentation.statusText,
                    detail: presentation.detail,
                    elapsed: presentation.elapsed,
                    changeSummary: presentation.changeSummary,
                    arguments: arguments,
                    output: output,
                    artifactActionID: tool.artifact.flatMap { _ in
                        registerAction.map {
                            $0(.transcript(
                                turnID: turn.id,
                                action: .openArtifact(callID: tool.callID)
                            ))
                        }
                    },
                    assetActions: tool.assets.compactMap { asset in
                        guard let registerAction else { return nil }
                        let reference = AssetIndex(turn: turn).reference(forStructuredAsset: asset)
                        return ConversationWebDocument.ActionItem(
                            title: asset.displayName ?? reference.display,
                            actionID: registerAction(.transcript(
                                turnID: turn.id,
                                action: .openAsset(reference)
                            )),
                            tooltip: reference.target,
                            focusID: "tool:\(tool.callID):asset:\(reference.id)"
                        )
                    },
                    copyOutputActionID: tool.output.isEmpty ? nil : registerAction.map {
                        $0(.transcript(
                            turnID: turn.id,
                            action: .copyBlock(text: tool.output)
                        ))
                    },
                    argumentActions: arguments.map {
                        inlineActions(
                            text: $0,
                            annotations: [],
                            turn: turn,
                            registerAction: registerAction
                        )
                    } ?? [],
                    outputActions: output.map {
                        inlineActions(
                            text: $0,
                            annotations: [],
                            turn: turn,
                            registerAction: registerAction
                        )
                    } ?? []
                )
            }
            return .init(
                id: group.id,
                kind: .toolGroup,
                text: nil,
                title: groupPresentation.summary,
                status: aggregateStatus(group.tools),
                elapsed: nil,
                tools: tools,
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                inlineActions: [],
                codeCopyActionIDs: []
            )

        case .artifact(let id, let artifact):
            return .init(
                id: id,
                kind: .artifact,
                text: artifactText(artifact),
                title: SummaryRenderer.summary(for: artifact),
                status: nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: registerAction.map {
                    $0(.transcript(
                        turnID: turn.id,
                        action: .openArtifact(callID: artifact.callID)
                    ))
                },
                actionTooltip: artifact.path,
                inlineActions: [],
                codeCopyActionIDs: []
            )

        case .system(let id, let payload):
            return .init(
                id: id,
                kind: .system,
                text: payload.text,
                title: payload.kind.rawValue,
                status: payload.kind == .error ? "failed" : nil,
                elapsed: nil,
                tools: [],
                childStreamKind: nil,
                actionID: nil,
                actionTooltip: nil,
                inlineActions: [],
                codeCopyActionIDs: []
            )

        case .childStream(let id, let payload):
            return .init(
                id: id,
                kind: .childStream,
                // The child result belongs to the Inspector. Keeping it out of
                // the parent DOM also keeps cross-turn selection and VoiceOver
                // from traversing a duplicated, potentially very large result.
                text: nil,
                title: payload.title,
                status: payload.status.rawValue,
                elapsed: payload.formattedElapsed,
                tools: [],
                childStreamKind: payload.kind.rawValue,
                actionID: registerAction.map {
                    $0(.transcript(
                        turnID: turn.id,
                        action: .openChildStream(childID: payload.childID)
                    ))
                },
                actionTooltip: payload.childID,
                inlineActions: [],
                codeCopyActionIDs: []
            )
        }
    }

    private static func aggregateStatus(_ tools: [ToolNodePayload]) -> String? {
        if tools.contains(where: { $0.status == .failed }) { return "failed" }
        if tools.contains(where: { $0.status == .running }) { return "running" }
        if tools.allSatisfy({ $0.status == .autoApproved }) { return "autoApproved" }
        return tools.isEmpty ? nil : "completed"
    }

    private static func formattedJSON(_ value: JSONValue) -> String? {
        if let pretty = value.prettyJSONString, !pretty.isEmpty {
            // JSONSerialization may escape path separators as `\/`. The workbench
            // renders arguments for people (and detects file actions in that text),
            // so keep filesystem paths readable and range-stable.
            return pretty.replacingOccurrences(of: "\\/", with: "/")
        }
        return value.stringValue.isEmpty ? nil : value.stringValue
    }

    private static func artifactText(_ artifact: ArtifactNode) -> String? {
        switch artifact.content {
        case .diff(let payload):
            return payload.diffContent
        case .file(let payload):
            return payload.content
        case .directory(let payload):
            return payload.listing
        case .terminal(let payload):
            return payload.output
        }
    }

    private static func makeLiveState(_ snapshot: RuntimeSnapshot) -> ConversationWebDocument.LiveState? {
        guard snapshot.isLive, snapshot.turnStartedAt != nil else { return nil }
        return ConversationWebDocument.LiveState(
            isThinking: snapshot.modelStartedAt != nil,
            startedAtMilliseconds: snapshot.turnStartedAt.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            }
        )
    }

    private static func turnAssets(_ turn: ConversationTurn) -> [AgentAssetRef] {
        var assets: [AgentAssetRef] = []
        for block in turn.blocks {
            guard case .toolGroup(let group) = block else { continue }
            for tool in group.tools { assets.append(contentsOf: tool.assets) }
        }
        return AgentAssetDisplayIndex.unique(assets)
    }

    private static func inlineActions(
        text: String,
        annotations: [AgentTextAnnotation],
        turn: ConversationTurn,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> [ConversationWebDocument.InlineAction] {
        guard let registerAction else { return [] }
        let assetIndex = AssetIndex(turn: turn)
        var consumedKeys = Set<String>()
        let resolvedAnnotations = annotations.resolvingNearbyLineNumberAssets(
            assetIndex: assetIndex
        )
        let annotationMatches = TextAnnotationReferenceDetector.matches(
            in: text,
            annotations: resolvedAnnotations,
            consumedKeys: &consumedKeys,
            assetIndex: assetIndex
        )
        let fallbackMatches = AssetReferenceDetector.matches(
            in: text,
            assetIndex: assetIndex
        ).filter { fallback in
            !annotationMatches.contains {
                NSIntersectionRange($0.range, fallback.range).length > 0
            }
        }
        let nsText = text as NSString
        return (annotationMatches + fallbackMatches)
            .sorted { $0.range.location < $1.range.location }
            .compactMap { match in
                guard match.range.location != NSNotFound,
                      NSMaxRange(match.range) <= nsText.length else { return nil }
                return ConversationWebDocument.InlineAction(
                    text: nsText.substring(with: match.range),
                    actionID: registerAction(.transcript(
                        turnID: turn.id,
                        action: .openAsset(match.reference)
                    )),
                    tooltip: match.reference.target
                )
            }
    }

    private static func codeBlockCopyActions(
        in markdown: String,
        turnID: String,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> [String] {
        guard let registerAction,
              let regex = try? NSRegularExpression(
                pattern: #"(?s)(?:^|\n)```[^\n]*\n(.*?)(?:\n```|```$)"#
              ) else { return [] }
        let nsText = markdown as NSString
        return regex.matches(
            in: markdown,
            range: NSRange(location: 0, length: nsText.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { return nil }
            let code = nsText.substring(with: match.range(at: 1))
            return registerAction(.transcript(
                turnID: turnID,
                action: .copyBlock(text: code)
            ))
        }
    }
}
