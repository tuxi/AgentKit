//
//  ConversationStyledExportRenderer.swift
//  AgentKit
//
//  Renders the same semantic Web document and CSS used by the conversation
//  workbench, then captures that laid-out document as PNG or PDF.
//

import Foundation
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ConversationStyledExportRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let messageHandlerName = "agentkitWorkbench"

    enum Output {
        case image
        case pdf
    }

    private let document: ConversationWebDocument
    private let title: String
    private let output: Output
    private let schemeHandler = ConversationWebSchemeHandler()
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didSubmitDocument = false
    private var didFinish = false

    init(document: ConversationWebDocument, title: String, output: Output) {
        self.document = document
        self.title = title
        self.output = output
    }

    static func render(
        document: ConversationWebDocument,
        title: String,
        output: Output
    ) async throws -> Data {
        let renderer = ConversationStyledExportRenderer(
            document: document,
            title: title,
            output: output
        )
        return try await renderer.start()
    }

    private func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.setURLSchemeHandler(
                schemeHandler,
                forURLScheme: ConversationWebSchemeHandler.scheme
            )
            configuration.userContentController.add(
                self,
                name: Self.messageHandlerName
            )

            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 824, height: 600),
                configuration: configuration
            )
            webView.navigationDelegate = self
            #if os(macOS)
            webView.underPageBackgroundColor = .white
            #else
            webView.isOpaque = true
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
            #endif
            self.webView = webView
            webView.load(URLRequest(url: ConversationWebSchemeHandler.indexURL))
            self.timeoutTask = Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                finish(.failure(RenderError.timedOut))
            }
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            submitDocument()
        case "ack":
            guard (body["revision"] as? NSNumber)?.uint64Value == document.revision else { return }
            prepareAndCapture()
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(error))
    }

    private func submitDocument() {
        guard !didSubmitDocument, let webView else { return }
        didSubmitDocument = true
        do {
            let update = ConversationWebDocumentDiffer.reset(document)
            let payload = try JSONEncoder().encode(update).base64EncodedString()
            webView.evaluateJavaScript(
                "window.AgentKitWorkbench?.applyUpdateBase64('\(payload)')"
            ) { [weak self] _, error in
                if let error { self?.finish(.failure(error)) }
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func prepareAndCapture() {
        guard let webView else { return }
        let encodedTitle = Data(title.utf8).base64EncodedString()
        let script = """
        (() => {
          let style = document.getElementById('agentkit-export-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'agentkit-export-style';
            style.textContent = `
              :root { color-scheme: light !important; background: #fff !important; }
              html, body, #root { min-height: 0 !important; background: #fff !important; }
              body { width: 824px !important; overflow: hidden !important; }
              .conversation-shell {
                width: 824px !important; max-width: none !important; min-height: 0 !important;
                margin: 0 !important; padding: 36px 32px 42px !important;
                background: #fff !important;
              }
              .turn-actions, .jump-to-latest { display: none !important; }
              .share-export-title {
                margin: 0 0 30px !important; color: #202020 !important;
                font: 650 28px/1.22 -apple-system, BlinkMacSystemFont, sans-serif !important;
                letter-spacing: -0.02em; overflow-wrap: anywhere;
              }
              * { animation: none !important; transition: none !important; }
            `;
            document.head.appendChild(style);
          }
          const shell = document.querySelector('.conversation-shell');
          if (!shell) throw new Error('Missing conversation shell');
          let heading = shell.querySelector('.share-export-title');
          if (!heading) {
            heading = document.createElement('h1');
            heading.className = 'share-export-title';
            shell.prepend(heading);
          }
          const bytes = Uint8Array.from(atob('\(encodedTitle)'), c => c.charCodeAt(0));
          heading.textContent = new TextDecoder().decode(bytes);
          document.documentElement.classList.add('workbench-ready');
          const rect = shell.getBoundingClientRect();
          return { width: Math.ceil(rect.width), height: Math.ceil(shell.scrollHeight) };
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let size = result as? [String: Any],
                  let width = (size["width"] as? NSNumber)?.doubleValue,
                  let height = (size["height"] as? NSNumber)?.doubleValue else {
                self.finish(.failure(RenderError.invalidLayout))
                return
            }
            let captureWidth = CGFloat(max(1, width))
            let captureHeight = CGFloat(max(1, height))
            self.webView?.frame = CGRect(
                x: 0,
                y: 0,
                width: captureWidth,
                height: captureHeight
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                self?.capture(width: captureWidth, height: captureHeight)
            }
        }
    }

    private func capture(width: CGFloat, height: CGFloat) {
        guard let webView else { return }
        switch output {
        case .image:
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: min(height, 12_000))
            webView.takeSnapshot(with: configuration) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                guard let image, let data = Self.pngData(from: image) else {
                    self.finish(.failure(RenderError.captureFailed))
                    return
                }
                self.finish(.success(data))
            }

        case .pdf:
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            webView.createPDF(configuration: configuration) { [weak self] result in
                guard let self else { return }
                self.finish(result)
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName
        )
        webView?.navigationDelegate = nil
        webView = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    #if os(macOS)
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
    #else
    private static func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }
    #endif

    private enum RenderError: Error {
        case invalidLayout
        case captureFailed
        case timedOut
    }
}
