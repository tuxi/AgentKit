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
        XCTAssertEqual(collapsed?["title"] as? String, "Viewed image screen.png")
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
            relation: crop?.querySelector('.image-view-crop-heading')?.textContent ?? '',
            hasDimensions: text.includes('Effective size: 640 × 400 px') && text.includes('Effective size: 320 × 160 px'),
            hasEffectiveDetail: text.includes('Effective detail: original'),
            hasOriginal: text.includes('View original'),
            hasViewSource: text.includes('View source'),
            hasViewCrop: text.includes('View crop'),
            sourceRole: source?.querySelector('.image-view-role')?.textContent ?? ''
          };
        })()
        """) as? [String: Any]
        XCTAssertEqual(expanded?["sourceFirst"] as? String, "source")
        XCTAssertEqual(expanded?["assetOrder"] as? String, "\(sourceID),\(cropID)")
        XCTAssertEqual(expanded?["sourceID"] as? String, sourceID)
        XCTAssertGreaterThan(expanded?["sourceWidth"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(expanded?["cropWidth"] as? Int ?? 0, 0)
        XCTAssertEqual(expanded?["cropParent"] as? String, sourceID)
        XCTAssertTrue((expanded?["relation"] as? String)?.contains("Crop of") == true)
        XCTAssertEqual(expanded?["hasDimensions"] as? Bool, true)
        XCTAssertEqual(expanded?["hasEffectiveDetail"] as? Bool, true)
        XCTAssertEqual(expanded?["hasOriginal"] as? Bool, true)
        XCTAssertEqual(expanded?["hasViewSource"] as? Bool, true)
        XCTAssertEqual(expanded?["hasViewCrop"] as? Bool, true)
        XCTAssertEqual(expanded?["sourceRole"] as? String, "Source")

        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("image-view-source-crop.png")
        try await saveSnapshot(of: webView, to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
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
