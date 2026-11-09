//
//  ConversationWebPreviewSecurity.swift
//  AgentKit
//
//  Shared policy for isolated preview viewer frames and their native bridge.
//

import Foundation

enum ConversationWebPreviewNavigationDecision: Equatable {
    case allow
    case cancel
}

struct ConversationWebPreviewSecurityError: Error, Equatable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

enum ConversationWebPreviewSecurity {
    static let iframeSandbox = "allow-scripts"
    static let parentFrameSource = "agentkit-workbench:"

    /// Defense-in-depth network block. The viewer's own CSP is the primary
    /// control; this rule list also blocks remote document/subresource loads and
    /// every popup before WebKit can reach the network. Remote images are
    /// intentionally absent: the workbench's existing gateway-backed user
    /// assets load as HTTPS images, while the isolated viewer's `img-src data:`
    /// policy still rejects every remote image inside preview content.
    static let networkBlockRulesJSON = """
    [
      {"trigger":{"url-filter":"^https?://","resource-type":["document","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://","resource-type":["raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://","resource-type":["document","image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^file://","resource-type":["document","image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","resource-type":["popup"]},"action":{"type":"block"}}
    ]
    """

    private static let requiredViewerCSP = [
        "default-src'none'",
        "script-src'unsafe-inline'",
        "style-src'unsafe-inline'",
        "img-srcdata:",
        "connect-src'none'",
        "frame-src'none'",
        "object-src'none'",
        "base-uri'none'",
        "form-action'none'",
    ]

    static func acceptsScriptMessage(isMainFrame: Bool) -> Bool {
        isMainFrame
    }

    static func navigationDecision(
        url: URL,
        isMainFrame: Bool,
        isNewWindow: Bool,
        shouldPerformDownload: Bool,
        isInitialShellNavigation: Bool,
        shellURL: URL?,
        pendingPreviewInitialURLs: Set<URL>
    ) -> ConversationWebPreviewNavigationDecision {
        guard !isNewWindow, !shouldPerformDownload else { return .cancel }
        if isMainFrame {
            return isInitialShellNavigation && url == shellURL ? .allow : .cancel
        }
        guard url.scheme == "agentkit-workbench",
              url.host == "preview",
              pendingPreviewInitialURLs.contains(url) else {
            return .cancel
        }
        return .allow
    }

    static func responseDecision(
        canShowMIMEType: Bool,
        isAttachment: Bool
    ) -> ConversationWebPreviewNavigationDecision {
        canShowMIMEType && !isAttachment ? .allow : .cancel
    }

    /// Validates the runtime-owned trusted viewer before its bytes are exposed
    /// to WebKit. The fragment itself is never loaded directly.
    static func validateViewerDocument(_ data: Data) throws -> String {
        guard data.count <= PreviewArtifact.maximumViewerBytes else {
            throw ConversationWebPreviewSecurityError(
                code: "preview_viewer_too_large",
                message: "Viewer exceeds the 2 MiB v1 limit."
            )
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ConversationWebPreviewSecurityError(
                code: "preview_invalid_artifact",
                message: "Viewer is not valid UTF-8 HTML."
            )
        }

        let compact = html
            .lowercased()
            .filter { !$0.isWhitespace }
        guard compact.contains("http-equiv=\"content-security-policy\""),
              requiredViewerCSP.allSatisfy(compact.contains) else {
            throw ConversationWebPreviewSecurityError(
                code: "preview_security_violation",
                message: "Viewer is missing the required self-contained CSP."
            )
        }

        for forbiddenTag in ["<iframe", "<object", "<embed", "<form"] {
            guard !compact.contains(forbiddenTag) else {
                throw ConversationWebPreviewSecurityError(
                    code: "preview_security_violation",
                    message: "Viewer contains a forbidden active element."
                )
            }
        }
        for externalReference in [
            "src=\"http", "src='http", "src=\"//", "src='//",
            "href=\"http", "href='http", "href=\"//", "href='//",
            "url(http", "url('http", "url(\"http",
        ] {
            guard !compact.contains(externalReference) else {
                throw ConversationWebPreviewSecurityError(
                    code: "preview_security_violation",
                    message: "Viewer contains an external resource reference."
                )
            }
        }
        return html
    }
}
