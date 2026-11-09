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
