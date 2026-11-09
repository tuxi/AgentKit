#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import AgentKit

/// Opt-in R4b harness. It never uses the R3 fixture server: readiness must point
/// at a real, continuously running Runtime session and event stream.
@MainActor
final class PreviewR4bLiveHarnessTests: XCTestCase {
    private struct Readiness: Decodable {
        let baseURL: String
        let bearerToken: String
        let sessionID: String
        let turnPrompt: String

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case bearerToken = "bearer_token"
            case sessionID = "session_id"
            case turnPrompt = "turn_prompt"
        }
    }

    private struct LivePreviewCapture: Sendable {
        let events: [AgentEvent]
        let preview: PreviewArtifactEvent
    }

    private enum HarnessError: Error, LocalizedError {
        case invalidReadiness(String)
        case streamEnded
        case timeout(TimeInterval)
        case missingArtifact(String)

        var errorDescription: String? {
            switch self {
            case .invalidReadiness(let message): return message
            case .streamEnded: return "Runtime event stream ended before a live preview_artifact event."
            case .timeout(let seconds): return "Timed out after \(seconds)s waiting for a live preview_artifact event."
            case .missingArtifact(let message): return message
            }
        }
    }

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    func testLivePreviewSessionViewerAssetReplayAndWorkbench() async throws {
        let readiness = try loadReadiness()
        let client = try await makeClient(readiness)
        let timeout = liveTimeout()

        let capabilities = try await client.runtimeCapabilities()
        for capability in PreviewCapability.allCases {
            XCTAssertEqual(capabilities.capabilities[capability.rawValue], true, capability.rawValue)
        }

        // Pre-trigger replay is captured before the stream is opened. The R4b
        // backend contract guarantees that no target preview exists yet.
        let initialBatch = try await client.getEventBatch(
            conversationID: readiness.sessionID,
            since: 0
        )
        let preTriggerNextSince = initialBatch.nextSince
        let initialPreviewEvents = previewEvents(in: initialBatch)
        XCTAssertTrue(
            initialPreviewEvents.isEmpty,
            "R4b pre-trigger replay must not contain a preview artifact."
        )
        let engine = RuntimeEngine(sessionID: readiness.sessionID)
        await engine.importHistory(initialBatch.events, wallClock: initialBatch.turnWallClock)

        let channel = client.makeSessionChannel(conversationID: readiness.sessionID)
        let stream = try await channel.connect(since: preTriggerNextSince)
        let liveCapture: LivePreviewCapture
        do {
            try await waitForConnected(channel, timeout: min(timeout, 15))
            await channel.send(input: AgentInput.text(
                readiness.turnPrompt,
                requestID: "r4b-trigger-1"
            ))
            liveCapture = try await waitForLivePreview(
                in: stream,
                sessionID: readiness.sessionID,
                timeout: timeout
            )
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
        let livePreview = liveCapture.preview

        guard livePreview.isValid, let liveArtifact = livePreview.artifact else {
            throw HarnessError.missingArtifact(
                "Live preview_artifact event was invalid: \(livePreview.error?.message ?? "unknown error")."
            )
        }
        XCTAssertEqual(liveArtifact.sessionID, readiness.sessionID)
        XCTAssertGreaterThan(livePreview.sequence ?? 0, preTriggerNextSince)
        XCTAssertFalse(initialPreviewEvents.contains {
            $0.artifact?.artifactID == liveArtifact.artifactID
                && $0.artifact?.revision == liveArtifact.revision
        })

        for event in liveCapture.events {
            await engine.ingest(event)
        }
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.previewArtifacts.contains {
            $0.artifactID == liveArtifact.artifactID && $0.revision == liveArtifact.revision
        })
        XCTAssertTrue(snapshot.turns.contains { $0.runtimeTurnID == liveArtifact.turnID })

        let replayBatch = try await client.getEventBatch(
            conversationID: readiness.sessionID,
            since: 0
        )
        let replayPreviews = previewEvents(in: replayBatch)
        let replayedLive = replayPreviews.first {
            if let eventID = livePreview.eventID, eventID == $0.eventID {
                return true
            }
            return $0.sequence == livePreview.sequence
                && $0.artifact?.artifactID == liveArtifact.artifactID
                && $0.artifact?.revision == liveArtifact.revision
        }
        XCTAssertNotNil(replayedLive)
        XCTAssertEqual(replayedLive?.artifact?.artifactID, liveArtifact.artifactID)
        XCTAssertEqual(replayedLive?.artifact?.revision, liveArtifact.revision)
        XCTAssertEqual(replayedLive?.artifact?.revisionSHA256, liveArtifact.revisionSHA256)
        XCTAssertEqual(replayedLive?.sequence, livePreview.sequence)
        XCTAssertGreaterThanOrEqual(
            replayBatch.nextSince,
            livePreview.sequence ?? 0
        )
        var replayStore = PreviewArtifactStore()
        for preview in replayPreviews {
            _ = replayStore.merge(preview)
        }
        XCTAssertTrue(replayStore.artifacts.contains {
            $0.artifactID == liveArtifact.artifactID && $0.revision == liveArtifact.revision
        })

        let interactive = try XCTUnwrap(
            snapshot.previewArtifacts.first {
                $0.kind == .interactiveHTML
                    && $0.status == .ready
                    && $0.viewer != nil
                    && $0.fallback?.assetID != nil
            },
            "R4b session did not expose a ready interactive preview with fallback."
        )
        let fallbackAssetID = try XCTUnwrap(interactive.fallback?.assetID)

        let viewerResolver = try XCTUnwrap(client.previewViewerResolver())
        let viewer = try await viewerResolver.resolve(PreviewViewerRequest(
            sessionID: interactive.sessionID,
            artifactID: interactive.artifactID,
            revision: interactive.revision
        ))
        try viewer.validate(against: interactive)
        XCTAssertEqual(viewer.data.count, interactive.viewer?.sizeBytes)

        let assetResolver = try XCTUnwrap(client.previewAssetResolver())
        let fallbackAsset = try await assetResolver.resolveContent(PreviewAssetRequest(
            sessionID: interactive.sessionID,
            artifactID: interactive.artifactID,
            revision: interactive.revision,
            assetID: fallbackAssetID
        ))
        try fallbackAsset.validate(against: interactive)
        XCTAssertNotNil(NSBitmapImageRep(data: fallbackAsset.data))

        let hostingView = try makeHostingView(
            client: client,
            snapshot: snapshot,
            conversationID: readiness.sessionID
        )
        let webView = try await waitForWebView(in: hostingView)
        try await waitForJavaScript(
            "document.querySelectorAll('.preview-block').length > 0",
            webView: webView,
            timeout: 12
        )
        _ = try await webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('details.preview-disclosure')).forEach((details) => {
          if (!details.open) {
            details.querySelector('summary')?.click();
          }
        });
        """)
        try await waitForJavaScript(
            "Array.from(document.querySelectorAll('details.preview-disclosure')).every((details) => details.open)",
            webView: webView,
            timeout: 5
        )
        try await waitForJavaScript(
            "document.querySelector('iframe[data-preview-frame=\\\"\(interactive.artifactID)\\\"]')?.dataset.loaded === 'true'",
            webView: webView,
            timeout: 12
        )
        let sandbox = try await webView.evaluateJavaScript(
            "document.querySelector('iframe[data-preview-frame=\\\"\(interactive.artifactID)\\\"]')?.getAttribute('sandbox')"
        ) as? String
        XCTAssertEqual(sandbox, "allow-scripts")
        let screenshot = try screenshotDirectoryURL()
            .appendingPathComponent("r4b-live-workbench.png")
        try await Task.sleep(for: .milliseconds(300))
        try await saveSnapshot(of: webView, to: screenshot)

        print(
            "R4B_EVIDENCE session=\(readiness.sessionID) turn=\(liveArtifact.turnID) "
                + "artifact=\(liveArtifact.artifactID) revision=\(liveArtifact.revision) "
                + "seq=\(livePreview.sequence ?? 0) viewer_sha256=\(viewer.sha256) "
                + "asset_sha256=\(fallbackAsset.sha256) screenshot=\(screenshot.path)"
        )
    }

    private func loadReadiness() throws -> Readiness {
        guard let raw = ProcessInfo.processInfo.environment["PREVIEW_R4_READY"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("PREVIEW_R4_READY is not configured")
        }
        let data: Data
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            data = Data(raw.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: raw))
        }
        let readiness = try JSONDecoder().decode(Readiness.self, from: data)
        guard !readiness.baseURL.isEmpty,
              !readiness.bearerToken.isEmpty,
              !readiness.sessionID.isEmpty,
              !readiness.turnPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessError.invalidReadiness("R4b readiness fields must be non-empty.")
        }
        return readiness
    }

    private func makeClient(_ readiness: Readiness) async throws -> DefaultAgentClient {
        guard let origin = URL(string: readiness.baseURL) else {
            throw HarnessError.invalidReadiness("PREVIEW_R4_READY base_url is malformed.")
        }
        let environment = try RuntimeEnvironment(origin: origin)
        let store = MemoryCredentialStore()
        let target: CredentialTarget = .runtimeAccess("preview-r4b")
        try await store.set(
            Credential(kind: .bearer, secret: readiness.bearerToken),
            for: target
        )
        return DefaultAgentClient(
            environment: environment,
            credentialStore: store,
            credentialTarget: target
        )
    }

    private func liveTimeout() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["PREVIEW_R4_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw),
              value > 0 else { return 60 }
        return value
    }

    private func waitForConnected(
        _ channel: any RuntimeSessionChannel,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if channel.isConnected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.timeout(timeout)
    }

    private func waitForLivePreview(
        in stream: AsyncStream<AgentEvent>,
        sessionID: String,
        timeout: TimeInterval
    ) async throws -> LivePreviewCapture {
        try await withThrowingTaskGroup(of: LivePreviewCapture.self) { group in
            group.addTask {
                var events: [AgentEvent] = []
                for await event in stream {
                    events.append(event)
                    guard case .previewArtifact(let preview) = event,
                          preview.isValid,
                          preview.artifact?.sessionID == sessionID else { continue }
                    return LivePreviewCapture(events: events, preview: preview)
                }
                throw HarnessError.streamEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw HarnessError.timeout(timeout)
            }
            defer { group.cancelAll() }
            guard let capture = try await group.next() else {
                throw HarnessError.streamEnded
            }
            return capture
        }
    }

    private func previewEvents(in batch: AgentEventBatch) -> [PreviewArtifactEvent] {
        batch.events.compactMap { event in
            guard case .previewArtifact(let preview) = event else { return nil }
            return preview
        }
    }

    private func makeHostingView(
        client: DefaultAgentClient,
        snapshot: RuntimeSnapshot,
        conversationID: String
    ) throws -> NSHostingView<AnyView> {
        let store = WorkspaceStore(usesEmbeddedRuntime: false)
        let content = AnyView(
            ConversationWebWorkbenchView(
                snapshot: snapshot,
                conversationID: conversationID,
                workspaceRoot: nil,
                previewViewerResolver: client.previewViewerResolver(),
                previewAssetResolver: client.previewAssetResolver(),
                extensionContributions: [:],
                timelineExtensions: [],
                isVisible: true,
                bottomInset: 0,
                onFatalFailure: { XCTFail("ConversationWorkbench renderer failed") }
            )
            .environment(store)
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "AgentKit R4b Live Runtime Preview"
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        self.window = window
        return hostingView
    }

    private func waitForWebView(in root: NSView) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let webView = findWebView(in: root) { return webView }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HarnessError.missingArtifact("ConversationWorkbench did not create a WKWebView.")
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
        throw HarnessError.timeout(timeout)
    }

    private func screenshotDirectoryURL() throws -> URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["PREVIEW_R4B_SCREENSHOT_DIR"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("agentkit-r4b-preview", isDirectory: true)
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
            throw HarnessError.missingArtifact("Workbench snapshot could not be encoded.")
        }
        try png.write(to: url, options: .atomic)
    }
}
#endif
