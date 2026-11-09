import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class ConversationWebPreviewSecurityTests: XCTestCase {
    func testFixtureViewerPassesTrustedViewerPolicy() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        XCTAssertLessThan(data.count, PreviewArtifact.maximumViewerBytes)
        let html = try ConversationWebPreviewSecurity.validateViewerDocument(data)
        XCTAssertTrue(html.contains("Content-Security-Policy"))
    }

    func testViewerWithoutCSPFailsClosed() {
        let data = Data("<html><body><script>fetch('https://example.com')</script></body></html>".utf8)
        XCTAssertThrowsError(try ConversationWebPreviewSecurity.validateViewerDocument(data)) { error in
            XCTAssertEqual(
                (error as? ConversationWebPreviewSecurityError)?.code,
                "preview_security_violation"
            )
        }
    }

    func testViewerWithExternalResourceFailsClosed() {
        let data = Data("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <img src="https://example.com/pixel.png">
        """.utf8)
        XCTAssertThrowsError(try ConversationWebPreviewSecurity.validateViewerDocument(data)) { error in
            XCTAssertEqual(
                (error as? ConversationWebPreviewSecurityError)?.code,
                "preview_security_violation"
            )
        }
    }

    func testNavigationPolicyAllowsOnlyShellAndOneInitialPreviewFrame() throws {
        let shell = ConversationWebSchemeHandler.indexURL
        let preview = try XCTUnwrap(URL(string: "agentkit-workbench://preview/\(UUID().uuidString.lowercased())"))
        let pending: Set<URL> = [preview]

        XCTAssertEqual(
            ConversationWebPreviewSecurity.navigationDecision(
                url: shell,
                isMainFrame: true,
                isNewWindow: false,
                shouldPerformDownload: false,
                isInitialShellNavigation: true,
                shellURL: shell,
                pendingPreviewInitialURLs: pending
            ),
            .allow
        )
        XCTAssertEqual(
            ConversationWebPreviewSecurity.navigationDecision(
                url: preview,
                isMainFrame: false,
                isNewWindow: false,
                shouldPerformDownload: false,
                isInitialShellNavigation: false,
                shellURL: shell,
                pendingPreviewInitialURLs: pending
            ),
            .allow
        )
        XCTAssertEqual(
            ConversationWebPreviewSecurity.navigationDecision(
                url: preview,
                isMainFrame: false,
                isNewWindow: false,
                shouldPerformDownload: false,
                isInitialShellNavigation: false,
                shellURL: shell,
                pendingPreviewInitialURLs: []
            ),
            .cancel
        )
    }

    func testNavigationPolicyRejectsRemoteTopNavigationPopupsAndDownloads() throws {
        let shell = ConversationWebSchemeHandler.indexURL
        let remote = try XCTUnwrap(URL(string: "https://example.com"))
        for (isMainFrame, isNewWindow, shouldDownload) in [
            (true, false, false),
            (false, false, false),
            (false, true, false),
            (false, false, true),
        ] {
            XCTAssertEqual(
                ConversationWebPreviewSecurity.navigationDecision(
                    url: remote,
                    isMainFrame: isMainFrame,
                    isNewWindow: isNewWindow,
                    shouldPerformDownload: shouldDownload,
                    isInitialShellNavigation: false,
                    shellURL: shell,
                    pendingPreviewInitialURLs: [remote]
                ),
                .cancel
            )
        }
        XCTAssertEqual(
            ConversationWebPreviewSecurity.navigationDecision(
                url: shell,
                isMainFrame: true,
                isNewWindow: false,
                shouldPerformDownload: false,
                isInitialShellNavigation: false,
                shellURL: shell,
                pendingPreviewInitialURLs: []
            ),
            .cancel
        )
    }

    func testIframeSandboxOmitsFormsPopupsTopNavigationDownloadsAndSameOrigin() {
        XCTAssertEqual(ConversationWebPreviewSecurity.iframeSandbox, "allow-scripts")
        for forbidden in [
            "allow-same-origin", "allow-forms", "allow-popups",
            "allow-top-navigation", "allow-downloads", "allow-modals",
        ] {
            XCTAssertFalse(ConversationWebPreviewSecurity.iframeSandbox.contains(forbidden))
        }
        XCTAssertEqual(ConversationWebPreviewSecurity.parentFrameSource, "agentkit-workbench:")
    }

    func testScriptMessagePolicyRejectsEveryNonMainFrame() {
        XCTAssertTrue(ConversationWebPreviewSecurity.acceptsScriptMessage(isMainFrame: true))
        XCTAssertFalse(ConversationWebPreviewSecurity.acceptsScriptMessage(isMainFrame: false))
    }

    func testResponsePolicyRejectsDownloadsAndUnrenderableMIME() {
        XCTAssertEqual(
            ConversationWebPreviewSecurity.responseDecision(canShowMIMEType: true, isAttachment: false),
            .allow
        )
        XCTAssertEqual(
            ConversationWebPreviewSecurity.responseDecision(canShowMIMEType: true, isAttachment: true),
            .cancel
        )
        XCTAssertEqual(
            ConversationWebPreviewSecurity.responseDecision(canShowMIMEType: false, isAttachment: false),
            .cancel
        )
    }

    func testNetworkRulesBlockRemoteSchemesAndAllPopups() throws {
        let data = try XCTUnwrap(ConversationWebPreviewSecurity.networkBlockRulesJSON.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rules.count, 5)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("^https?://"))
        XCTAssertTrue(encoded.contains("^wss?://"))
        XCTAssertTrue(encoded.contains("^file://"))
        XCTAssertTrue(encoded.contains("\"popup\""))
    }

    /// The workbench-level rule list must not break existing gateway-backed
    /// HTTPS user assets. Preview-viewer CSP, not this global rule list, is the
    /// authority that rejects remote images inside isolated preview content.
    func testNetworkRulesPreserveWorkbenchRemoteImageAssets() throws {
        let data = try XCTUnwrap(ConversationWebPreviewSecurity.networkBlockRulesJSON.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let remoteRule = try XCTUnwrap(rules.first {
            ($0["trigger"] as? [String: Any])?["url-filter"] as? String == "^https?://"
        })
        let trigger = try XCTUnwrap(remoteRule["trigger"] as? [String: Any])
        let resourceTypes = try XCTUnwrap(trigger["resource-type"] as? [String])
        XCTAssertFalse(resourceTypes.contains("image"))
        XCTAssertTrue(resourceTypes.contains("script"))
        XCTAssertTrue(resourceTypes.contains("raw"))
    }

    func testSchemeHandlerRegistersOpaquePreviewAndFallbackTokens() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let artifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let viewer = PreviewViewerResource(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            data: viewerData,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: viewerData.count,
            sha256: PreviewRFC8785.sha256(data: viewerData)
        )
        let handler = ConversationWebSchemeHandler()
        let viewerURL = try XCTUnwrap(handler.registerPreviewViewer(viewer))
        XCTAssertTrue(ConversationWebSchemeHandler.isPreviewViewerURL(viewerURL))
        XCTAssertTrue(viewerURL.absoluteString.hasPrefix("agentkit-workbench://preview/"))

        let fallbackData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let fallbackURL = try XCTUnwrap(handler.registerLocalAsset(
            data: fallbackData,
            mimeType: "image/png"
        ))
        XCTAssertTrue(ConversationWebSchemeHandler.isLocalAssetURL(fallbackURL))
        XCTAssertNotEqual(viewerURL, fallbackURL)
        handler.removeAllPreviewViewers()
        handler.removeAllLocalAssets()
    }
}
