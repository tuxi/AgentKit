//
//  ConversationWebSchemeHandler.swift
//  AgentKit
//
//  Serves the immutable bundled renderer from a same-origin private scheme.
//

import Foundation
import WebKit

final class ConversationWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "agentkit-workbench"
    static let host = "bundle"
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!

    private let resourceRoot: URL?
    private static let allowedFiles: Set<String> = [
        "index.html",
        "assets/workbench.js",
        "assets/workbench.css",
    ]

    override init() {
        resourceRoot = Bundle.module.url(
            forResource: "ConversationWeb",
            withExtension: nil
        )
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let relativePath = Self.allowedResourcePath(for: requestURL),
              let resourceRoot else {
            fail(urlSchemeTask, code: .fileNoSuchFile)
            return
        }

        let resourceURL = resourceRoot.appendingPathComponent(relativePath)
        do {
            let data = try Data(contentsOf: resourceURL, options: .mappedIfSafe)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: resourceURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    static func allowedResourcePath(for url: URL) -> String? {
        guard url.scheme == scheme,
              url.host == host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil else { return nil }
        guard let encodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath else { return nil }
        let lowercaseEncodedPath = encodedPath.lowercased()
        guard !lowercaseEncodedPath.contains("%2e"),
              !lowercaseEncodedPath.contains("%2f"),
              !lowercaseEncodedPath.contains("%5c") else { return nil }
        let relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return allowedFiles.contains(relativePath) ? relativePath : nil
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Reads are synchronous and bundle-local, so there is no outstanding
        // operation to cancel by the time WebKit can issue stop.
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }

    private func fail(_ task: any WKURLSchemeTask, code: CocoaError.Code) {
        task.didFailWithError(CocoaError(code))
    }
}
