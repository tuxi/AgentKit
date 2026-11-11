#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

private struct FixturePreviewResourceResolvers: PreviewViewerResolver, PreviewAssetResolver, Sendable {
    let viewerData: Data
    let assetData: Data

    func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
        PreviewViewerResource(
            sessionID: request.sessionID,
            artifactID: request.artifactID,
            revision: request.revision,
            data: viewerData,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: viewerData.count,
            sha256: PreviewRFC8785.sha256(data: viewerData)
        )
    }

    func resolveContent(_ request: PreviewAssetRequest) async throws -> PreviewAssetResource {
        PreviewAssetResource(
            sessionID: request.sessionID,
            artifactID: request.artifactID,
            revision: request.revision,
            assetID: request.assetID,
            data: assetData,
            statusCode: 200,
            mimeType: "image/png",
            sizeBytes: assetData.count,
            sha256: PreviewRFC8785.sha256(data: assetData)
        )
    }
}

@MainActor
final class PreviewWorkbenchRenderTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    func testConversationWorkbenchRendersViewerAndFallbackImage() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let interactive = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let fallback = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("unavailable-with-fallback.json"))
        )
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let assetData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let resolver = FixturePreviewResourceResolvers(
            viewerData: viewerData,
            assetData: assetData
        )
        let turn = ConversationTurn(
            id: "turn_turn_fixture_user",
            userPrompt: MessageNodePayload(role: .user, text: "Show a preview"),
            blocks: [.text(
                id: "answer",
                MessageNodePayload(role: .assistant, text: "Preview ready.")
            )],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(
            timeline: [],
            turns: [turn],
            previewArtifacts: [interactive, fallback],
            generation: 1
        )
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "session_fixture",
            workspaceRoot: nil,
            previewViewerResolver: resolver,
            previewAssetResolver: resolver,
            extensionContributions: [:],
            timelineExtensions: [],
            isVisible: true,
            bottomInset: 0,
            onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
        )
        .environment(store)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit ConversationWorkbench Preview"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "Boolean(document.querySelector('[data-preview-id=\\\"preview_fixture_interactive\\\"]'))",
            webView: webView,
            timeout: 12
        )
        let parentCSP = try await webView.evaluateJavaScript(
            "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content"
        ) as? String
        XCTAssertTrue(parentCSP?.contains("frame-src agentkit-workbench:") == true)

        _ = try await webView.evaluateJavaScript("""
        document.querySelectorAll('details.preview-disclosure > summary')
          .forEach((summary) => summary.click());
        """)

        try await waitForJavaScript(
            "document.querySelector('iframe[data-preview-frame=\\\"preview_fixture_interactive\\\"]')?.dataset.loaded === 'true'",
            webView: webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('img[data-preview-fallback-asset-id=\\\"asset_fixture_fallback\\\"]')?.dataset.loaded === 'true'",
            webView: webView,
            timeout: 12
        )

        let sandbox = try await webView.evaluateJavaScript(
            "document.querySelector('iframe[data-preview-frame=\\\"preview_fixture_interactive\\\"]')?.getAttribute('sandbox')"
        ) as? String
        XCTAssertEqual(sandbox, "allow-scripts")
        let frameSource = try await webView.evaluateJavaScript(
            "document.querySelector('iframe[data-preview-frame=\\\"preview_fixture_interactive\\\"]')?.src"
        ) as? String
        let firstFrameSource = try XCTUnwrap(frameSource)
        XCTAssertTrue(firstFrameSource.hasPrefix("agentkit-workbench://preview/"))
        let fallbackWidth = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-preview-fallback-asset-id=\\\"asset_fixture_fallback\\\"]')?.naturalWidth"
        ) as? Int
        XCTAssertGreaterThan(fallbackWidth ?? 0, 0)

        let fallbackEvidence = try await webView.evaluateJavaScript("""
        document.querySelector('[data-preview-id="preview_fixture_unavailable_with_fallback"] .preview-evidence')?.textContent
        """) as? String
        XCTAssertTrue(fallbackEvidence?.contains("Interactive preview unavailable. Showing static evidence.") == true)

        let screenshotDirectory = try screenshotDirectoryURL()
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-preview-id="preview_fixture_interactive"]')
          ?.scrollIntoView({ block: 'start' });
        """)
        try await Task.sleep(for: .milliseconds(300))
        try await saveSnapshot(
            of: webView,
            to: screenshotDirectory.appendingPathComponent("a5-interactive-preview.png")
        )

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-preview-id="preview_fixture_unavailable_with_fallback"]')
          ?.scrollIntoView({ block: 'start' });
        """)
        try await Task.sleep(for: .milliseconds(300))
        try await saveSnapshot(
            of: webView,
            to: screenshotDirectory.appendingPathComponent("a5-fallback-preview.png")
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: screenshotDirectory.appendingPathComponent("a5-interactive-preview.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: screenshotDirectory.appendingPathComponent("a5-fallback-preview.png").path
        ))

        // Preview tokens are single-use, but the loaded iframe remains mounted
        // while its disclosure is closed. Reopening must not trigger a second
        // navigation through the already-consumed token.
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-preview-id="preview_fixture_interactive"] summary')?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-preview-id=\"preview_fixture_interactive\"] details')?.open === false",
            webView: webView,
            timeout: 5
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-preview-id="preview_fixture_interactive"] summary')?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-preview-id=\"preview_fixture_interactive\"] details')?.open === true",
            webView: webView,
            timeout: 5
        )
        let secondFrameSource = try await webView.evaluateJavaScript(
            "document.querySelector('iframe[data-preview-frame=\"preview_fixture_interactive\"]')?.src"
        ) as? String
        XCTAssertEqual(secondFrameSource, firstFrameSource)
    }

    func testInteractiveReadyDoesNotRenderFallbackUnavailableEvidence() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let interactive = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let assetData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let resolver = FixturePreviewResourceResolvers(
            viewerData: viewerData,
            assetData: assetData
        )
        let turn = ConversationTurn(
            id: "turn_turn_fixture_user",
            userPrompt: MessageNodePayload(role: .user, text: "Show a preview"),
            blocks: [.text(
                id: "answer",
                MessageNodePayload(role: .assistant, text: "Preview ready.")
            )],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(
            timeline: [],
            turns: [turn],
            previewArtifacts: [interactive],
            generation: 1
        )
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "session_fixture",
            workspaceRoot: nil,
            previewViewerResolver: resolver,
            previewAssetResolver: resolver,
            extensionContributions: [:],
            timelineExtensions: [],
            isVisible: true,
            bottomInset: 0,
            onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
        )
        .environment(store)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit ConversationWorkbench Preview State"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "Boolean(document.querySelector('[data-preview-id=\"preview_fixture_interactive\"]'))",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const summary = document.querySelector('[data-preview-id="preview_fixture_interactive"] summary');
          if (summary?.parentElement?.open === false) {
            summary.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          }
        })()
        """)
        try await waitForJavaScript(
            "document.querySelector('iframe[data-preview-frame=\"preview_fixture_interactive\"]')?.dataset.loaded === 'true'",
            webView: webView,
            timeout: 12
        )

        let inspection = try await webView.evaluateJavaScript("""
        (() => {
          const section = document.querySelector('[data-preview-id="preview_fixture_interactive"]');
          const text = section?.textContent ?? '';
          return {
            status: section?.getAttribute('data-status'),
            evidence: section?.querySelector('.preview-evidence')?.textContent ?? null,
            hasUnavailableText: text.includes('Interactive preview unavailable. Showing static evidence.')
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(inspection?["status"] as? String, "interactiveReady")
        XCTAssertNil(inspection?["evidence"] as? String)
        XCTAssertEqual(inspection?["hasUnavailableText"] as? Bool, false)
    }

    func testConversationWorkbenchRendersImageViewSourceAndCrop() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-image-view-\(UUID().uuidString)", isDirectory: true)
        let images = workspace.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sourceURL = images.appendingPathComponent("screen.png")
        let cropURL = images.appendingPathComponent("screen-crop.png")
        try writeImageFixture(
            to: sourceURL,
            size: NSSize(width: 640, height: 400),
            color: NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.64, alpha: 1),
            label: "SOURCE"
        )
        try writeImageFixture(
            to: cropURL,
            size: NSSize(width: 320, height: 160),
            color: NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.20, alpha: 1),
            label: "CROP"
        )

        let sourceID = "asset_render_source"
        let cropID = "asset_render_crop"
        let sourceAsset = AgentAssetRef(
            id: sourceID,
            kind: "image",
            displayName: "screen.png",
            workspaceRelativePath: "images/screen.png",
            mimeType: "image/png"
        )
        let cropAsset = AgentAssetRef(
            id: cropID,
            kind: "image",
            displayName: "screen-crop.png",
            workspaceRelativePath: "images/screen-crop.png",
            mimeType: "image/png"
        )
        let tool = ToolNodePayload(
            callID: "call_image_view",
            toolName: "generic_image_surface",
            args: nil,
            status: .completed,
            output: "structured image result",
            structuredOutput: imageViewRenderOutput(sourceID: sourceID, cropID: cropID),
            assets: [sourceAsset, cropAsset]
        )
        let turn = ConversationTurn(
            id: "turn-image-view",
            userPrompt: MessageNodePayload(role: .user, text: "Inspect this screen"),
            blocks: [.toolGroup(ToolGroup(id: "image-activity", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn], generation: 1)
        let expectedTitle = ToolTranscriptText().text("image.viewed", 1)
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "image-view-render",
            workspaceRoot: workspace,
            previewViewerResolver: nil,
            previewAssetResolver: nil,
            extensionContributions: [:],
            timelineExtensions: [],
            isVisible: true,
            bottomInset: 0,
            onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
        )
        .environment(store)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit Image View Activity"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        do {
            try await waitForJavaScript(
                "document.querySelector('[data-tool-id=\"call_image_view\"]') !== null",
                webView: webView,
                timeout: 12
            )
        } catch {
            let body = try? await webView.evaluateJavaScript("document.body?.innerText ?? ''")
            print("[ImageViewRender] body after tool wait: \(String(describing: body))")
            throw error
        }
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('.turn-process-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        do {
            try await waitForJavaScript(
                "document.querySelector('.turn-process')?.open === true",
                webView: webView,
                timeout: 5
            )
            try await waitForJavaScript(
                "document.querySelector('.image-view-thumbnail img')?.naturalWidth > 0",
                webView: webView,
                timeout: 12
            )
        } catch {
            let state = try? await webView.evaluateJavaScript("""
            (() => {
              const img = document.querySelector('.image-view-thumbnail img');
              return { body: document.body?.innerText ?? '', src: img?.src ?? '', complete: img?.complete ?? false, naturalWidth: img?.naturalWidth ?? 0 };
            })()
            """)
            print("[ImageViewRender] state after thumbnail wait: \(String(describing: state))")
            throw error
        }

        let collapsed = try await webView.evaluateJavaScript("""
        (() => {
          const tool = document.querySelector('[data-tool-id="call_image_view"]');
          const thumb = tool?.querySelector('.image-view-thumbnail img');
          return {
            title: tool?.querySelector('.tool-title')?.textContent ?? '',
            thumbnailWidth: thumb?.naturalWidth ?? 0,
            sourceURL: thumb?.src ?? ''
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(collapsed?["title"] as? String, expectedTitle)
        XCTAssertGreaterThan(collapsed?["thumbnailWidth"] as? Int ?? 0, 0)
        XCTAssertTrue((collapsed?["sourceURL"] as? String)?.hasPrefix("agentkit-workbench://local-asset/") == true)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="call_image_view"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-image-view-node=\"source\"] img')?.naturalWidth > 0 && document.querySelector('[data-image-view-node=\"crop\"] img')?.naturalWidth > 0",
            webView: webView,
            timeout: 12
        )

        let expanded = try await webView.evaluateJavaScript("""
        (() => {
          const activity = document.querySelector('.image-view-activity');
          const source = activity?.querySelector('[data-image-view-node="source"]');
          const crop = activity?.querySelector('[data-image-view-node="crop"]');
          const text = activity?.textContent ?? '';
          return {
            sourceFirst: activity?.firstElementChild?.getAttribute('data-image-view-node') ?? '',
            assetOrder: activity?.getAttribute('data-image-view-asset-order') ?? '',
            sourceID: source?.querySelector('.image-view-preview')?.getAttribute('data-image-view-asset-id') ?? '',
            sourceWidth: source?.querySelector('img')?.naturalWidth ?? 0,
            cropWidth: crop?.querySelector('img')?.naturalWidth ?? 0,
            cropParent: crop?.getAttribute('data-parent-asset-id') ?? '',
            hasMetadataText: /SOURCE|Effective size|Effective detail|Requested:/.test(text),
            hasActions: /View original|View source|View crop/.test(text),
            hasToolChrome: /原始详情|Raw details|Open artifact/.test(text)
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(expanded?["sourceFirst"] as? String, "source")
        XCTAssertEqual(expanded?["assetOrder"] as? String, "\(sourceID),\(cropID)")
        XCTAssertEqual(expanded?["sourceID"] as? String, sourceID)
        XCTAssertGreaterThan(expanded?["sourceWidth"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(expanded?["cropWidth"] as? Int ?? 0, 0)
        XCTAssertEqual(expanded?["cropParent"] as? String, sourceID)
        XCTAssertEqual(expanded?["hasMetadataText"] as? Bool, false)
        XCTAssertEqual(expanded?["hasActions"] as? Bool, false)
        XCTAssertEqual(expanded?["hasToolChrome"] as? Bool, false)

        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("image-view-source-crop.png")
        try await saveSnapshot(of: webView, to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
    }

    func testConversationWorkbenchRendersRealCodeAgentViewImagePayloadLiveAndReplay() async throws {
        let fixture = try loadCodeAgentViewImageFixture()
        let snapshots = try await codeAgentViewImageSnapshots(fixture)
        let expectedTitle = ToolTranscriptText().text("image.viewed", 1)
        let workspace = codeAgentViewImageFixtureRoot().appendingPathComponent("workspace", isDirectory: true)

        let live = try await presentCodeAgentImageViewWorkbench(
            snapshot: snapshots.live,
            conversationID: "real-code-agent-live",
            workspace: workspace
        )
        try await expandCodeAgentImageViewTool(in: live.webView, toolID: fixture.callID)
        try await waitForJavaScript(
            "document.querySelector('[data-image-view-node=\"source\"] img')?.naturalWidth > 0 && document.querySelector('[data-image-view-node=\"crop\"] img')?.naturalWidth > 0",
            webView: live.webView,
            timeout: 12
        )
        let liveInspection = try await inspectCodeAgentImageView(
            in: live.webView,
            expected: fixture
        )
        XCTAssertEqual(liveInspection.sourceID, fixture.sourceAssetID)
        XCTAssertEqual(liveInspection.cropParent, fixture.sourceAssetID)
        live.window.orderOut(nil)
        self.window = nil

        let replay = try await presentCodeAgentImageViewWorkbench(
            snapshot: snapshots.replay,
            conversationID: "real-code-agent-replay",
            workspace: workspace
        )
        try await expandCodeAgentImageViewTool(in: replay.webView, toolID: fixture.callID)
        try await waitForJavaScript(
            "document.querySelector('[data-image-view-node=\"source\"] img')?.naturalWidth > 0 && document.querySelector('[data-image-view-node=\"crop\"] img')?.naturalWidth > 0",
            webView: replay.webView,
            timeout: 12
        )
        let replayInspection = try await inspectCodeAgentImageView(
            in: replay.webView,
            expected: fixture
        )

        XCTAssertEqual(replayInspection.title, expectedTitle)
        XCTAssertEqual(replayInspection.sourceFirst, "source")
        XCTAssertEqual(replayInspection.assetOrder, "\(fixture.sourceAssetID),\(fixture.cropAssetID)")
        XCTAssertEqual(replayInspection.sourceID, fixture.sourceAssetID)
        XCTAssertEqual(replayInspection.cropParent, fixture.sourceAssetID)
        XCTAssertEqual(replayInspection.sourceWidth, liveInspection.sourceWidth)
        XCTAssertEqual(replayInspection.cropWidth, liveInspection.cropWidth)
        XCTAssertEqual(replayInspection.hasMetadataText, false)
        XCTAssertEqual(replayInspection.hasActions, false)
        XCTAssertEqual(replayInspection.hasToolChrome, false)
        XCTAssertEqual(replayInspection.isStandaloneToolGroup, true)
        XCTAssertEqual(replayInspection.hasVisibleThumbnail, true)

        let screenshotDirectory = try screenshotDirectoryURL()
        let sourceScreenshot = screenshotDirectory
            .appendingPathComponent("image-view-real-code-agent-payload-source.png")
        try await saveSnapshot(of: replay.webView, to: sourceScreenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceScreenshot.path))

        _ = try await replay.webView.evaluateJavaScript("""
        (() => {
          const scroller = document.querySelector('.tool-group-tools');
          if (scroller) scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
        })()
        """)
        try await Task.sleep(for: .milliseconds(250))
        let cropScreenshot = screenshotDirectory
            .appendingPathComponent("image-view-real-code-agent-payload-crop.png")
        try await saveSnapshot(of: replay.webView, to: cropScreenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cropScreenshot.path))
    }

    private struct CodeAgentViewImageFixture {
        let turnID: String
        let callID: String
        let result: ToolResult
        let sourceAssetID: String
        let cropAssetID: String
    }

    private struct CodeAgentViewImageSnapshots {
        let live: RuntimeSnapshot
        let replay: RuntimeSnapshot
    }

    private struct CodeAgentImageViewInspection {
        let title: String
        let sourceFirst: String
        let assetOrder: String
        let sourceID: String
        let cropParent: String
        let sourceWidth: Int
        let cropWidth: Int
        let hasMetadataText: Bool
        let hasActions: Bool
        let hasToolChrome: Bool
        let isStandaloneToolGroup: Bool
        let hasVisibleThumbnail: Bool
    }

    private struct PresentedCodeAgentImageViewWorkbench {
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
        let webView: WKWebView
        let store: WorkspaceStore
    }

    private func codeAgentViewImageFixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/view-image/code-agent-80329b1", isDirectory: true)
    }

    private func loadCodeAgentViewImageFixture() throws -> CodeAgentViewImageFixture {
        let url = codeAgentViewImageFixtureRoot().appendingPathComponent("source-and-crop.wire.json")
        let wire = try JSONDecoder().decode(WireFrame.self, from: Data(contentsOf: url))
        guard case .toolFinished(let rawTurnID, let callID, let result) = AgentEvent.from(wire: wire),
              let turnID = rawTurnID,
              let output = result.output,
              let sourceAssetID = output["source_asset_id"].string,
              let cropAssetID = output["crop_asset_id"].string else {
            throw NSError(domain: "PreviewWorkbenchRenderTests", code: 5)
        }
        return CodeAgentViewImageFixture(
            turnID: turnID,
            callID: callID,
            result: result,
            sourceAssetID: sourceAssetID,
            cropAssetID: cropAssetID
        )
    }

    private func codeAgentViewImageSnapshots(
        _ fixture: CodeAgentViewImageFixture
    ) async throws -> CodeAgentViewImageSnapshots {
        let prefix: [AgentEvent] = [
            .turnStarted(turnID: fixture.turnID, text: "Inspect this screen"),
            .toolStarted(
                turnID: fixture.turnID,
                callID: fixture.callID,
                tool: ToolCall(
                    callID: fixture.callID,
                    toolName: fixture.result.toolName,
                    toolArgs: nil
                )
            ),
            .toolFinished(
                turnID: fixture.turnID,
                callID: fixture.callID,
                result: fixture.result
            )
        ]
        let liveEngine = RuntimeEngine(sessionID: "real-code-agent-live")
        for event in prefix {
            await liveEngine.ingest(event)
        }
        let live = await liveEngine.currentSnapshot()

        let replayEngine = RuntimeEngine(sessionID: "real-code-agent-replay")
        await replayEngine.importHistory(prefix + [
            .turnFinished(turnID: fixture.turnID, text: "done", textAnnotations: [])
        ])
        let replay = await replayEngine.currentSnapshot()
        return CodeAgentViewImageSnapshots(live: live, replay: replay)
    }

    private func presentCodeAgentImageViewWorkbench(
        snapshot: RuntimeSnapshot,
        conversationID: String,
        workspace: URL
    ) async throws -> PresentedCodeAgentImageViewWorkbench {
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = AnyView(
            ConversationWebWorkbenchView(
                snapshot: snapshot,
                conversationID: conversationID,
                workspaceRoot: workspace,
                previewViewerResolver: nil,
                previewAssetResolver: nil,
                extensionContributions: [:],
                timelineExtensions: [],
                isVisible: true,
                bottomInset: 0,
                onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
            )
            .environment(store)
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit Real code-agent image_view"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window
        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.body?.innerText?.length > 0",
            webView: webView,
            timeout: 12
        )
        return PresentedCodeAgentImageViewWorkbench(
            window: window,
            hostingView: hostingView,
            webView: webView,
            store: store
        )
    }

    private func expandCodeAgentImageViewTool(
        in webView: WKWebView,
        toolID: String
    ) async throws {
        do {
            try await waitForJavaScript(
                "document.querySelector('.tool-group') !== null || document.querySelector('[data-tool-id=\"\(toolID)\"]') !== null",
                webView: webView,
                timeout: 12
            )
        } catch {
            let body = try? await webView.evaluateJavaScript("document.body?.innerText ?? ''")
            print("[RealImageViewRender] initial body: \(String(describing: body))")
            throw error
        }
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const process = document.querySelector('.turn-process');
          if (process && !process.open) {
            process.querySelector('.turn-process-summary')
              ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          }
        })()
        """)
        try await waitForJavaScript(
            "!document.querySelector('.turn-process') || document.querySelector('.turn-process')?.open === true",
            webView: webView,
            timeout: 5
        )
        _ = try await webView.evaluateJavaScript("""
        (() => {
          if (document.querySelector('[data-tool-id="\(toolID)"]')) return;
          document.querySelector('.tool-group > .tool-group-summary')
            ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        })()
        """)
        do {
            try await waitForJavaScript(
                "document.querySelector('[data-tool-id=\"\(toolID)\"]') !== null",
                webView: webView,
                timeout: 12
            )
            try await waitForJavaScript(
                "document.querySelector('[data-tool-id=\"\(toolID)\"] .image-view-thumbnail img')?.naturalWidth > 0",
                webView: webView,
                timeout: 12
            )
        } catch {
            let state = try? await webView.evaluateJavaScript("""
            (() => ({
              body: document.body?.innerText ?? '',
              processOpen: document.querySelector('.turn-process')?.open ?? null,
              groupOpen: document.querySelector('.tool-group')?.open ?? null,
              tool: Boolean(document.querySelector('[data-tool-id="\(toolID)"]')),
              thumb: document.querySelector('.image-view-thumbnail img')?.naturalWidth ?? 0
            }))()
            """)
            print("[RealImageViewRender] expanded state: \(String(describing: state))")
            throw error
        }
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="\(toolID)"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
    }

    private func inspectCodeAgentImageView(
        in webView: WKWebView,
        expected: CodeAgentViewImageFixture
    ) async throws -> CodeAgentImageViewInspection {
        let state = try await webView.evaluateJavaScript("""
        (() => {
          const tool = document.querySelector('[data-tool-id="\(expected.callID)"]');
          const activity = document.querySelector('.image-view-activity');
          const source = activity?.querySelector('[data-image-view-node="source"]');
          const crop = activity?.querySelector('[data-image-view-node="crop"]');
          const text = activity?.textContent ?? '';
          const toolGroup = tool?.closest('.tool-group');
          return {
            title: tool?.querySelector('.tool-title')?.textContent ?? '',
            sourceFirst: activity?.firstElementChild?.getAttribute('data-image-view-node') ?? '',
            assetOrder: activity?.getAttribute('data-image-view-asset-order') ?? '',
            sourceID: source?.querySelector('.image-view-preview')?.getAttribute('data-image-view-asset-id') ?? '',
            cropParent: crop?.getAttribute('data-parent-asset-id') ?? '',
            sourceWidth: source?.querySelector('img')?.naturalWidth ?? 0,
            cropWidth: crop?.querySelector('img')?.naturalWidth ?? 0,
            hasMetadataText: /SOURCE|Effective size|Effective detail|Requested:/.test(text),
            hasActions: /View original|View source|View crop/.test(text),
            hasToolChrome: /原始详情|Raw details|Open artifact/.test(text),
            isStandaloneToolGroup: Boolean(toolGroup && !toolGroup.querySelector(':scope > .tool-group-summary')),
            hasVisibleThumbnail: (tool?.querySelector('.image-view-thumbnail img')?.naturalWidth ?? 0) > 0
          };
        })()
        """) as? [String: Any]
        return CodeAgentImageViewInspection(
            title: state?["title"] as? String ?? "",
            sourceFirst: state?["sourceFirst"] as? String ?? "",
            assetOrder: state?["assetOrder"] as? String ?? "",
            sourceID: state?["sourceID"] as? String ?? "",
            cropParent: state?["cropParent"] as? String ?? "",
            sourceWidth: state?["sourceWidth"] as? Int ?? 0,
            cropWidth: state?["cropWidth"] as? Int ?? 0,
            hasMetadataText: state?["hasMetadataText"] as? Bool ?? true,
            hasActions: state?["hasActions"] as? Bool ?? true,
            hasToolChrome: state?["hasToolChrome"] as? Bool ?? true,
            isStandaloneToolGroup: state?["isStandaloneToolGroup"] as? Bool ?? false,
            hasVisibleThumbnail: state?["hasVisibleThumbnail"] as? Bool ?? false
        )
    }

    private func writeImageFixture(
        to url: URL,
        size: NSSize,
        color: NSColor,
        label: String
    ) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(size.width, size.height) * 0.16, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PreviewWorkbenchRenderTests", code: 4)
        }
        try png.write(to: url, options: .atomic)
    }

    private func imageViewRenderOutput(sourceID: String, cropID: String) -> JSONValue {
        let bbox: JSONValue = .object([
            "x": .number(0.15),
            "y": .number(0.2),
            "width": .number(0.5),
            "height": .number(0.4)
        ])
        return .object([
            "schema": .string("view_image_result.v1"),
            "kind": .string("image_view"),
            "source_asset_id": .string(sourceID),
            "crop_asset_id": .string(cropID),
            "assets": .array([
                .object([
                    "asset_id": .string(sourceID),
                    "role": .string("source"),
                    "asset_role": .string("source"),
                    "relative_path": .string("images/screen.png"),
                    "filename": .string("screen.png"),
                    "mime_type": .string("image/png"),
                    "width": .integer(640),
                    "height": .integer(400),
                    "sha256": .string(String(repeating: "a", count: 64))
                ]),
                .object([
                    "asset_id": .string(cropID),
                    "role": .string("crop"),
                    "asset_role": .string("crop"),
                    "relative_path": .string("images/screen-crop.png"),
                    "filename": .string("screen-crop.png"),
                    "mime_type": .string("image/png"),
                    "width": .integer(320),
                    "height": .integer(160),
                    "sha256": .string(String(repeating: "b", count: 64)),
                    "source_asset_id": .string(sourceID),
                    "source_bbox": bbox,
                    "purpose": .string("detail")
                ])
            ]),
            "detail_requested": .string("original"),
            "detail_effective": .string("original"),
            "source_region": bbox
        ])
    }

    private func waitForWebView(in root: NSView) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let webView = findWebView(in: root) { return webView }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "PreviewWorkbenchRenderTests", code: 1)
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }

    private func waitForJavaScript(
        _ script: String,
        webView: WKWebView,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try await webView.evaluateJavaScript(script) as? Bool) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "PreviewWorkbenchRenderTests", code: 2)
    }

    private func screenshotDirectoryURL() throws -> URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["PREVIEW_WORKBENCH_SCREENSHOT_DIR"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("agentkit-a5-preview", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func saveSnapshot(of webView: WKWebView, to url: URL) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PreviewWorkbenchRenderTests", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }
}
#endif
