//
//  TimelineDocumentInspectorView.swift
//  AgentKit
//
//  Native Inspector host for semantic Timeline extension documents.
//

import SwiftUI

struct TimelineDocumentInspectorView: View {
    let document: TimelineWebDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(document.title)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            switch document.format {
            case .plainText, .markdown:
                ScrollView {
                    Text(document.body)
                        .font(document.format == .plainText ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }

            case .html:
                #if os(macOS)
                SecureTimelineHTMLView(html: document.body)
                #else
                ScrollView {
                    Text(document.body)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                #endif
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.title)
    }
}

#if os(macOS)
import WebKit

private struct SecureTimelineHTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.prepareForDocumentLoad()
        webView.loadHTMLString(Self.sandboxedDocument(body: html), baseURL: nil)
    }

    private static func sandboxedDocument(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; font: 14px -apple-system, sans-serif; }
          body { margin: 16px; line-height: 1.5; overflow-wrap: anywhere; }
          pre { overflow-x: auto; white-space: pre; }
          table { border-collapse: collapse; }
          th, td { border: 1px solid color-mix(in srgb, currentColor 20%, transparent); padding: 5px 8px; }
        </style></head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var allowsInitialAboutBlank = false

        func prepareForDocumentLoad() {
            allowsInitialAboutBlank = true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let isInitialDocument = allowsInitialAboutBlank
                && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.scheme == "about"
            if isInitialDocument { allowsInitialAboutBlank = false }
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }
}
#endif
