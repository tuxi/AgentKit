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
    static let previewHost = "preview"
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!

    private enum LocalAssetResource {
        case file(URL, mimeType: String)
        case data(Data, mimeType: String)
    }

    private let resourceRoot: URL?
    private let localAssetLock = NSLock()
    private var localAssetResources: [String: LocalAssetResource] = [:]
    private let previewViewerLock = NSLock()
    private var previewViewers: [String: PreviewViewerResource] = [:]
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

        if let previewViewer = previewViewerResource(for: requestURL) {
            servePreviewViewer(
                previewViewer,
                requestURL: requestURL,
                task: urlSchemeTask
            )
            return
        }

        if let localAsset = localAssetResource(for: requestURL) {
            switch localAsset {
            case .file(let sourceURL, let mimeType):
                serve(
                    sourceURL,
                    as: mimeType,
                    requestURL: requestURL,
                    task: urlSchemeTask
                )
            case .data(let data, let mimeType):
                serve(
                    data,
                    as: mimeType,
                    requestURL: requestURL,
                    task: urlSchemeTask
                )
            }
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
              Self.previewAssetMIMETypes.contains(mimeType.lowercased()) else { return nil }
        return registerLocalAssetResource(.file(sourceURL, mimeType: mimeType.lowercased()))
    }

    /// Registers verified fallback bytes behind the same opaque non-file image
    /// scheme used by existing user assets.
    func registerLocalAsset(data: Data, mimeType: String) -> URL? {
        let normalizedMIME = mimeType.lowercased()
        guard Self.previewAssetMIMETypes.contains(normalizedMIME), !data.isEmpty else { return nil }
        return registerLocalAssetResource(.data(data, mimeType: normalizedMIME))
    }

    /// Registers verified trusted-viewer bytes under an opaque preview token.
    func registerPreviewViewer(_ resource: PreviewViewerResource) -> URL? {
        guard resource.statusCode == 200,
              resource.mimeType.lowercased() == "text/html; charset=utf-8",
              resource.data.count == resource.sizeBytes,
              resource.data.count <= PreviewArtifact.maximumViewerBytes,
              !resource.data.isEmpty else { return nil }
        let token = UUID().uuidString.lowercased()
        previewViewerLock.withLock {
            previewViewers[token] = resource
        }
        return URL(string: "\(Self.scheme)://\(Self.previewHost)/\(token)")
    }

    func removeAllLocalAssets() {
        localAssetLock.withLock {
            localAssetResources.removeAll()
        }
    }

    func removeAllPreviewViewers() {
        previewViewerLock.withLock {
            previewViewers.removeAll()
        }
    }

    static func isPreviewViewerURL(_ url: URL) -> Bool {
        guard url.scheme == scheme,
              url.host == previewHost,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: token) != nil && !token.contains("/")
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

    private static let previewAssetMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp",
    ]

    private func registerLocalAssetResource(_ resource: LocalAssetResource) -> URL? {
        let token = UUID().uuidString.lowercased()
        localAssetLock.withLock {
            localAssetResources[token] = resource
        }
        return URL(string: "\(Self.scheme)://\(Self.localAssetHost)/\(token)")
    }

    private func previewViewerResource(for url: URL) -> PreviewViewerResource? {
        guard Self.isPreviewViewerURL(url) else { return nil }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return previewViewerLock.withLock {
            previewViewers[token]
        }
    }

    private func localAssetResource(for url: URL) -> LocalAssetResource? {
        guard Self.isLocalAssetURL(url) else { return nil }
        let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return localAssetLock.withLock {
            localAssetResources[token]
        }
    }

    private func servePreviewViewer(
        _ resource: PreviewViewerResource,
        requestURL: URL,
        task: any WKURLSchemeTask
    ) {
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            task.didFailWithError(CocoaError(.fileReadCorruptFile))
            return
        }
        task.didReceive(response)
        task.didReceive(resource.data)
        task.didFinish()
    }

    private func serve(
        _ data: Data,
        as mimeType: String,
        requestURL: URL,
        task: any WKURLSchemeTask
    ) {
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
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
