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

    func testConversationWorkbenchRendersUIEvidenceSourceCropAndInspectorActions() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-ui-evidence-\(UUID().uuidString)", isDirectory: true)
        let images = workspace.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = images.appendingPathComponent("screen.png")
        let cropURL = images.appendingPathComponent("screen-crop.png")
        try writeImageFixture(
            to: sourceURL,
            size: NSSize(width: 640, height: 400),
            color: NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.66, alpha: 1),
            label: "SOURCE"
        )
        try writeImageFixture(
            to: cropURL,
            size: NSSize(width: 320, height: 160),
            color: NSColor(calibratedRed: 0.75, green: 0.34, blue: 0.18, alpha: 1),
            label: "CROP"
        )

        let sourceID = "asset_ui_evidence_source"
        let cropID = "asset_ui_evidence_crop"
        let tool = ToolNodePayload(
            callID: "call_ui_evidence",
            toolName: "arbitrary_evidence_surface",
            args: nil,
            status: .completed,
            output: "evidence",
            structuredOutput: uiEvidenceRenderOutput(sourceID: sourceID, cropID: cropID),
            assets: [
                AgentAssetRef(
                    id: sourceID,
                    kind: "image",
                    displayName: "screen.png",
                    workspaceRelativePath: "images/screen.png",
                    mimeType: "image/png"
                ),
                AgentAssetRef(
                    id: cropID,
                    kind: "image",
                    displayName: "screen-crop.png",
                    workspaceRelativePath: "images/screen-crop.png",
                    mimeType: "image/png"
                ),
            ]
        )
        let turn = ConversationTurn(
            id: "turn-ui-evidence",
            userPrompt: MessageNodePayload(role: .user, text: "Inspect this screen"),
            blocks: [.toolGroup(ToolGroup(id: "ui-evidence-activity", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn], generation: 1)
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "ui-evidence-render",
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit UI Evidence Workbench"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_evidence\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('.turn-process-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        do {
            try await waitForJavaScript(
                "document.querySelector('[data-tool-id=\"call_ui_evidence\"] .image-view-thumbnail img')?.naturalWidth > 0",
                webView: webView,
                timeout: 12
            )
        } catch {
            let body = try? await webView.evaluateJavaScript("document.body?.innerText ?? ''")
            let state = try? await webView.evaluateJavaScript("""
            (() => {
              const tool = document.querySelector('[data-tool-id="call_ui_evidence"]');
              const img = tool?.querySelector('.image-view-thumbnail img');
              return { open: document.querySelector('.turn-process')?.open ?? null, tool: tool?.outerHTML ?? '', src: img?.src ?? '', width: img?.naturalWidth ?? 0 };
            })()
            """)
            print("[UIEvidenceRender] body: \(String(describing: body))")
            print("[UIEvidenceRender] state: \(String(describing: state))")
            throw error
        }

        let collapsed = try await webView.evaluateJavaScript("""
        (() => {
          const tool = document.querySelector('[data-tool-id="call_ui_evidence"]');
          const thumb = tool?.querySelector('.image-view-thumbnail img');
          return {
            title: tool?.querySelector('.tool-title')?.textContent ?? '',
            thumbnailWidth: thumb?.naturalWidth ?? 0,
            sourceURL: thumb?.src ?? ''
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(collapsed?["title"] as? String, "UI evidence: screen.png")
        XCTAssertGreaterThan(collapsed?["thumbnailWidth"] as? Int ?? 0, 0)
        XCTAssertTrue((collapsed?["sourceURL"] as? String)?.hasPrefix("agentkit-workbench://local-asset/") == true)

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="call_ui_evidence"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-ui-evidence-node=\"source\"] img')?.naturalWidth > 0 && document.querySelector('[data-ui-evidence-node=\"crop\"] img')?.naturalWidth > 0",
            webView: webView,
            timeout: 12
        )

        let expanded = try await webView.evaluateJavaScript("""
        (() => {
          const activity = document.querySelector('.ui-evidence-activity');
          const source = activity?.querySelector('[data-ui-evidence-node="source"]');
          const crop = activity?.querySelector('[data-ui-evidence-node="crop"]');
          const ocr = activity?.querySelector('.ui-evidence-ocr-list');
          const text = activity?.textContent ?? '';
          return {
            sourceFirst: activity?.firstElementChild?.getAttribute('data-ui-evidence-node') ?? '',
            sourceID: source?.querySelector('.image-view-preview')?.getAttribute('data-image-view-asset-id') ?? '',
            sourceWidth: source?.querySelector('img')?.naturalWidth ?? 0,
            cropWidth: crop?.querySelector('img')?.naturalWidth ?? 0,
            cropParent: crop?.getAttribute('data-parent-asset-id') ?? '',
            hasSummary: /text/.test(text) && /containers/.test(text) && /repeated groups/.test(text),
            hasOCR: text.includes('Settings'),
            hasBBox: text.includes('bbox 0.120, 0.240'),
            hasObserved: text.includes('Observed'),
            hasInferred: text.includes('Inferred'),
            hasSourceTreeNote: text.includes('No AX/DOM tree was supplied'),
            hasUncertainty: text.includes('Small text may be unreadable'),
            hasWarning: text.includes('Element list was truncated'),
            hasRawJSON: text.includes('"schema"') || text.includes('"elements"'),
            hasRecommendation: text.includes('recommended_component') || text.includes('layout_should_be'),
            injectedImageCount: ocr?.querySelectorAll('img').length ?? -1,
            hasSourceAction: /View source/.test(text),
            hasCropAction: /View crop/.test(text),
            hasRawAction: /Inspect raw evidence/.test(text)
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(expanded?["sourceFirst"] as? String, "source")
        XCTAssertEqual(expanded?["sourceID"] as? String, sourceID)
        XCTAssertGreaterThan(expanded?["sourceWidth"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(expanded?["cropWidth"] as? Int ?? 0, 0)
        XCTAssertEqual(expanded?["cropParent"] as? String, sourceID)
        XCTAssertEqual(expanded?["hasSummary"] as? Bool, true)
        XCTAssertEqual(expanded?["hasOCR"] as? Bool, true)
        XCTAssertEqual(expanded?["hasBBox"] as? Bool, true)
        XCTAssertEqual(expanded?["hasObserved"] as? Bool, true)
        XCTAssertEqual(expanded?["hasInferred"] as? Bool, true)
        XCTAssertEqual(expanded?["hasSourceTreeNote"] as? Bool, true)
        XCTAssertEqual(expanded?["hasUncertainty"] as? Bool, true)
        XCTAssertEqual(expanded?["hasWarning"] as? Bool, true)
        XCTAssertEqual(expanded?["hasRawJSON"] as? Bool, false)
        XCTAssertEqual(expanded?["hasRecommendation"] as? Bool, false)
        XCTAssertEqual(expanded?["injectedImageCount"] as? Int, 0)
        XCTAssertEqual(expanded?["hasSourceAction"] as? Bool, true)
        XCTAssertEqual(expanded?["hasCropAction"] as? Bool, true)
        XCTAssertEqual(expanded?["hasRawAction"] as? Bool, true)

        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("ui-evidence-source-crop.png")
        try await saveSnapshot(of: webView, to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
        print("[UIEvidenceRender] screenshot: \(screenshot.path)")

        _ = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.ui-evidence-activity button')]
          .find((button) => button.textContent?.includes('View source'))?.click();
        """)
        let assetDeadline = Date().addingTimeInterval(5)
        while Date() < assetDeadline {
            if case .asset(let payload) = store.inspectorSelection,
               payload.asset.id == sourceID {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .asset(let payload) = store.inspectorSelection else {
            return XCTFail("View source did not open the source asset")
        }
        XCTAssertEqual(payload.asset.id, sourceID)

        _ = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.ui-evidence-activity button')]
          .find((button) => button.textContent?.includes('View crop'))?.click();
        """)
        let cropDeadline = Date().addingTimeInterval(5)
        while Date() < cropDeadline {
            if case .asset(let payload) = store.inspectorSelection,
               payload.asset.id == cropID {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .asset(let cropPayload) = store.inspectorSelection else {
            return XCTFail("View crop did not open the crop asset")
        }
        XCTAssertEqual(cropPayload.asset.id, cropID)
        XCTAssertEqual(cropPayload.asset.workspaceRelativePath, "images/screen-crop.png")

        _ = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.ui-evidence-activity button')]
          .find((button) => button.textContent?.includes('Inspect raw evidence'))?.click();
        """)
        let rawDeadline = Date().addingTimeInterval(5)
        while Date() < rawDeadline {
            if case .uiEvidence(let selection) = store.inspectorSelection,
               selection.callID == "call_ui_evidence" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .uiEvidence(let selection) = store.inspectorSelection else {
            return XCTFail("Inspect raw evidence did not open the evidence Inspector")
        }
        XCTAssertEqual(selection.callID, "call_ui_evidence")
    }

    func testConversationWorkbenchRendersUILayoutOverlayMetadataAndInspectorActions() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-ui-layout-\(UUID().uuidString)", isDirectory: true)
        let revision = workspace
            .appendingPathComponent(".codeagent/assets/ui-layout/layout_render/revision-000003", isDirectory: true)
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let overlayURL = revision.appendingPathComponent("overlay.png")
        try writeImageFixture(
            to: overlayURL,
            size: NSSize(width: 200, height: 400),
            color: NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.36, alpha: 1),
            label: "OVERLAY"
        )
        try Data("{}".utf8).write(to: revision.appendingPathComponent("layout.json"))

        let overlayID = "asset_layout_overlay"
        let layoutJSONID = "asset_layout_json"
        let artifactID = "layout_render"
        let sourceSHA = String(repeating: "a", count: 64)
        let evidenceSHA = String(repeating: "b", count: 64)
        let revisionSHA = "sha256:" + String(repeating: "c", count: 64)
        let overlayPath = ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/overlay.png"
        let layoutPath = ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/layout.json"
        let sharedMetadata: [String: JSONValue] = [
            "layout_artifact_id": .string(artifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(revisionSHA),
            "source_asset_id": .string("asset_source_screen"),
            "source_asset_sha256": .string(sourceSHA),
            "canvas": .object(["width": .integer(200), "height": .integer(400)]),
            "node_count": .integer(3),
        ]
        let output: JSONValue = .object([
            "schema": .string("ui_layout_result.v1"),
            "layout_artifact_id": .string(artifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(revisionSHA),
            "source_asset_id": .string("asset_source_screen"),
            "source_asset_sha256": .string(sourceSHA),
            "evidence_sha256": .string(evidenceSHA),
            "canvas": .object(["width": .integer(200), "height": .integer(400)]),
            "node_count": .integer(3),
            "assumption_count": .integer(1),
            "targets": .array([.string("duo_folded"), .string("iphone_portrait")]),
            "created": .bool(true),
            "overlay_asset": .object([
                "asset_id": .string(overlayID),
                "asset_role": .string("layout_overlay"),
                "kind": .string("image"),
                "relative_path": .string(overlayPath),
                "filename": .string("overlay.png"),
                "mime_type": .string("image/png"),
                "width": .integer(200),
                "height": .integer(400),
                "sha256": .string(String(repeating: "d", count: 64)),
            ]),
            "layout_json_asset": .object([
                "asset_id": .string(layoutJSONID),
                "asset_role": .string("layout_json"),
                "kind": .string("file"),
                "relative_path": .string(layoutPath),
                "filename": .string("layout.json"),
                "mime_type": .string("application/json"),
                "sha256": .string(String(repeating: "c", count: 64)),
            ]),
        ])
        var overlayMetadata = sharedMetadata
        overlayMetadata["asset_role"] = .string("layout_overlay")
        var jsonMetadata = sharedMetadata
        jsonMetadata["asset_role"] = .string("layout_json")
        let tool = ToolNodePayload(
            callID: "call_ui_layout",
            toolName: "arbitrary_layout_surface",
            args: nil,
            status: .completed,
            output: "layout",
            structuredOutput: output,
            assets: [
                AgentAssetRef(
                    id: overlayID,
                    kind: "image",
                    displayName: "overlay.png",
                    workspaceRelativePath: overlayPath,
                    mimeType: "image/png",
                    metadata: overlayMetadata
                ),
                AgentAssetRef(
                    id: layoutJSONID,
                    kind: "file",
                    displayName: "layout.json",
                    workspaceRelativePath: layoutPath,
                    mimeType: "application/json",
                    metadata: jsonMetadata
                ),
            ]
        )
        let turn = ConversationTurn(
            id: "turn-ui-layout",
            userPrompt: MessageNodePayload(role: .user, text: "Analyze this layout"),
            blocks: [.toolGroup(ToolGroup(id: "ui-layout-activity", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(timeline: [], turns: [turn], generation: 1)
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "ui-layout-render",
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit UI Layout Workbench"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_layout\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('.turn-process-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_layout\"] .image-view-thumbnail img')?.naturalWidth > 0",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id=\"call_ui_layout\"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-ui-layout-node=\"overlay\"] img')?.naturalWidth > 0",
            webView: webView,
            timeout: 12
        )

        let expanded = try await webView.evaluateJavaScript("""
        (() => {
          const activity = document.querySelector('.ui-layout-activity');
          const overlay = activity?.querySelector('[data-ui-layout-node="overlay"]');
          const text = activity?.textContent ?? '';
          return {
            artifactID: activity?.getAttribute('data-ui-layout-artifact-id') ?? '',
            revision: activity?.getAttribute('data-ui-layout-revision') ?? '',
            created: activity?.getAttribute('data-ui-layout-created') ?? '',
            overlayAssetID: overlay?.querySelector('.image-view-preview')?.getAttribute('data-image-view-asset-id') ?? '',
            overlayWidth: overlay?.querySelector('img')?.naturalWidth ?? 0,
            hasRevision: /revision/.test(text),
            hasCanvas: text.includes('200 × 400'),
            hasNodes: text.includes('3') && /nodes/.test(text),
            hasTargets: text.includes('duo_folded') && text.includes('iphone_portrait'),
            hasEvidenceSHA: text.includes('\(evidenceSHA)'),
            hasCreated: text.includes('Created'),
            hasOverlayAction: /Open overlay/.test(text),
            hasJSONAction: /Open layout JSON/.test(text),
            hasMetadataAction: /Inspect metadata/.test(text)
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(expanded?["artifactID"] as? String, artifactID)
        XCTAssertEqual(expanded?["revision"] as? String, "3")
        XCTAssertEqual(expanded?["created"] as? String, "true")
        XCTAssertEqual(expanded?["overlayAssetID"] as? String, overlayID)
        XCTAssertGreaterThan(expanded?["overlayWidth"] as? Int ?? 0, 0)
        XCTAssertEqual(expanded?["hasRevision"] as? Bool, true)
        XCTAssertEqual(expanded?["hasCanvas"] as? Bool, true)
        XCTAssertEqual(expanded?["hasNodes"] as? Bool, true)
        XCTAssertEqual(expanded?["hasTargets"] as? Bool, true)
        XCTAssertEqual(expanded?["hasEvidenceSHA"] as? Bool, true)
        XCTAssertEqual(expanded?["hasCreated"] as? Bool, true)
        XCTAssertEqual(expanded?["hasOverlayAction"] as? Bool, true)
        XCTAssertEqual(expanded?["hasJSONAction"] as? Bool, true)
        XCTAssertEqual(expanded?["hasMetadataAction"] as? Bool, true)

        for (label, expectedID) in [
            ("Open overlay", overlayID),
            ("Open layout JSON", layoutJSONID),
        ] {
            _ = try await webView.evaluateJavaScript("""
            [...document.querySelectorAll('.ui-layout-activity button')]
              .find((button) => button.textContent?.includes('\(label)'))?.click();
            """)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if case .asset(let payload) = store.inspectorSelection,
                   payload.asset.id == expectedID {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard case .asset(let payload) = store.inspectorSelection else {
                return XCTFail("\(label) did not open the asset Inspector")
            }
            XCTAssertEqual(payload.asset.id, expectedID)
        }

        _ = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.ui-layout-activity button')]
          .find((button) => button.textContent?.includes('Inspect metadata'))?.click();
        """)
        let metadataDeadline = Date().addingTimeInterval(5)
        while Date() < metadataDeadline {
            if case .uiLayout(let selection) = store.inspectorSelection,
               selection.callID == "call_ui_layout" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .uiLayout(let selection) = store.inspectorSelection else {
            return XCTFail("Inspect metadata did not open the UI Layout Inspector")
        }
        XCTAssertEqual(selection.callID, "call_ui_layout")

        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("ui-layout-overlay.png")
        try await saveSnapshot(of: webView, to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
        print("[UILayoutRender] screenshot: \(screenshot.path)")
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

    private func uiEvidenceRenderOutput(sourceID: String, cropID: String) -> JSONValue {
        let bbox: JSONValue = .object([
            "x": .number(0.12),
            "y": .number(0.24),
            "width": .number(0.5),
            "height": .number(0.4)
        ])
        let textBBox: JSONValue = .object([
            "x": .number(0.12),
            "y": .number(0.24),
            "width": .number(0.4),
            "height": .number(0.08)
        ])
        return .object([
            "schema": .string("ui_evidence.v1"),
            "source": .object([
                "asset_id": .string(sourceID),
                "source_kind": .string("app_screenshot"),
                "sha256": .string(String(repeating: "a", count: 64)),
                "mime_type": .string("image/png"),
                "width": .integer(640),
                "height": .integer(400)
            ]),
            "coordinate_space": .string("normalized_top_left"),
            "producer": .object([
                "name": .string("ClientToolsKit.inspect_ui_image"),
                "version": .string("1")
            ]),
            "elements": .array([
                .object([
                    "id": .string("el_title"),
                    "kind": .string("text"),
                    "role": .string("heading"),
                    "bbox": textBBox,
                    "text": .string("Settings <img src=x onerror=alert(1)>"),
                    "confidence": .number(0.97),
                    "evidence": .string("observed")
                ]),
                .object([
                    "id": .string("el_toggle"),
                    "kind": .string("control"),
                    "role": .string("switch"),
                    "bbox": textBBox,
                    "text": .string("Wi-Fi"),
                    "confidence": .number(0.84),
                    "evidence": .string("inferred"),
                    "interactive": .bool(true)
                ]),
                .object([
                    "id": .string("el_region"),
                    "kind": .string("container"),
                    "bbox": bbox,
                    "confidence": .number(0.95),
                    "evidence": .string("observed")
                ])
            ]),
            "repeated_groups": .array([
                .object([
                    "id": .string("group_rows"),
                    "axis": .string("vertical"),
                    "member_ids": .array([.string("el_title"), .string("el_toggle")]),
                    "bbox": bbox,
                    "confidence": .number(0.83),
                    "evidence": .string("inferred")
                ])
            ]),
            "source_tree": .object([
                "kind": .string("none"),
                "nodes": .array([]),
                "truncated": .bool(false)
            ]),
            "crops": .array([
                .object([
                    "asset_id": .string(cropID),
                    "source_bbox": bbox,
                    "purpose": .string("detail")
                ])
            ]),
            "uncertainties": .array([
                .object([
                    "description": .string("Small text may be unreadable."),
                    "related_element_ids": .array([.string("el_title")]),
                    "reason": .string("low_resolution")
                ])
            ]),
            "limits": .object([
                "element_count": .integer(3),
                "elements_truncated": .bool(true),
                "tree_nodes_truncated": .bool(false)
            ])
        ])
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

    func testConversationWorkbenchRendersUIPreviewLineageViewerAndFallback() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let fallbackData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let fallbackSHA = String(
            PreviewRFC8785.sha256(data: fallbackData).dropFirst("sha256:".count)
        )
        let resolver = FixturePreviewResourceResolvers(
            viewerData: viewerData,
            assetData: fallbackData
        )
        let lineage = renderLineage()
        let artifact = try makeRenderArtifact(
            sessionID: "ui-preview-render",
            callID: "call_ui_preview",
            title: "DreamLog Duo Home",
            viewerData: viewerData,
            fallbackSHA256: fallbackSHA,
            lineage: lineage
        )
        let fallbackAsset = AgentAssetRef(
            id: "asset_render_fallback",
            kind: "image",
            displayName: "fallback.png",
            workspaceID: "ws_current",
            workspaceRelativePath: "assets/fallback.png",
            mimeType: "image/png",
            sourceCallID: "call_ui_preview"
        )
        let tool = ToolNodePayload(
            callID: "call_ui_preview",
            toolName: "ui_preview",
            args: nil,
            status: .completed,
            output: "Prepared adaptation preview.",
            structuredOutput: renderPreviewResult(
                fallbackPath: "assets/fallback.png",
                fallbackSHA256: fallbackSHA,
                lineage: lineage
            ),
            assets: [fallbackAsset]
        )
        let layoutTurn = ConversationTurn(
            id: "turn-ui-layout-support",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(
                id: "layout-support",
                tools: [renderLayoutTool()]
            ))],
            footer: nil,
            isLive: false
        )
        let turn = ConversationTurn(
            id: "turn-ui-preview",
            userPrompt: MessageNodePayload(role: .user, text: "Build the adaptation preview"),
            blocks: [.toolGroup(ToolGroup(id: "ui-preview-activity", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        let snapshot = RuntimeSnapshot(
            timeline: [],
            turns: [layoutTurn, turn],
            previewArtifacts: [artifact],
            generation: 1
        )
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: "ui-preview-render",
            workspaceRoot: root,
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_200)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit UI Preview Workbench"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window

        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_preview\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelectorAll('.turn-process-summary')
          .forEach((summary) => summary.dispatchEvent(
            new MouseEvent('click', { bubbles: true, cancelable: true })
          ));
        """)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_preview\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="call_ui_preview"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        try await waitForJavaScript(
            "document.querySelector('details.tool[data-tool-id=\"call_ui_preview\"]')?.open === true",
            webView: webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('.ui-preview-activity') !== null",
            webView: webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('[data-ui-preview-node=\"fallback\"] img')?.naturalWidth > 0",
            webView: webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('iframe[data-ui-preview-frame=\"preview_p1f_render\"]')?.src.startsWith('agentkit-workbench://preview/') === true",
            webView: webView,
            timeout: 12
        )
        let loaded = try await webView.evaluateJavaScript("""
        (() => {
          const activity = document.querySelector('.ui-preview-activity');
          const text = activity?.textContent ?? '';
          return {
            mode: activity?.getAttribute('data-ui-preview-mode') ?? '',
            artifactID: activity?.getAttribute('data-ui-preview-artifact-id') ?? '',
            revision: activity?.getAttribute('data-ui-preview-revision') ?? '',
            kind: activity?.getAttribute('data-ui-preview-kind') ?? '',
            hasModeLabel: text.includes('Adaptation Preview'),
            hasSource: text.includes('asset_source_screen'),
            hasSourceSHA: text.includes('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
            hasEvidence: text.includes('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
            hasLayout: text.includes('layout_abcdef0123456789'),
            hasTarget: text.includes('duo_folded') && text.includes('home'),
            hasMatrix: text.includes('matrix_duo_primary') && text.includes('iphone_portrait'),
            hasApproval: text.includes('user_confirmed') && text.includes('approval-note-1'),
            hasFallbackAction: /Open fallback PNG/.test(text),
            hasLayoutAction: /Open layout JSON/.test(text),
            hasEvidenceAction: /Open evidence JSON/.test(text),
            hasLineageAction: /Inspect lineage/.test(text)
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(loaded?["mode"] as? String, "adaptation")
        XCTAssertEqual(loaded?["artifactID"] as? String, "preview_p1f_render")
        XCTAssertEqual(loaded?["revision"] as? String, "1")
        XCTAssertEqual(loaded?["kind"] as? String, "interactive_html")
        for key in [
            "hasModeLabel", "hasSource", "hasSourceSHA", "hasEvidence", "hasLayout",
            "hasTarget", "hasMatrix", "hasApproval", "hasFallbackAction",
            "hasLayoutAction", "hasEvidenceAction", "hasLineageAction",
        ] {
            XCTAssertEqual(loaded?[key] as? Bool, true, key)
        }
        let renderDocument = ConversationWebDocumentBuilder.build(
            snapshot: snapshot,
            conversationID: "ui-preview-render"
        )
        XCTAssertNil(
            renderDocument.turns.last?.previews,
            "the tool card owns the only preview Block"
        )
        let encoded = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(renderDocument),
                encoding: .utf8
            )
        )
        XCTAssertFalse(encoded.contains("viewer_html"))
        XCTAssertFalse(encoded.contains("recommended_"))

        _ = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('.ui-preview-activity button')]
          .find((button) => button.textContent?.includes('Inspect lineage'))?.click();
        """)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .uiPreview(let selection) = store.inspectorSelection,
               selection.callID == "call_ui_preview" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .uiPreview(let selection) = store.inspectorSelection else {
            return XCTFail("Inspect lineage did not open the UI Preview Inspector")
        }
        XCTAssertEqual(selection.callID, "call_ui_preview")

        _ = try await webView.evaluateJavaScript("""
        document.querySelector('.ui-preview-activity')?.scrollIntoView({ block: 'start' });
        """)
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("ui-preview-lineage.png")
        try await saveSnapshot(of: webView, to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
        print("[UIPreviewRender] screenshot: \(screenshot.path)")
    }

    // MARK: - Viewer request / failure / late-artifact acceptance

    private final class RecordingPreviewResolver: PreviewViewerResolver, PreviewAssetResolver, @unchecked Sendable {
        struct ViewerRequest: Equatable {
            let sessionID: String
            let artifactID: String
            let revision: Int
        }

        private let lock = NSLock()
        private var recordedViewerRequests: [ViewerRequest] = []
        private let failViewer: Bool
        let viewerData: Data
        let assetData: Data

        init(viewerData: Data, assetData: Data, failViewer: Bool = false) {
            self.viewerData = viewerData
            self.assetData = assetData
            self.failViewer = failViewer
        }

        var viewerRequests: [ViewerRequest] {
            lock.withLock { recordedViewerRequests }
        }

        func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource {
            lock.withLock {
                recordedViewerRequests.append(ViewerRequest(
                    sessionID: request.sessionID,
                    artifactID: request.artifactID,
                    revision: request.revision
                ))
            }
            if failViewer {
                throw PreviewResourceError(
                    code: "preview_test_failure",
                    message: "Forced viewer failure."
                )
            }
            return PreviewViewerResource(
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

    private final class PreviewSnapshotDriver: ObservableObject {
        @Published var snapshot: RuntimeSnapshot

        init(snapshot: RuntimeSnapshot) {
            self.snapshot = snapshot
        }
    }

    private struct PreviewSnapshotHostView: View {
        @ObservedObject var driver: PreviewSnapshotDriver
        let store: WorkspaceStore
        let resolver: RecordingPreviewResolver
        let conversationID: String
        let workspace: URL

        var body: some View {
            ConversationWebWorkbenchView(
                snapshot: driver.snapshot,
                conversationID: conversationID,
                workspaceRoot: workspace,
                previewViewerResolver: resolver,
                previewAssetResolver: resolver,
                extensionContributions: [:],
                timelineExtensions: [],
                isVisible: true,
                bottomInset: 0,
                onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
            )
            .environment(store)
        }
    }

    private struct UIPreviewRenderFixture {
        let root: URL
        let artifact: PreviewArtifact
        let snapshotWithoutArtifact: RuntimeSnapshot
        let snapshotWithArtifact: RuntimeSnapshot
        let conversationID: String
    }

    private func makeUIPreviewRenderFixture() throws -> UIPreviewRenderFixture {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let fallbackData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let fallbackSHA = String(
            PreviewRFC8785.sha256(data: fallbackData).dropFirst("sha256:".count)
        )
        let conversationID = "ui-preview-render"
        let lineage = renderLineage()
        let artifact = try makeRenderArtifact(
            sessionID: conversationID,
            callID: "call_ui_preview",
            title: "DreamLog Duo Home",
            viewerData: viewerData,
            fallbackSHA256: fallbackSHA,
            lineage: lineage
        )
        let fallbackAsset = AgentAssetRef(
            id: "asset_render_fallback",
            kind: "image",
            displayName: "fallback.png",
            workspaceID: "ws_current",
            workspaceRelativePath: "assets/fallback.png",
            mimeType: "image/png",
            sourceCallID: "call_ui_preview"
        )
        let tool = ToolNodePayload(
            callID: "call_ui_preview",
            toolName: "ui_preview",
            args: nil,
            status: .completed,
            output: "Prepared adaptation preview.",
            structuredOutput: renderPreviewResult(
                fallbackPath: "assets/fallback.png",
                fallbackSHA256: fallbackSHA,
                lineage: lineage
            ),
            assets: [fallbackAsset]
        )
        let layoutTurn = ConversationTurn(
            id: "turn-ui-layout-support",
            userPrompt: nil,
            blocks: [.toolGroup(ToolGroup(
                id: "layout-support",
                tools: [renderLayoutTool()]
            ))],
            footer: nil,
            isLive: false
        )
        let turn = ConversationTurn(
            id: "turn-ui-preview",
            userPrompt: MessageNodePayload(role: .user, text: "Build the adaptation preview"),
            blocks: [.toolGroup(ToolGroup(id: "ui-preview-activity", tools: [tool]))],
            footer: nil,
            isLive: false
        )
        return UIPreviewRenderFixture(
            root: root,
            artifact: artifact,
            snapshotWithoutArtifact: RuntimeSnapshot(
                timeline: [],
                turns: [layoutTurn, turn],
                previewArtifacts: [],
                generation: 1
            ),
            snapshotWithArtifact: RuntimeSnapshot(
                timeline: [],
                turns: [layoutTurn, turn],
                previewArtifacts: [artifact],
                generation: 1
            ),
            conversationID: conversationID
        )
    }

    private func presentUIPreviewWorkbench(
        snapshot: RuntimeSnapshot,
        resolver: RecordingPreviewResolver,
        fixture: UIPreviewRenderFixture
    ) async throws -> (window: NSWindow, webView: WKWebView, store: WorkspaceStore) {
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = ConversationWebWorkbenchView(
            snapshot: snapshot,
            conversationID: fixture.conversationID,
            workspaceRoot: fixture.root,
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_200)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit UI Preview Viewer Acceptance"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window
        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_preview\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelectorAll('.turn-process-summary')
          .forEach((summary) => summary.dispatchEvent(
            new MouseEvent('click', { bubbles: true, cancelable: true })
          ));
        """)
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="call_ui_preview"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        return (window, webView, store)
    }

    func testViewerResolutionSendsRequestAndShowsViewer() async throws {
        let fixture = try makeUIPreviewRenderFixture()
        let viewerData = try Data(contentsOf: fixture.root.appendingPathComponent("viewer.html"))
        let fallbackData = try Data(contentsOf: fixture.root.appendingPathComponent("assets/fallback.png"))
        let resolver = RecordingPreviewResolver(viewerData: viewerData, assetData: fallbackData)
        let presented = try await presentUIPreviewWorkbench(
            snapshot: fixture.snapshotWithArtifact,
            resolver: resolver,
            fixture: fixture
        )
        try await waitForJavaScript(
            "document.querySelector('.ui-preview-activity') !== null",
            webView: presented.webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('iframe[data-ui-preview-frame=\"preview_p1f_render\"]')?.src.startsWith('agentkit-workbench://preview/') === true",
            webView: presented.webView,
            timeout: 12
        )
        let requests = resolver.viewerRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, fixture.conversationID)
        XCTAssertEqual(requests.first?.artifactID, "preview_p1f_render")
        XCTAssertEqual(requests.first?.revision, 1)

        let document = ConversationWebDocumentBuilder.build(
            snapshot: fixture.snapshotWithArtifact,
            conversationID: fixture.conversationID
        )
        let preview = try XCTUnwrap(
            document.turns.last?.blocks.first?.tools.first?.uiPreview
        )
        XCTAssertFalse(preview.artifactID.isEmpty)
        XCTAssertEqual(preview.revision, 1)
        XCTAssertEqual(preview.presentationState, "interactiveReady")
    }

    func testViewerFailureShowsErrorFallbackAndRetry() async throws {
        let fixture = try makeUIPreviewRenderFixture()
        let viewerData = try Data(contentsOf: fixture.root.appendingPathComponent("viewer.html"))
        let fallbackData = try Data(contentsOf: fixture.root.appendingPathComponent("assets/fallback.png"))
        let resolver = RecordingPreviewResolver(
            viewerData: viewerData,
            assetData: fallbackData,
            failViewer: true
        )
        let presented = try await presentUIPreviewWorkbench(
            snapshot: fixture.snapshotWithArtifact,
            resolver: resolver,
            fixture: fixture
        )
        try await waitForJavaScript(
            "document.querySelector('.ui-preview-viewer-placeholder')?.textContent.includes('Preview render failed') === true",
            webView: presented.webView,
            timeout: 12
        )
        let state = try await presented.webView.evaluateJavaScript("""
        (() => {
          const placeholder = document.querySelector('.ui-preview-viewer-placeholder');
          return {
            text: placeholder?.textContent ?? '',
            hasRetry: Boolean(placeholder?.querySelector('.ui-preview-retry')),
            fallbackWidth: document.querySelector('[data-ui-preview-node="fallback"] img')?.naturalWidth ?? 0
          };
        })()
        """) as? [String: Any]
        XCTAssertTrue((state?["text"] as? String)?.contains("Preview render failed (preview_test_failure)") == true)
        XCTAssertFalse((state?["text"] as? String)?.contains("Preparing interactive preview") == true)
        XCTAssertEqual(state?["hasRetry"] as? Bool, true)
        XCTAssertGreaterThan(state?["fallbackWidth"] as? Int ?? 0, 0)
        XCTAssertEqual(resolver.viewerRequests.count, 1)

        _ = try await presented.webView.evaluateJavaScript("""
        document.querySelector('.ui-preview-retry')?.click();
        """)
        try await waitForJavaScript(
            "document.querySelectorAll('.ui-preview-retry').length > 0 && document.querySelector('.ui-preview-viewer-placeholder')?.textContent.includes('Preview render failed') === true",
            webView: presented.webView,
            timeout: 12
        )
        XCTAssertEqual(resolver.viewerRequests.count, 2)
    }

    func testLatePreviewArtifactRefreshesViewer() async throws {
        let fixture = try makeUIPreviewRenderFixture()
        let viewerData = try Data(contentsOf: fixture.root.appendingPathComponent("viewer.html"))
        let fallbackData = try Data(contentsOf: fixture.root.appendingPathComponent("assets/fallback.png"))
        let resolver = RecordingPreviewResolver(viewerData: viewerData, assetData: fallbackData)
        let driver = PreviewSnapshotDriver(snapshot: fixture.snapshotWithoutArtifact)
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = PreviewSnapshotHostView(
            driver: driver,
            store: store,
            resolver: resolver,
            conversationID: fixture.conversationID,
            workspace: fixture.root
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_200)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit UI Preview Late Artifact"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window
        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelector('[data-tool-id=\"call_ui_preview\"]') !== null",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        document.querySelectorAll('.turn-process-summary')
          .forEach((summary) => summary.dispatchEvent(
            new MouseEvent('click', { bubbles: true, cancelable: true })
          ));
        """)
        _ = try await webView.evaluateJavaScript("""
        document.querySelector('[data-tool-id="call_ui_preview"] .tool-summary')
          ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
        """)
        XCTAssertTrue(resolver.viewerRequests.isEmpty)

        driver.snapshot = fixture.snapshotWithArtifact
        try await waitForJavaScript(
            "document.querySelector('.ui-preview-activity') !== null",
            webView: webView,
            timeout: 12
        )
        try await waitForJavaScript(
            "document.querySelector('iframe[data-ui-preview-frame=\"preview_p1f_render\"]')?.src.startsWith('agentkit-workbench://preview/') === true",
            webView: webView,
            timeout: 12
        )
        XCTAssertEqual(resolver.viewerRequests.count, 1)
    }

    private func renderLineage() -> JSONValue {
        .object([
            "schema": .string("ui_preview_lineage.v2"),
            "layout_artifact_id": .string("layout_abcdef0123456789"),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(
                "sha256:" + String(repeating: "c", count: 64)
            ),
            "source_asset_id": .string("asset_source_screen"),
            "source_asset_sha256": .string(String(repeating: "a", count: 64)),
            "evidence_sha256": .string(String(repeating: "b", count: 64)),
            "approval": .object([
                "state": .string("user_confirmed"),
                "evidence_ref": .string("approval-note-1"),
            ]),
            "target": .string("duo_folded"),
            "state": .string("home"),
            "target_matrix": .object([
                "id": .string("matrix_duo_primary"),
                "targets": .array(["duo_folded", "iphone_portrait"].map(JSONValue.string)),
            ]),
        ])
    }

    private func renderPreviewResult(
        fallbackPath: String,
        fallbackSHA256: String,
        lineage: JSONValue
    ) -> JSONValue {
        .object([
            "schema": .string("ui_preview_result.v1"),
            "artifact_key": "preview_key",
            "kind": "interactive_html",
            "title": "DreamLog Duo Home",
            "mode": "adaptation",
            "lineage": lineage,
            "fallback_asset": .object([
                "asset_id": .string("asset_render_fallback"),
                "relative_path": .string(fallbackPath),
                "mime_type": "image/png",
                "width": .integer(1_200),
                "height": .integer(800),
                "sha256": .string(fallbackSHA256),
            ]),
        ])
    }

    private func makeRenderArtifact(
        sessionID: String,
        callID: String,
        title: String,
        viewerData: Data,
        fallbackSHA256: String,
        lineage: JSONValue
    ) throws -> PreviewArtifact {
        let artifactID = "preview_p1f_render"
        let fallbackID = "asset_render_fallback"
        var object: [String: JSONValue] = [
            "schema_version": .string("preview.artifact.v1"),
            "artifact_id": .string(artifactID),
            "revision": .integer(1),
            "status": .string("ready"),
            "kind": .string("interactive_html"),
            "title": .string(title),
            "summary": .string("Adaptation preview for the reviewed layout revision."),
            "capability": .string("ui-adaptation"),
            "producer_id": .string("ui_preview"),
            "session_id": .string(sessionID),
            "turn_id": .string("turn-ui-preview"),
            "call_id": .string(callID),
            "created_at": .string("2026-11-14T12:00:00Z"),
            "updated_at": .string("2026-11-14T12:00:00Z"),
            "expires_at": .null,
            "presentation": .object([
                "placement": .string("conversation_inline"),
                "preferred_aspect_ratio": .number(1.78),
                "min_height": .integer(420),
                "initial_state": .string("expanded"),
            ]),
            "viewer": .object([
                "url": .string("/v1/conversations/\(sessionID)/previews/\(artifactID)/revisions/1/viewer"),
                "mime_type": .string("text/html; charset=utf-8"),
                "size_bytes": .integer(viewerData.count),
                "sha256": .string(PreviewRFC8785.sha256(data: viewerData)),
            ]),
            "assets": .array([
                .object([
                    "asset_id": .string(fallbackID),
                    "role": .string("fallback"),
                    "mime_type": .string("image/png"),
                    "size_bytes": .integer(1),
                    "sha256": .string("sha256:" + fallbackSHA256),
                    "content_url": .string("/v1/conversations/\(sessionID)/previews/\(artifactID)/revisions/1/assets/\(fallbackID)/content"),
                    "width": .integer(1_200),
                    "height": .integer(800),
                    "alt": .string("DreamLog Duo preview fallback"),
                ]),
            ]),
            "fallback": .object([
                "asset_id": .string(fallbackID),
                "text": .string("Interactive preview unavailable. Showing static evidence."),
            ]),
            "security": .object([
                "profile": .string("preview.security.v1"),
                "javascript": .string("isolated_only"),
                "network": .string("deny"),
                "navigation": .string("deny"),
                "persistent_data": .string("deny"),
                "actions": .string("none"),
            ]),
            "error": .null,
            "metadata": .object([
                "preview_mode": .string("adaptation"),
                "ui_preview_lineage": lineage,
            ]),
        ]
        object["revision_sha256"] = .string(try PreviewRFC8785.sha256(.object(object)))
        return try PreviewArtifact.decode(.object(object))
    }

    private func renderLayoutTool() -> ToolNodePayload {
        let artifactID = "layout_abcdef0123456789"
        let revisionSHA = "sha256:" + String(repeating: "c", count: 64)
        let sourceSHA = String(repeating: "a", count: 64)
        let evidenceSHA = String(repeating: "b", count: 64)
        let overlayID = "asset_layout_overlay"
        let layoutJSONID = "asset_layout_json"
        let evidenceID = "asset_evidence_json"
        var shape: [String: JSONValue] = [
            "asset_role": .string("layout_overlay"),
            "layout_artifact_id": .string(artifactID),
            "layout_revision": .integer(3),
            "layout_revision_sha256": .string(revisionSHA),
            "source_asset_id": .string("asset_source_screen"),
            "source_asset_sha256": .string(sourceSHA),
            "canvas": .object(["width": .integer(200), "height": .integer(400)]),
            "node_count": .integer(3),
        ]
        let overlay = AgentAssetRef(
            id: overlayID,
            kind: "image",
            displayName: "overlay.png",
            workspaceID: "ws_current",
            workspaceRelativePath: ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/overlay.png",
            mimeType: "image/png",
            sourceCallID: "call_ui_layout",
            metadata: shape
        )
        shape["asset_role"] = .string("layout_json")
        let layoutJSON = AgentAssetRef(
            id: layoutJSONID,
            kind: "file",
            displayName: "layout.json",
            workspaceID: "ws_current",
            workspaceRelativePath: ".codeagent/assets/ui-layout/\(artifactID)/revision-000003/layout.json",
            mimeType: "application/json",
            sourceCallID: "call_ui_layout",
            metadata: shape
        )
        let evidence = AgentAssetRef(
            id: evidenceID,
            kind: "file",
            displayName: "evidence.json",
            workspaceID: "ws_current",
            workspaceRelativePath: "ui-evidence/\(String(sourceSHA.prefix(16)))/evidence.json",
            mimeType: "application/json",
            sourceCallID: "call_ui_evidence",
            metadata: [
                "asset_role": .string("evidence"),
                "source_asset_id": .string("asset_source_screen"),
                "evidence_sha256": .string(evidenceSHA),
            ]
        )
        return ToolNodePayload(
            callID: "call_ui_layout",
            toolName: "ui_layout",
            args: nil,
            status: .completed,
            output: "layout",
            structuredOutput: .object([
                "schema": .string("ui_layout_result.v1"),
                "layout_artifact_id": .string(artifactID),
                "layout_revision": .integer(3),
                "layout_revision_sha256": .string(revisionSHA),
                "source_asset_id": .string("asset_source_screen"),
                "source_asset_sha256": .string(sourceSHA),
                "evidence_sha256": .string(evidenceSHA),
                "canvas": .object(["width": .integer(200), "height": .integer(400)]),
                "node_count": .integer(3),
                "assumption_count": .integer(1),
                "targets": .array(["duo_folded", "iphone_portrait"].map(JSONValue.string)),
                "created": .bool(true),
                "overlay_asset": .object([
                    "asset_id": .string(overlayID),
                    "asset_role": .string("layout_overlay"),
                    "kind": .string("image"),
                    "relative_path": .string(overlay.workspaceRelativePath!),
                    "filename": .string("overlay.png"),
                    "mime_type": .string("image/png"),
                    "width": .integer(200),
                    "height": .integer(400),
                    "sha256": .string(String(repeating: "1", count: 64)),
                ]),
                "layout_json_asset": .object([
                    "asset_id": .string(layoutJSONID),
                    "asset_role": .string("layout_json"),
                    "kind": .string("file"),
                    "relative_path": .string(layoutJSON.workspaceRelativePath!),
                    "filename": .string("layout.json"),
                    "mime_type": .string("application/json"),
                    "sha256": .string(String(repeating: "2", count: 64)),
                ]),
            ]),
            assets: [overlay, layoutJSON, evidence]
        )
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
