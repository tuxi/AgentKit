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
    static let localAssetHost = "local-asset"
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!

    private struct LocalAssetResource {
        let sourceURL: URL
        let mimeType: String
    }

    private let resourceRoot: URL?
    private let localAssetLock = NSLock()
    private var localAssetResources: [String: LocalAssetResource] = [:]
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
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: .fileNoSuchFile)
            return
        }

        if let localAsset = localAssetResource(for: requestURL) {
            serve(
                localAsset.sourceURL,
                as: localAsset.mimeType,
                requestURL: requestURL,
                task: urlSchemeTask
            )
            return
        }

        guard let relativePath = Self.allowedResourcePath(for: requestURL),
              let resourceRoot else {
            fail(urlSchemeTask, code: .fileNoSuchFile)
            return
        }
        let resourceURL = resourceRoot.appendingPathComponent(relativePath)
        serve(
            resourceURL,
            as: mimeType(for: resourceURL.pathExtension),
            requestURL: requestURL,
            task: urlSchemeTask,
            textEncodingName: "utf-8"
        )
    }

    /// Registers one host-resolved image behind an opaque, non-file Web URL.
    /// Registrations are conversation-scoped by the coordinator and cleared on
    /// conversation changes or renderer teardown.
    func registerLocalAsset(sourceURL: URL, mimeType: String) -> URL? {
        guard sourceURL.isFileURL,
              mimeType == "image/jpeg" || mimeType == "image/png" else { return nil }
        let token = UUID().uuidString.lowercased()
        localAssetLock.withLock {
            localAssetResources[token] = LocalAssetResource(
                sourceURL: sourceURL,
                mimeType: mimeType
            )
        }
        return URL(string: "\(Self.scheme)://\(Self.localAssetHost)/\(token)")
    }

    func removeAllLocalAssets() {
        localAssetLock.withLock {
            localAssetResources.removeAll()
        }
    }

    static func isLocalAssetURL(_ url: URL) -> Bool {
        guard url.scheme == scheme,
              url.host == localAssetHost,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: token) != nil && !token.contains("/")
    }

    private func localAssetResource(for url: URL) -> LocalAssetResource? {
        guard Self.isLocalAssetURL(url) else { return nil }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return localAssetLock.withLock {
            localAssetResources[token]
        }
    }

    private func serve(
        _ resourceURL: URL,
        as mimeType: String,
        requestURL: URL,
        task: any WKURLSchemeTask,
        textEncodingName: String? = nil
    ) {
        do {
            let data = try Data(contentsOf: resourceURL, options: .mappedIfSafe)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: textEncodingName
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
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
