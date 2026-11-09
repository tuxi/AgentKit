#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import AgentKit

@MainActor
private final class WebViewLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ webView: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class ScriptMessageProbe: NSObject, WKScriptMessageHandler {
    let mainFrameMessage: XCTestExpectation
    private(set) var bodies: [String] = []

    init(mainFrameMessage: XCTestExpectation) {
        self.mainFrameMessage = mainFrameMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        bodies.append(body)
        if body == "main" {
            mainFrameMessage.fulfill()
        }
    }
}

@MainActor
final class PreviewViewerRenderTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        try await super.tearDown()
    }

    func testSubTwoMiBViewerRendersAndRunsIsolatedInlineScript() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let artifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        XCTAssertLessThan(viewerData.count, PreviewArtifact.maximumViewerBytes)

        let (webView, handler) = try makeWebView()
        let resource = PreviewViewerResource(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            data: viewerData,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: viewerData.count,
            sha256: PreviewRFC8785.sha256(data: viewerData)
        )
        let viewerURL = try XCTUnwrap(handler.registerPreviewViewer(resource))
        let waiter = WebViewLoadWaiter()
        webView.navigationDelegate = waiter
        try await waiter.load(webView, url: viewerURL)

        let initial = try await webView.evaluateJavaScript(
            "document.getElementById('pose').textContent"
        ) as? String
        XCTAssertEqual(initial, "Outer screen")

        let changed = try await webView.evaluateJavaScript("""
        document.getElementById('pose').click();
        document.getElementById('pose').textContent;
        """) as? String
        XCTAssertEqual(changed, "Inner portrait")
    }

    func testCSPBlocksRemoteFetchAndImageWithContentRulesInstalled() async throws {
        let viewerHTML = """
        <!doctype html>
        <html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        </head><body><script>
        document.addEventListener('securitypolicyviolation', (event) => {
          const violations = new Set((document.body.dataset.violations || '').split(',').filter(Boolean));
          violations.add(event.violatedDirective);
          document.body.dataset.violations = [...violations].sort().join(',');
        });
        fetch('https://example.com/data')
          .then(() => { document.body.dataset.network = 'allowed'; })
          .catch(() => { document.body.dataset.network = 'blocked'; });
        const image = document.createElement('img');
        image.onload = () => { document.body.dataset.image = 'allowed'; };
        image.onerror = () => { document.body.dataset.image = 'blocked'; };
        image.src = 'https://example.com/pixel.png';
        </script></body></html>
        """
        let viewerData = Data(viewerHTML.utf8)
        let resource = PreviewViewerResource(
            sessionID: "session",
            artifactID: "artifact",
            revision: 1,
            data: viewerData,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: viewerData.count,
            sha256: PreviewRFC8785.sha256(data: viewerData)
        )
        let (webView, handler) = try makeWebView()
        try await installNetworkRules(on: webView)
        let viewerURL = try XCTUnwrap(handler.registerPreviewViewer(resource))
        let waiter = WebViewLoadWaiter()
        webView.navigationDelegate = waiter
        try await waiter.load(webView, url: viewerURL)

        let networkResult = try await waitForJavaScript(
            "document.body.dataset.network || ''",
            webView: webView,
            timeout: 2
        ) as? String
        XCTAssertEqual(networkResult, "blocked")
        let imageResult = try await waitForJavaScript(
            "document.body.dataset.image || ''",
            webView: webView,
            timeout: 2
        ) as? String
        XCTAssertEqual(imageResult, "blocked")
        let violations = try await waitForJavaScript(
            "(document.body.dataset.violations || '').includes('connect-src') && (document.body.dataset.violations || '').includes('img-src') ? document.body.dataset.violations : ''",
            webView: webView,
            timeout: 2
        ) as? String
        XCTAssertTrue(violations?.contains("connect-src") == true)
        XCTAssertTrue(violations?.contains("img-src") == true)
    }

    func testWeakScriptMessageHandlerRejectsEveryNonMainFrameMessage() async throws {
        let mainFrameMessage = expectation(description: "main-frame message delivered")
        let probe = ScriptMessageProbe(mainFrameMessage: mainFrameMessage)
        let proxy = WeakScriptMessageHandler(delegate: probe)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(proxy, name: "previewTest")
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        windows.append(window)

        webView.loadHTMLString("""
        <!doctype html>
        <body>
          <script>
            window.webkit.messageHandlers.previewTest.postMessage('main');
            const frame = document.createElement('iframe');
            frame.srcdoc = "<script>window.webkit.messageHandlers.previewTest.postMessage('iframe')</scr" + "ipt>";
            document.body.appendChild(frame);
          </script>
        </body>
        """, baseURL: nil)
        await fulfillment(of: [mainFrameMessage], timeout: 3)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(probe.bodies, ["main"])
        configuration.userContentController.removeScriptMessageHandler(forName: "previewTest")
    }

    private func makeWebView() throws -> (WKWebView, ConversationWebSchemeHandler) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let handler = ConversationWebSchemeHandler()
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: ConversationWebSchemeHandler.scheme
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 720),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return (webView, handler)
    }

    private func installNetworkRules(on webView: WKWebView) async throws {
        let list = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PreviewViewerRenderTest-\(UUID().uuidString)",
                encodedContentRuleList: ConversationWebPreviewSecurity.networkBlockRulesJSON
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                }
            }
        }
        webView.configuration.userContentController.add(list)
    }

    private func waitForJavaScript(
        _ script: String,
        webView: WKWebView,
        timeout: TimeInterval
    ) async throws -> Any? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = try await webView.evaluateJavaScript(script)
            if let string = value as? String, !string.isEmpty {
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await webView.evaluateJavaScript(script)
    }
}
#endif
