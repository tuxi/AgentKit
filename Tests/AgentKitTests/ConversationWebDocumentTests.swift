//
//  ConversationWebDocumentTests.swift
//  AgentKitTests
//

import XCTest
@testable import AgentKit
#if os(macOS)
import WebKit
#endif

@MainActor
final class ConversationWebDocumentTests: XCTestCase {
    func testBuilderPreservesStableIdentityMarkdownAndRevision() throws {
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: MessageNodePayload(role: .user, text: "show the table"),
            blocks: [
                .text(
                    id: "text-1",
                    MessageNodePayload(
                        role: .assistant,
                        text: "| Name | Value |\n| --- | --- |\n| width | 640 |"
                    )
                )
            ],
            footer: TurnStats(
                contextTokens: 1_200,
                totalTokens: 1_350,
                elapsedMs: 420,
                invocationCount: 1
            ),
            isLive: false
        )
        let snapshot = RuntimeSnapshot(
            timeline: [],
            turns: [turn],
            generation: 42
        )

        let document = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "conversation-1"
        )

        XCTAssertEqual(document.protocolVersion, 1)
        XCTAssertEqual(document.revision, 42)
        XCTAssertEqual(document.conversationID, "conversation-1")
        XCTAssertEqual(document.turns.first?.id, "turn-1")
        XCTAssertEqual(document.turns.first?.blocks.first?.id, "text-1")
        XCTAssertEqual(document.turns.first?.blocks.first?.kind, .markdown)
        XCTAssertEqual(document.turns.first?.footer?.totalTokens, "1.4K")

        let encoded = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(ConversationWebDocument.self, from: encoded), document)
    }

    func testBuilderProjectsToolStatusAndWideOutput() {
        let runningTool = ToolNodePayload(
            callID: "call-1",
            toolName: "read_file",
            args: .object(["path": .string("/tmp/example.swift")]),
            status: .running,
            output: String(repeating: "a", count: 800),
            elapsedMs: 1_250
        )
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "call-1", tools: [runningTool]))],
            footer: nil,
            isLive: true
        )

        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn], generation: 2),
            conversationID: "conversation-1"
        )
        let block = document.turns[0].blocks[0]

        XCTAssertEqual(block.kind, .toolGroup)
        XCTAssertEqual(block.status, "running")
        XCTAssertEqual(block.tools[0].id, "call-1")
        XCTAssertEqual(block.tools[0].statusText, "running")
        XCTAssertEqual(block.tools[0].detail, "/tmp/example.swift")
        XCTAssertEqual(block.tools[0].elapsed, "1.2s")
        XCTAssertEqual(block.tools[0].output?.count, 800)
        XCTAssertTrue(block.tools[0].arguments?.contains("example.swift") == true)
    }

    func testBuilderProjectsEditLineCountsAndHidesSuccessfulStatusText() {
        let editTool = ToolNodePayload(
            callID: "edit-1",
            toolName: "apply_patch",
            args: .object(["path": .string("/tmp/example.swift")]),
            status: .completed,
            output: "--- a/example.swift\n+++ b/example.swift\n@@ -1 +1,2 @@\n-old\n+new\n+more",
            elapsedMs: 240
        )
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(id: "edit-1", tools: [editTool]))],
            footer: nil,
            isLive: false
        )

        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "conversation-1"
        )
        let tool = document.turns[0].blocks[0].tools[0]

        XCTAssertEqual(tool.changeSummary, "+2 -1")
        XCTAssertEqual(tool.elapsed, "240ms")
        XCTAssertNil(tool.statusText)
    }

    func testBuilderProjectsChildStreamAsInspectorEntryWithoutDuplicatingResult() {
        let child = ChildStreamNodePayload(
            kind: .task,
            childID: "child-1",
            title: "Search the workspace for minimum-width references",
            status: .completed,
            result: String(repeating: "Inspector-only result ", count: 100),
            elapsedMs: 3_100
        )
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [.childStream(id: "child-block-1", child)],
            footer: nil,
            isLive: false
        )

        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "conversation-1"
        )
        let block = document.turns[0].blocks[0]

        XCTAssertEqual(block.kind, .childStream)
        XCTAssertEqual(block.childStreamKind, "task")
        XCTAssertEqual(block.title, child.title)
        XCTAssertEqual(block.status, "completed")
        XCTAssertEqual(block.elapsed, "3.1s")
        XCTAssertNil(block.text)
    }

    func testDifferUsesBlockPatchAndDoesNotForcePinForAppend() {
        func turn(_ id: String, _ text: String) -> ConversationTurn {
            ConversationTurn(
                id: id,
                userPrompt: MessageNodePayload(role: .user, text: id),
                blocks: [.text(
                    id: "text-\(id)",
                    MessageNodePayload(role: .assistant, text: text)
                )],
                footer: nil,
                isLive: true
            )
        }

        let old = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn("one", "stable"), turn("two", "old")]
            ),
            conversationID: "conversation",
            revision: 1
        )
        let changed = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn("one", "stable"), turn("two", "streamed")]
            ),
            conversationID: "conversation",
            revision: 2
        )

        let patch = ConversationWebDocumentDiffer.update(from: old, to: changed)
        XCTAssertEqual(patch?.kind, .patch)
        XCTAssertEqual(patch?.patch?.operations.count, 1)
        XCTAssertEqual(patch?.patch?.operations.first?.kind, .replaceBlock)
        XCTAssertEqual(patch?.patch?.operations.first?.index, 1)
        XCTAssertEqual(patch?.patch?.operations.first?.blockIndex, 0)
        XCTAssertEqual(patch?.patch?.forcePinToBottom, false)

        let appended = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [
                    turn("one", "stable"),
                    turn("two", "streamed"),
                    turn("three", "new"),
                ]
            ),
            conversationID: "conversation",
            revision: 3
        )
        let appendPatch = ConversationWebDocumentDiffer.update(from: changed, to: appended)
        XCTAssertEqual(appendPatch?.patch?.operations.last?.kind, .appendTurn)
        XCTAssertEqual(appendPatch?.patch?.forcePinToBottom, false)

        let revisionGap = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: appended.turns.map { webTurn in
                turn(webTurn.id, "same")
            }),
            conversationID: "conversation",
            revision: 8
        )
        XCTAssertEqual(
            ConversationWebDocumentDiffer.update(from: appended, to: revisionGap)?.kind,
            .reset
        )
    }

    func testResetCarriesProcessRecoveryViewportWithoutForcingBottom() throws {
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: []),
            conversationID: "conversation",
            revision: 12
        )
        let viewport = ConversationWebUpdate.RecoveryViewport(
            pinned: false,
            anchorID: "block:text-8",
            anchorTop: 137.5
        )

        let update = ConversationWebDocumentDiffer.reset(
            document,
            recoveryViewport: viewport
        )

        XCTAssertEqual(update.kind, .reset)
        XCTAssertEqual(update.recoveryViewport, viewport)
        XCTAssertNil(update.patch)

        let encoded = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(ConversationWebUpdate.self, from: encoded)
        XCTAssertEqual(decoded.recoveryViewport, viewport)
    }

    @MainActor
    func testIncrementalBuilderReusesStableTurnsAndExpiresChangedTurnActions() throws {
        func turn(_ id: String, _ text: String) -> ConversationTurn {
            ConversationTurn(
                id: id,
                userPrompt: MessageNodePayload(role: .user, text: id),
                blocks: [.text(
                    id: "text-\(id)",
                    MessageNodePayload(role: .assistant, text: text)
                )],
                footer: nil,
                isLive: id == "tail"
            )
        }

        let registry = ConversationWebActionRegistry()
        let firstSnapshot = RuntimeSnapshot(
            timeline: [],
            turns: [turn("stable", "unchanged"), turn("tail", "old")]
        )
        registry.beginRevision(1)
        let first = ConversationWebDocumentBuilder.build(
            snapshot: firstSnapshot,
            conversationID: "conversation",
            revision: 1,
            registerAction: registry.register
        )
        registry.finishRevision(
            retaining: ConversationWebDocumentBuilder.actionTokens(in: first)
        )

        let secondSnapshot = RuntimeSnapshot(
            timeline: [],
            turns: [firstSnapshot.turns[0], turn("tail", "new")]
        )
        registry.beginRevision(2)
        let second = ConversationWebDocumentBuilder.build(
            snapshot: secondSnapshot,
            conversationID: "conversation",
            revision: 2,
            reusing: .init(
                snapshot: firstSnapshot,
                document: first,
                extensionContributions: [:]
            ),
            registerAction: registry.register
        )
        registry.finishRevision(
            retaining: ConversationWebDocumentBuilder.actionTokens(in: second)
        )

        let stableToken = try XCTUnwrap(first.turns[0].copyActionID)
        let oldTailToken = try XCTUnwrap(first.turns[1].copyActionID)
        let newTailToken = try XCTUnwrap(second.turns[1].copyActionID)
        XCTAssertEqual(second.turns[0], first.turns[0])
        XCTAssertEqual(second.turns[0].copyActionID, stableToken)
        XCTAssertNotEqual(newTailToken, oldTailToken)
        XCTAssertNotNil(registry.resolve(stableToken, revision: 2))
        XCTAssertNil(registry.resolve(oldTailToken, revision: 2))
        XCTAssertNotNil(registry.resolve(newTailToken, revision: 2))
    }

    @MainActor
    func testOpaqueActionRegistryKeepsStableTokensAndRejectsExpiredActions() {
        let registry = ConversationWebActionRegistry()
        let firstAction = ConversationWebAction.transcript(
            turnID: "turn-1",
            action: .openPath("/tmp/example.swift")
        )
        let secondAction = ConversationWebAction.showTurnAssets(turnID: "turn-1")

        registry.beginRevision()
        let firstToken = registry.register(firstAction)
        _ = registry.register(secondAction)
        registry.finishRevision()
        XCTAssertEqual(registry.resolve(firstToken), firstAction)
        XCTAssertFalse(firstToken.contains("example.swift"))

        registry.beginRevision()
        let stableToken = registry.register(firstAction)
        registry.finishRevision()
        XCTAssertEqual(stableToken, firstToken)
        XCTAssertEqual(registry.resolve(stableToken), firstAction)

        registry.beginRevision()
        registry.finishRevision()
        XCTAssertNil(registry.resolve(firstToken))
    }

    @MainActor
    func testActionRegistryKeepsDisplayedAndInflightRevisionsIsolated() {
        let registry = ConversationWebActionRegistry()
        let stable = ConversationWebAction.transcript(
            turnID: "turn-1",
            action: .openPath("/tmp/stable.swift")
        )
        let nextOnly = ConversationWebAction.showTurnAssets(turnID: "turn-1")

        registry.beginRevision(10)
        let stableToken = registry.register(stable)
        registry.finishRevision()

        registry.beginRevision(11)
        XCTAssertEqual(registry.register(stable), stableToken)
        let nextToken = registry.register(nextOnly)
        registry.finishRevision()

        XCTAssertEqual(registry.resolve(stableToken, revision: 10), stable)
        XCTAssertEqual(registry.resolve(stableToken, revision: 11), stable)
        XCTAssertNil(registry.resolve(nextToken, revision: 10))
        XCTAssertEqual(registry.resolve(nextToken, revision: 11), nextOnly)

        registry.retainRevisions([11])
        XCTAssertNil(registry.resolve(stableToken, revision: 10))
        XCTAssertEqual(registry.resolve(stableToken, revision: 11), stable)
    }

    @MainActor
    func testBuilderRegistersDetectedFilePathAsOpaqueInlineAction() {
        let registry = ConversationWebActionRegistry()
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [.text(
                id: "text-1",
                MessageNodePayload(
                    role: .assistant,
                    text: "Open /tmp/example.swift and inspect it."
                )
            )],
            footer: nil,
            isLive: false
        )
        registry.beginRevision()
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "conversation",
            revision: 1,
            registerAction: registry.register
        )
        registry.finishRevision()

        let inlineAction = document.turns[0].blocks[0].inlineActions.first
        XCTAssertEqual(inlineAction?.text, "/tmp/example.swift")
        XCTAssertFalse(inlineAction?.actionID.contains("example.swift") == true)
        guard let actionID = inlineAction?.actionID,
              case .transcript(let turnID, let action)? = registry.resolve(actionID) else {
            return XCTFail("Expected registered transcript action")
        }
        XCTAssertEqual(turnID, "turn-1")
        XCTAssertEqual(action, .openAsset(AssetIndex(turn: turn).reference(forPath: "/tmp/example.swift")))
    }

    @MainActor
    func testBuilderRegistersCodeCopyAndToolArgumentOutputActions() throws {
        let registry = ConversationWebActionRegistry()
        let tool = ToolNodePayload(
            callID: "call-1",
            toolName: "write_file",
            args: .object(["path": .string("/tmp/generated.swift")]),
            status: .completed,
            output: "Wrote /tmp/generated.swift"
        )
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [
                .text(
                    id: "text-1",
                    MessageNodePayload(
                        role: .assistant,
                        text: "```swift\nlet answer = 42\n```"
                    )
                ),
                .toolGroup(ToolGroup(id: "tools-1", tools: [tool])),
            ],
            footer: nil,
            isLive: false
        )

        registry.beginRevision()
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "conversation",
            revision: 1,
            registerAction: registry.register
        )
        registry.finishRevision()

        let copyActionID = try XCTUnwrap(document.turns[0].blocks[0].codeCopyActionIDs.first)
        XCTAssertEqual(
            registry.resolve(copyActionID),
            .transcript(turnID: "turn-1", action: .copyBlock(text: "let answer = 42"))
        )

        let webTool = document.turns[0].blocks[1].tools[0]
        XCTAssertEqual(webTool.argumentActions.first?.text, "/tmp/generated.swift")
        XCTAssertEqual(webTool.outputActions.first?.text, "/tmp/generated.swift")
        for action in [webTool.argumentActions.first, webTool.outputActions.first].compactMap({ $0 }) {
            guard case .transcript(let turnID, let transcriptAction)? = registry.resolve(action.actionID) else {
                return XCTFail("Expected registered tool path action")
            }
            XCTAssertEqual(turnID, "turn-1")
            XCTAssertEqual(
                transcriptAction,
                .openAsset(AssetIndex(turn: turn).reference(forPath: "/tmp/generated.swift"))
            )
        }
    }

    @MainActor
    func testSemanticTimelineExtensionProjectsOpaqueActionsAndInspectorDocument() throws {
        let registry = ConversationWebActionRegistry()
        let document = TimelineWebDocument(
            id: "report-1",
            title: "Evidence report",
            format: .html,
            body: "<h1>Evidence</h1>"
        )
        let contribution = TimelineWebContribution(
            extensionID: "fixture.extension",
            node: TimelineWebNode(
                id: "evidence-1",
                title: "Desktop evidence",
                summary: "Action verified",
                status: "passed",
                tone: .success,
                badges: [.init(id: "risk", text: "low")],
                sections: [.init(
                    id: "verification",
                    title: "Verification",
                    rows: [.init(id: "result", label: "Result", value: "passed")]
                )],
                actions: [
                    .init(id: "retry", title: "Retry"),
                    .document(id: "report", title: "Report", document: document),
                ]
            )
        )
        let turn = ConversationTurn(
            id: "turn-1",
            userPrompt: nil,
            blocks: [],
            footer: nil,
            isLive: false
        )

        registry.beginRevision()
        let webDocument = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: [turn]),
            conversationID: "conversation",
            revision: 1,
            extensionContributions: ["turn-1": [contribution]],
            registerAction: registry.register
        )
        registry.finishRevision()

        let node = try XCTUnwrap(webDocument.turns[0].extensionNodes.first)
        XCTAssertEqual(node.id, "fixture.extension:evidence-1")
        XCTAssertEqual(node.sections.first?.rows.first?.value, "passed")
        XCTAssertEqual(node.actions.count, 2)
        XCTAssertEqual(
            registry.resolve(node.actions[0].actionID),
            .timelineExtension(
                extensionID: "fixture.extension",
                turnID: "turn-1",
                actionID: "retry"
            )
        )
        XCTAssertEqual(
            registry.resolve(node.actions[1].actionID),
            .timelineDocument(document)
        )
        XCTAssertFalse(node.actions[0].actionID.contains("retry"))
    }

    func testFiveHundredTurnDocumentBuildAndTailDiffStayBounded() throws {
        func makeTurn(_ index: Int, text: String? = nil) -> ConversationTurn {
            ConversationTurn(
                id: "turn-\(index)",
                userPrompt: MessageNodePayload(role: .user, text: "Prompt \(index)"),
                blocks: [.text(
                    id: "text-\(index)",
                    MessageNodePayload(
                        role: .assistant,
                        text: text ?? "Response \(index)\n\n| Key | Value |\n| --- | --- |\n| index | \(index) |"
                    )
                )],
                footer: nil,
                isLive: index == 499
            )
        }

        let turns = (0..<500).map { makeTurn($0) }
        let clock = ContinuousClock()
        let start = clock.now
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: turns),
            conversationID: "stress",
            revision: 1
        )
        let buildDuration = start.duration(to: clock.now)
        let encoded = try JSONEncoder().encode(document)

        var updatedTurns = turns
        updatedTurns[499] = makeTurn(
            499,
            text: String(repeating: "streamed token ", count: 2_000)
        )
        let updated = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: updatedTurns),
            conversationID: "stress",
            revision: 2
        )
        let patch = try XCTUnwrap(ConversationWebDocumentDiffer.update(from: document, to: updated))

        XCTAssertLessThan(buildDuration, .seconds(5))
        XCTAssertLessThan(encoded.count, 10_000_000)
        XCTAssertEqual(document.turns.count, 500)
        XCTAssertEqual(patch.patch?.operations.count, 1)
        XCTAssertEqual(patch.patch?.operations.first?.index, 499)
    }

    #if os(macOS)
    func testPrivateSchemeOnlyServesAllowlistedBundleResources() throws {
        XCTAssertEqual(
            ConversationWebSchemeHandler.allowedResourcePath(
                for: try XCTUnwrap(URL(string: "agentkit-workbench://bundle/index.html"))
            ),
            "index.html"
        )
        XCTAssertEqual(
            ConversationWebSchemeHandler.allowedResourcePath(
                for: try XCTUnwrap(URL(string: "agentkit-workbench://bundle/assets/workbench.js"))
            ),
            "assets/workbench.js"
        )
        for rawURL in [
            "https://bundle/index.html",
            "agentkit-workbench://other/index.html",
            "agentkit-workbench://bundle/config.yaml",
            "agentkit-workbench://bundle/assets/%2e%2e/config.yaml",
            "agentkit-workbench://user@bundle/index.html",
            "agentkit-workbench://bundle:443/index.html",
            "agentkit-workbench://bundle/index.html#fragment",
        ] {
            XCTAssertNil(
                ConversationWebSchemeHandler.allowedResourcePath(
                    for: try XCTUnwrap(URL(string: rawURL))
                ),
                rawURL
            )
        }
    }

    func testRendererRolloutPolicyIsConservative() {
        XCTAssertEqual(
            ConversationRendererMode.auto.resolved(hasLegacyTimelineExtensions: false),
            .web
        )
        XCTAssertEqual(
            ConversationRendererMode.auto.resolved(hasLegacyTimelineExtensions: true),
            .native
        )
        XCTAssertEqual(
            ConversationRendererMode.web.resolved(hasLegacyTimelineExtensions: true),
            .native
        )
    }

    @MainActor
    func testBundledShellLoadsFromPrivateSchemeAndHandshakes() async throws {
        let ready = expectation(description: "Web renderer handshake")
        let acknowledged = expectation(description: "Web document acknowledgement")
        let probe = ConversationWebBridgeProbe(ready: ready)
        probe.expectAcknowledgement(revision: 1, expectation: acknowledged)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ConversationWebSchemeHandler(),
            forURLScheme: ConversationWebSchemeHandler.scheme
        )
        configuration.userContentController.add(
            probe,
            name: "agentkitWorkbench"
        )

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.load(URLRequest(url: ConversationWebSchemeHandler.indexURL))

        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(probe.protocolVersion, ConversationWebDocument.currentProtocolVersion)

        let registry = ConversationWebActionRegistry()
        let readTools = (1...5).map { index in
            ToolNodePayload(
                callID: "read-\(index)",
                toolName: "read_file",
                args: .object(["path": .string("/tmp/file-\(index).swift")]),
                status: .completed,
                output: "contents \(index)",
                elapsedMs: index * 20
            )
        }
        let compactEditTool = ToolNodePayload(
            callID: "edit-compact",
            toolName: "apply_patch",
            args: .object(["path": .string("/tmp/compact.swift")]),
            status: .completed,
            output: "--- a/compact.swift\n+++ b/compact.swift\n@@ -1 +1,2 @@\n-old\n+new\n+added",
            elapsedMs: 240
        )
        let childResult = "CHILD_RESULT_MUST_STAY_IN_INSPECTOR "
            + String(repeating: "long result ", count: 100)
        let subagent = ChildStreamNodePayload(
            kind: .task,
            childID: "subagent-1",
            title: "Search the workspace for any references to minimum width, scroll, code block, table block, or horizontal scroll",
            status: .completed,
            result: childResult
        )
        let extensionContributions = [
            "turn-1": [TimelineWebContribution(
                extensionID: "fixture.extension",
                node: TimelineWebNode(
                    id: "evidence",
                    title: "Verified evidence",
                    summary: "Semantic extension content",
                    status: "passed",
                    tone: .success,
                    sections: [.init(
                        id: "details",
                        title: "Details",
                        rows: [.init(id: "result", label: "Result", value: "passed")]
                    )],
                    actions: [.init(id: "inspect", title: "Inspect")]
                )
            )]
        ]

        let fixture = RuntimeSnapshot(
            timeline: [],
            turns: [
                ConversationTurn(
                    id: "turn-1",
                    userPrompt: MessageNodePayload(role: .user, text: "first"),
                    blocks: [
                        .text(
                            id: "text-1",
                            MessageNodePayload(
                                role: .assistant,
                                text: "| Column A | Column B | Column C |\n| --- | --- | --- |\n| one | two | three |\n\n<script>window.__agentKitInjected = true</script><img src='https://invalid.example/pixel' onerror='window.__agentKitInjected = true'>"
                            )
                        ),
                        .toolGroup(ToolGroup(id: "read-group", tools: readTools)),
                        .toolGroup(ToolGroup(id: "edit-compact", tools: [compactEditTool])),
                        .childStream(id: "subagent-block", subagent),
                    ],
                    footer: nil,
                    isLive: false
                ),
                ConversationTurn(
                    id: "turn-2",
                    userPrompt: MessageNodePayload(role: .user, text: "second"),
                    blocks: [.text(
                        id: "text-2",
                        MessageNodePayload(
                            role: .assistant,
                            text: "```swift\nlet width = 1234567890123456789012345678901234567890\n```"
                        )
                    )],
                    footer: nil,
                    isLive: false
                ),
            ],
            generation: 7
        )
        let initialDocument = ConversationWebDocumentBuilder.build(
                snapshot: fixture,
                conversationID: "fixture",
                revision: 1,
                extensionContributions: extensionContributions,
                registerAction: registry.register
            )
        let payload = try JSONEncoder().encode(
            ConversationWebDocumentDiffer.reset(initialDocument)
        ).base64EncodedString()
        _ = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.applyUpdateBase64('\(payload)')"
        )

        await fulfillment(of: [acknowledged], timeout: 5)
        XCTAssertEqual(probe.acknowledgedRevision, 1)

        let inspection = try await webView.evaluateJavaScript(
            """
            (() => {
              const frame = document.querySelector('.table-frame');
              return {
                turnCount: document.querySelectorAll('.turn').length,
                tableOverflows: Boolean(frame && frame.scrollWidth > frame.clientWidth),
                userSelect: getComputedStyle(document.body).userSelect || getComputedStyle(document.body).webkitUserSelect,
                opacity: getComputedStyle(document.documentElement).opacity,
                mainLabel: document.querySelector('main').getAttribute('aria-label'),
                labelledTurns: document.querySelectorAll('article[aria-labelledby]').length,
                extensionCount: document.querySelectorAll('.extension-node').length,
                semanticRows: document.querySelectorAll('.extension-rows dt').length,
                rawScriptCount: document.querySelectorAll('.turn-block script').length,
                rawImageCount: document.querySelectorAll('.turn-block img').length,
                injected: Boolean(window.__agentKitInjected),
                scopedHeaders: document.querySelectorAll('th[scope="col"]').length,
                cspBlocksFrames: document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.content.includes("frame-src 'none'") ?? false,
                unnamedInteractive: [...document.querySelectorAll('button,a[href],summary,[role="button"]')].filter((element) => !(element.getAttribute('aria-label') || element.textContent?.trim())).length,
                toolGroupCount: document.querySelectorAll('details.tool-group').length,
                toolGroupOpen: document.querySelector('details.tool-group')?.open ?? null,
                toolGroupTitle: document.querySelector('.tool-group-summary')?.textContent ?? null,
                toolGroupIsCompact: (() => {
                  const group = document.querySelector('details.tool-group');
                  const block = group?.closest('.turn-block');
                  return Boolean(group && block && group.getBoundingClientRect().width < block.getBoundingClientRect().width / 2);
                })(),
                toolChromeIsClear: (() => {
                  const group = document.querySelector('details.tool-group');
                  if (!group) return false;
                  const style = getComputedStyle(group);
                  return style.backgroundColor === 'rgba(0, 0, 0, 0)' && style.borderStyle === 'none';
                })(),
                toolDotCount: document.querySelectorAll('.tool-group .status-dot').length,
                completedToolLabelCount: [...document.querySelectorAll('.tool-group-summary,.tool-summary')].filter((element) => element.textContent?.toLowerCase().includes('completed')).length,
                editChangeSummary: document.querySelector('.tool-change-summary')?.textContent ?? null,
                editElapsed: [...document.querySelectorAll('.tool-summary')].find((element) => element.textContent?.includes('+2'))?.querySelector('.tool-elapsed')?.textContent ?? null,
                subagentKind: document.querySelector('.child-stream-kind')?.textContent ?? null,
                subagentTitle: document.querySelector('.child-stream-title')?.textContent ?? null,
                subagentContainsResult: document.querySelector('.child-stream')?.textContent?.includes('CHILD_RESULT_MUST_STAY_IN_INSPECTOR') ?? null,
                subagentContainsCompleted: document.querySelector('.child-stream')?.textContent?.toLowerCase().includes('completed') ?? null,
                subagentChromeIsClear: (() => {
                  const row = document.querySelector('.child-stream');
                  return Boolean(row && getComputedStyle(row).backgroundColor === 'rgba(0, 0, 0, 0)' && getComputedStyle(row).borderStyle === 'none');
                })(),
                subagentSingleLine: document.querySelector('.child-stream-title') ? getComputedStyle(document.querySelector('.child-stream-title')).whiteSpace === 'nowrap' : false,
                subagentFits: (() => {
                  const row = document.querySelector('.child-stream');
                  return Boolean(row && row.scrollWidth <= row.clientWidth + 1);
                })()
              };
            })()
            """
        ) as? [String: Any]
        XCTAssertEqual(inspection?["turnCount"] as? Int, 2)
        XCTAssertEqual(inspection?["tableOverflows"] as? Bool, true)
        XCTAssertEqual(inspection?["userSelect"] as? String, "text")
        XCTAssertEqual(inspection?["opacity"] as? String, "1")
        XCTAssertEqual(inspection?["mainLabel"] as? String, "Conversation")
        XCTAssertEqual(inspection?["labelledTurns"] as? Int, 2)
        XCTAssertEqual(inspection?["extensionCount"] as? Int, 1)
        XCTAssertEqual(inspection?["semanticRows"] as? Int, 1)
        XCTAssertEqual(inspection?["rawScriptCount"] as? Int, 0)
        XCTAssertEqual(inspection?["rawImageCount"] as? Int, 0)
        XCTAssertEqual(inspection?["injected"] as? Bool, false)
        XCTAssertGreaterThan(inspection?["scopedHeaders"] as? Int ?? 0, 0)
        XCTAssertEqual(inspection?["cspBlocksFrames"] as? Bool, true)
        XCTAssertEqual(inspection?["unnamedInteractive"] as? Int, 0)
        XCTAssertEqual(inspection?["toolGroupCount"] as? Int, 1)
        XCTAssertEqual(inspection?["toolGroupOpen"] as? Bool, false)
        XCTAssertTrue((inspection?["toolGroupTitle"] as? String)?.contains("Read 5 files") == true)
        XCTAssertEqual(inspection?["toolGroupIsCompact"] as? Bool, true)
        XCTAssertEqual(inspection?["toolChromeIsClear"] as? Bool, true)
        XCTAssertEqual(inspection?["toolDotCount"] as? Int, 0)
        XCTAssertEqual(inspection?["completedToolLabelCount"] as? Int, 0)
        XCTAssertEqual(inspection?["editChangeSummary"] as? String, "+2 -1")
        XCTAssertEqual(inspection?["editElapsed"] as? String, "240ms")
        XCTAssertEqual(inspection?["subagentKind"] as? String, "Subagent")
        XCTAssertEqual(inspection?["subagentTitle"] as? String, subagent.title)
        XCTAssertEqual(inspection?["subagentContainsResult"] as? Bool, false)
        XCTAssertEqual(inspection?["subagentContainsCompleted"] as? Bool, false)
        XCTAssertEqual(inspection?["subagentChromeIsClear"] as? Bool, true)
        XCTAssertEqual(inspection?["subagentSingleLine"] as? Bool, true)
        XCTAssertEqual(inspection?["subagentFits"] as? Bool, true)

        let selectionBefore = try await webView.evaluateJavaScript(
            """
            (() => {
              const start = document.querySelector('[data-selection-id="turn:turn-1:user"]').firstChild;
              const end = document.querySelector('[data-selection-id="block:text-2"] code').firstChild;
              const range = document.createRange();
              range.setStart(start, 0);
              range.setEnd(end, 12);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const table = document.querySelector('.table-frame');
              table.scrollLeft = 96;
              document.querySelector('[data-turn-id="turn-1"]').dataset.identityProbe = 'preserved';
              document.querySelector('.code-actions button').focus();
              return selection.toString();
            })()
            """
        ) as? String

        let longStreamingCode = "```swift\nlet width = 1234567890123456789012345678901234567890\n"
            + (1...80).map { "let streamed\($0) = true" }.joined(separator: "\n")
            + "\n```"
        let updatedFixture = RuntimeSnapshot(
            timeline: [],
            turns: [
                fixture.turns[0],
                ConversationTurn(
                    id: "turn-2",
                    userPrompt: MessageNodePayload(role: .user, text: "second"),
                    blocks: [.text(
                        id: "text-2",
                        MessageNodePayload(
                            role: .assistant,
                            text: longStreamingCode
                        )
                    )],
                    footer: nil,
                    isLive: true
                ),
            ],
            generation: 8
        )
        let updatedDocument = ConversationWebDocumentBuilder.build(
            snapshot: updatedFixture,
            conversationID: "fixture",
            revision: 2,
            extensionContributions: extensionContributions,
            registerAction: registry.register
        )
        let patchUpdate = try XCTUnwrap(
            ConversationWebDocumentDiffer.update(from: initialDocument, to: updatedDocument)
        )
        XCTAssertEqual(patchUpdate.kind, .patch)
        let secondAcknowledgement = expectation(description: "Web patch acknowledgement")
        probe.expectAcknowledgement(revision: 2, expectation: secondAcknowledgement)
        let patchPayload = try JSONEncoder().encode(patchUpdate).base64EncodedString()
        _ = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.applyUpdateBase64('\(patchPayload)')"
        )
        await fulfillment(of: [secondAcknowledgement], timeout: 5)

        let preservedState = try await webView.evaluateJavaScript(
            """
            (() => ({
              selection: window.getSelection().toString(),
              horizontalOffset: document.querySelector('.table-frame').scrollLeft,
              identityProbe: document.querySelector('[data-turn-id="turn-1"]').dataset.identityProbe,
              streamedText: document.querySelector('[data-selection-id="block:text-2"]').textContent,
              focusedAction: document.activeElement?.dataset.focusId ?? null
            }))()
            """
        ) as? [String: Any]
        XCTAssertEqual(preservedState?["selection"] as? String, selectionBefore)
        XCTAssertGreaterThan(preservedState?["horizontalOffset"] as? Double ?? 0, 0)
        XCTAssertEqual(preservedState?["identityProbe"] as? String, "preserved")
        XCTAssertTrue((preservedState?["streamedText"] as? String)?.contains("streamed") == true)
        XCTAssertNil(preservedState?["focusedAction"] as? String)

        _ = try await webView.evaluateJavaScript(
            "window.getSelection().removeAllRanges(); document.querySelector('.code-actions button').focus(); window.dispatchEvent(new WheelEvent('wheel', { deltaY: -120 })); window.scrollTo(0, 0);"
        )
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.lastViewportInteracting, true)
        let unpinnedBeforePatch = try await webView.evaluateJavaScript(
            "({ y: window.scrollY, jump: Boolean(document.querySelector('.jump-to-latest')), focusedAction: document.activeElement?.dataset.focusId ?? null })"
        ) as? [String: Any]
        XCTAssertEqual(unpinnedBeforePatch?["jump"] as? Bool, true)

        let unpinnedSecondTurn = ConversationTurn(
            id: "turn-2",
            userPrompt: MessageNodePayload(role: .user, text: "second"),
            blocks: [.text(
                id: "text-2",
                MessageNodePayload(
                    role: .assistant,
                    text: longStreamingCode.replacingOccurrences(
                        of: "\n```",
                        with: "\nlet finalTail = true\n```"
                    )
                )
            )],
            footer: nil,
            isLive: true
        )
        let unpinnedDocument = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [
                    updatedFixture.turns[0],
                    unpinnedSecondTurn,
                ]
            ),
            conversationID: "fixture",
            revision: 3,
            extensionContributions: extensionContributions,
            registerAction: registry.register
        )
        let unpinnedPatch = try XCTUnwrap(
            ConversationWebDocumentDiffer.update(from: updatedDocument, to: unpinnedDocument)
        )
        let thirdAcknowledgement = expectation(description: "Unpinned patch acknowledgement")
        probe.expectAcknowledgement(revision: 3, expectation: thirdAcknowledgement)
        let unpinnedPayload = try JSONEncoder().encode(unpinnedPatch).base64EncodedString()
        _ = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.applyUpdateBase64('\(unpinnedPayload)')"
        )
        await fulfillment(of: [thirdAcknowledgement], timeout: 5)
        let unpinnedAfterPatch = try await webView.evaluateJavaScript(
            "({ y: window.scrollY, jump: Boolean(document.querySelector('.jump-to-latest')), focusedAction: document.activeElement?.dataset.focusId ?? null })"
        ) as? [String: Any]
        XCTAssertEqual(unpinnedAfterPatch?["jump"] as? Bool, true)
        XCTAssertTrue((unpinnedAfterPatch?["focusedAction"] as? String)?.hasPrefix("code-copy:") == true)
        XCTAssertEqual(
            unpinnedAfterPatch?["y"] as? Double ?? -1,
            unpinnedBeforePatch?["y"] as? Double ?? -2,
            accuracy: 1
        )

        let appendedTurn = ConversationTurn(
            id: "turn-3",
            userPrompt: MessageNodePayload(role: .user, text: "new turn"),
            blocks: [.text(
                id: "text-3",
                MessageNodePayload(role: .assistant, text: "new reply")
            )],
            footer: nil,
            isLive: true
        )
        let appendedRuntimeDocument = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [updatedFixture.turns[0], unpinnedSecondTurn, appendedTurn]
            ),
            conversationID: "fixture",
            revision: 4,
            extensionContributions: extensionContributions,
            registerAction: registry.register
        )
        let appendPatch = try XCTUnwrap(
            ConversationWebDocumentDiffer.update(from: unpinnedDocument, to: appendedRuntimeDocument)
        )
        XCTAssertEqual(appendPatch.patch?.forcePinToBottom, false)
        let fourthAcknowledgement = expectation(description: "New turn acknowledgement")
        probe.expectAcknowledgement(revision: 4, expectation: fourthAcknowledgement)
        let appendPayload = try JSONEncoder().encode(appendPatch).base64EncodedString()
        _ = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.applyUpdateBase64('\(appendPayload)')"
        )
        await fulfillment(of: [fourthAcknowledgement], timeout: 5)
        try await Task.sleep(for: .milliseconds(30))
        let readingStateAfterAppend = try await webView.evaluateJavaScript(
            "({ y: window.scrollY, distance: document.documentElement.scrollHeight - window.scrollY - window.innerHeight, jump: Boolean(document.querySelector('.jump-to-latest')) })"
        ) as? [String: Any]
        XCTAssertEqual(readingStateAfterAppend?["jump"] as? Bool, true)
        XCTAssertEqual(
            readingStateAfterAppend?["y"] as? Double ?? -1,
            unpinnedAfterPatch?["y"] as? Double ?? -2,
            accuracy: 1
        )
        XCTAssertGreaterThan(readingStateAfterAppend?["distance"] as? Double ?? 0, 1)

        _ = try await webView.evaluateJavaScript(
            "document.querySelector('.jump-to-latest').click()"
        )
        try await Task.sleep(for: .milliseconds(30))
        let bottomState = try await webView.evaluateJavaScript(
            "({ distance: document.documentElement.scrollHeight - window.scrollY - window.innerHeight, jump: Boolean(document.querySelector('.jump-to-latest')) })"
        ) as? [String: Any]
        XCTAssertLessThanOrEqual(bottomState?["distance"] as? Double ?? 100, 1)
        XCTAssertEqual(bottomState?["jump"] as? Bool, false)

        configuration.userContentController.removeScriptMessageHandler(forName: "agentkitWorkbench")
        _ = webView
    }

    func testLongConversationAndRapidTailPatchesStayResponsive() async throws {
        let ready = expectation(description: "Long renderer handshake")
        let rendered = expectation(description: "Long document acknowledgement")
        let finalPatch = expectation(description: "Rapid tail patch acknowledgement")
        let finalReadingPatch = expectation(description: "Rapid unpinned tail patch acknowledgement")
        let probe = ConversationWebBridgeProbe(ready: ready)
        probe.expectAcknowledgement(revision: 1, expectation: rendered)
        probe.expectAcknowledgement(revision: 26, expectation: finalPatch)
        probe.expectAcknowledgement(revision: 51, expectation: finalReadingPatch)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ConversationWebSchemeHandler(),
            forURLScheme: ConversationWebSchemeHandler.scheme
        )
        configuration.userContentController.add(probe, name: "agentkitWorkbench")
        let webView = WKWebView(
            frame: .init(x: 0, y: 0, width: 760, height: 700),
            configuration: configuration
        )
        webView.load(URLRequest(url: ConversationWebSchemeHandler.indexURL))
        await fulfillment(of: [ready], timeout: 5)

        func turn(_ index: Int, tail: String? = nil) -> ConversationTurn {
            let representativeContent = index.isMultiple(of: 20)
                ? "| Column | Value |\n| --- | --- |\n| index | \(index) |\n\n```swift\nlet index = \(index)\n```"
                : "Response \(index) with enough prose to exercise layout and selection."
            return ConversationTurn(
                id: "turn-\(index)",
                userPrompt: MessageNodePayload(role: .user, text: "Prompt \(index)"),
                blocks: [.text(
                    id: "text-\(index)",
                    MessageNodePayload(role: .assistant, text: tail ?? representativeContent)
                )],
                footer: nil,
                isLive: index == 499
            )
        }

        let initialTurns = (0..<500).map { turn($0) }
        var previous = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(timeline: [], turns: initialTurns),
            conversationID: "long-stress",
            revision: 1
        )
        let initialPayload = try JSONEncoder().encode(
            ConversationWebDocumentDiffer.reset(previous)
        ).base64EncodedString()
        let clock = ContinuousClock()
        let renderStart = clock.now
        _ = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.applyUpdateBase64('\(initialPayload)')"
        )
        await fulfillment(of: [rendered], timeout: 15)
        XCTAssertLessThan(renderStart.duration(to: clock.now), .seconds(10))

        for revision in 2...26 {
            var turns = initialTurns
            turns[499] = turn(
                499,
                tail: "Streaming tail revision \(revision)\n\n" + String(repeating: "token ", count: revision * 4)
            )
            let next = ConversationWebDocumentBuilder.build(
                snapshot: RuntimeSnapshot(timeline: [], turns: turns),
                conversationID: "long-stress",
                revision: UInt64(revision)
            )
            let update = try XCTUnwrap(ConversationWebDocumentDiffer.update(from: previous, to: next))
            let payload = try JSONEncoder().encode(update).base64EncodedString()
            _ = try await webView.evaluateJavaScript(
                "window.AgentKitWorkbench.applyUpdateBase64('\(payload)')"
            )
            previous = next
        }
        await fulfillment(of: [finalPatch], timeout: 15)

        let inspection = try await webView.evaluateJavaScript(
            """
            (() => ({
              turns: document.querySelectorAll('article.turn').length,
              nodes: document.querySelectorAll('*').length,
              tail: document.querySelector('[data-selection-id="block:text-499"]').textContent,
              distance: document.documentElement.scrollHeight - window.scrollY - window.innerHeight,
              mainRole: document.querySelectorAll('main[aria-label="Conversation"]').length
            }))()
            """
        ) as? [String: Any]
        XCTAssertEqual(inspection?["turns"] as? Int, 500)
        XCTAssertLessThan(inspection?["nodes"] as? Int ?? 100_000, 20_000)
        XCTAssertTrue((inspection?["tail"] as? String)?.contains("revision 26") == true)
        XCTAssertLessThanOrEqual(inspection?["distance"] as? Double ?? 100, 1)
        XCTAssertEqual(inspection?["mainRole"] as? Int, 1)

        // Height changes that happen after React commits still follow while
        // the viewport was already at the bottom.
        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-turn-id=\"turn-499\"]').style.paddingBottom = '240px'"
        )
        try await Task.sleep(for: .milliseconds(80))
        let followedResizeDistance = try await webView.evaluateJavaScript(
            "document.documentElement.scrollHeight - window.scrollY - window.innerHeight"
        ) as? Double
        let followedResizeDiagnostics = try await webView.evaluateJavaScript(
            "window.AgentKitWorkbench.viewportDiagnostics()"
        )
        XCTAssertLessThanOrEqual(
            followedResizeDistance ?? 100,
            1,
            String(describing: followedResizeDiagnostics)
        )

        _ = try await webView.evaluateJavaScript(
            "window.dispatchEvent(new WheelEvent('wheel', { deltaY: -160 })); window.scrollTo(0, Math.floor(document.documentElement.scrollHeight / 2));"
        )
        try await Task.sleep(for: .milliseconds(220))
        let readingBeforePatches = try await webView.evaluateJavaScript(
            "({ y: window.scrollY, jump: Boolean(document.querySelector('.jump-to-latest')), viewport: window.AgentKitWorkbench.viewportDiagnostics() })"
        ) as? [String: Any]
        let readingY = readingBeforePatches?["y"] as? Double
        XCTAssertEqual(readingBeforePatches?["jump"] as? Bool, true)

        for revision in 27...51 {
            var turns = initialTurns
            turns[499] = turn(
                499,
                tail: "Reading-safe tail revision \(revision)\n\n"
                    + String(repeating: "token ", count: revision * 5)
            )
            let next = ConversationWebDocumentBuilder.build(
                snapshot: RuntimeSnapshot(timeline: [], turns: turns),
                conversationID: "long-stress",
                revision: UInt64(revision)
            )
            let update = try XCTUnwrap(
                ConversationWebDocumentDiffer.update(from: previous, to: next)
            )
            let payload = try JSONEncoder().encode(update).base64EncodedString()
            _ = try await webView.evaluateJavaScript(
                "window.AgentKitWorkbench.applyUpdateBase64('\(payload)')"
            )
            previous = next
        }
        await fulfillment(of: [finalReadingPatch], timeout: 15)
        try await Task.sleep(for: .milliseconds(160))

        let readingInspection = try await webView.evaluateJavaScript(
            "({ y: window.scrollY, jump: Boolean(document.querySelector('.jump-to-latest')), tail: document.querySelector('[data-selection-id=\"block:text-499\"]').textContent, viewport: window.AgentKitWorkbench.viewportDiagnostics() })"
        ) as? [String: Any]
        let viewportDiagnostics = readingInspection?["viewport"]
        XCTAssertEqual(
            readingInspection?["y"] as? Double ?? -1,
            readingY ?? -2,
            accuracy: 1,
            String(describing: viewportDiagnostics)
        )
        XCTAssertEqual(readingInspection?["jump"] as? Bool, true)
        XCTAssertTrue((readingInspection?["tail"] as? String)?.contains("revision 51") == true)
        XCTAssertEqual(probe.lastViewportPinned, false)

        configuration.userContentController.removeScriptMessageHandler(forName: "agentkitWorkbench")
        _ = webView
    }
    #endif
}

#if os(macOS)
@MainActor
private final class ConversationWebBridgeProbe: NSObject, WKScriptMessageHandler {
    private let ready: XCTestExpectation
    private var acknowledgementExpectations: [Int: XCTestExpectation] = [:]
    private(set) var protocolVersion: Int?
    private(set) var acknowledgedRevision: Int?
    private(set) var lastViewportPinned: Bool?
    private(set) var lastViewportInteracting: Bool?

    init(ready: XCTestExpectation) {
        self.ready = ready
    }

    func expectAcknowledgement(revision: Int, expectation: XCTestExpectation) {
        acknowledgementExpectations[revision] = expectation
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            protocolVersion = body["protocolVersion"] as? Int
            ready.fulfill()
        case "ack":
            acknowledgedRevision = body["revision"] as? Int
            if let acknowledgedRevision,
               let expectation = acknowledgementExpectations.removeValue(
                   forKey: acknowledgedRevision
               ) {
                expectation.fulfill()
            }
        case "viewport":
            lastViewportPinned = body["pinned"] as? Bool
            lastViewportInteracting = body["interacting"] as? Bool
        default:
            break
        }
    }
}
#endif
