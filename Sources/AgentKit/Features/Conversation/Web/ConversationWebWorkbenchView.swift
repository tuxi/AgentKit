//
//  ConversationWebWorkbenchView.swift
//  AgentKit
//
//  One WKWebView / one DOM document for the active macOS conversation.
//

#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import WebKit

@MainActor
struct ConversationWebWorkbenchView: NSViewRepresentable {
    let snapshot: RuntimeSnapshot
    let conversationID: String?
    let extensionContributions: [String: [TimelineWebContribution]]
    let timelineExtensions: [any TimelineExtension]
    let onFatalFailure: @MainActor () -> Void

    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let schemeHandler = ConversationWebSchemeHandler()
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: ConversationWebSchemeHandler.scheme
        )

        let messageProxy = WeakScriptMessageHandler(delegate: context.coordinator)
        configuration.userContentController.add(messageProxy, name: Coordinator.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .clear

        context.coordinator.attach(
            webView: webView,
            messageProxy: messageProxy,
            schemeHandler: schemeHandler,
            onFatalFailure: onFatalFailure
        )
        context.coordinator.replaceSnapshot(
            snapshot,
            conversationID: conversationID,
            extensionContributions: extensionContributions,
            timelineExtensions: timelineExtensions,
            store: workspaceStore,
            openURL: openURL
        )
        context.coordinator.loadShell()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.replaceSnapshot(
            snapshot,
            conversationID: conversationID,
            extensionContributions: extensionContributions,
            timelineExtensions: timelineExtensions,
            store: workspaceStore,
            openURL: openURL
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
        webView.navigationDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "agentkitWorkbench"
        private static let logger = Logger(
            subsystem: "AgentKit",
            category: "ConversationWebWorkbench"
        )

        private weak var webView: WKWebView?
        private var messageProxy: WeakScriptMessageHandler?
        private var schemeHandler: ConversationWebSchemeHandler?
        private var latestDocument: ConversationWebDocument?
        private var lastSentDocument: ConversationWebDocument?
        private var isPageReady = false
        private var shellURL: URL?
        private var sourceGeneration: UInt64?
        private var sourceConversationID: String?
        private var sourceExtensionContributions: [String: [TimelineWebContribution]] = [:]
        private var rendererRevision: UInt64 = 0
        private var latestTurns: [ConversationTurn] = []
        private var latestTimelineExtensions: [any TimelineExtension] = []
        private weak var workspaceStore: WorkspaceStore?
        private var openURL: OpenURLAction?
        private var onFatalFailure: (@MainActor () -> Void)?
        private var processTerminationDates: [Date] = []
        private let actionRegistry = ConversationWebActionRegistry()

        fileprivate func attach(
            webView: WKWebView,
            messageProxy: WeakScriptMessageHandler,
            schemeHandler: ConversationWebSchemeHandler,
            onFatalFailure: @escaping @MainActor () -> Void
        ) {
            self.webView = webView
            self.messageProxy = messageProxy
            self.schemeHandler = schemeHandler
            self.onFatalFailure = onFatalFailure
        }

        func detach() {
            webView = nil
            messageProxy = nil
            schemeHandler = nil
            isPageReady = false
            actionRegistry.removeAll()
            onFatalFailure = nil
        }

        func replaceSnapshot(
            _ snapshot: RuntimeSnapshot,
            conversationID: String?,
            extensionContributions: [String: [TimelineWebContribution]],
            timelineExtensions: [any TimelineExtension],
            store: WorkspaceStore,
            openURL: OpenURLAction
        ) {
            workspaceStore = store
            self.openURL = openURL
            latestTurns = snapshot.turns
            latestTimelineExtensions = timelineExtensions

            let resolvedConversationID = conversationID ?? "unbound"
            guard sourceGeneration != snapshot.generation
                    || sourceConversationID != resolvedConversationID
                    || sourceExtensionContributions != extensionContributions else {
                return
            }

            if sourceConversationID != resolvedConversationID {
                rendererRevision = 1
                lastSentDocument = nil
                actionRegistry.removeAll()
            } else {
                rendererRevision &+= 1
            }
            sourceGeneration = snapshot.generation
            sourceConversationID = resolvedConversationID
            sourceExtensionContributions = extensionContributions

            actionRegistry.beginRevision()
            let document = ConversationWebDocumentBuilder.build(
                snapshot: snapshot,
                conversationID: resolvedConversationID,
                revision: rendererRevision,
                extensionContributions: extensionContributions,
                registerAction: { [actionRegistry] action in
                    actionRegistry.register(action)
                }
            )
            actionRegistry.finishRevision()
            latestDocument = document
            sendLatestDocumentIfPossible()
        }

        func loadShell() {
            let indexURL = ConversationWebSchemeHandler.indexURL
            shellURL = indexURL
            isPageReady = false
            webView?.load(URLRequest(url: indexURL))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageHandlerName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                guard body["protocolVersion"] as? Int
                        == ConversationWebDocument.currentProtocolVersion else {
                    reportFatalFailure("Conversation Web protocol mismatch")
                    return
                }
                isPageReady = true
                lastSentDocument = nil
                sendLatestDocumentIfPossible()
            case "ack":
                if let revision = body["revision"] as? Int,
                   let duration = body["applyDurationMilliseconds"] as? Double {
                    Self.logger.debug(
                        "Applied Web revision \(revision, privacy: .public) in \(duration, privacy: .public) ms"
                    )
                }
            case "resync":
                Self.logger.notice("Web renderer requested a full document resync")
                lastSentDocument = nil
                sendLatestDocumentIfPossible()
            case "action":
                handleAction(body)
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .other,
               url.scheme == ConversationWebSchemeHandler.scheme,
               url == shellURL {
                decisionHandler(.allow)
            } else {
                // Runtime content never navigates the workbench. Approved link
                // actions travel through the versioned native message bridge.
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let now = Date()
            processTerminationDates = processTerminationDates.filter {
                now.timeIntervalSince($0) < 30
            }
            processTerminationDates.append(now)
            Self.logger.error(
                "Web content process terminated; recent count=\(self.processTerminationDates.count, privacy: .public)"
            )
            if processTerminationDates.count >= 3 {
                reportFatalFailure("Conversation Web process terminated repeatedly")
                return
            }
            isPageReady = false
            lastSentDocument = nil
            loadShell()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            reportFatalFailure("Conversation Web shell failed to load: \(error.localizedDescription)")
        }

        private func sendLatestDocumentIfPossible() {
            guard isPageReady,
                  let webView,
                  let document = latestDocument else { return }
            guard let update = ConversationWebDocumentDiffer.update(
                from: lastSentDocument,
                to: document
            ) else { return }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let payload = try encoder.encode(update).base64EncodedString()
                let script = "window.AgentKitWorkbench?.applyUpdateBase64('\(payload)')"
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard error == nil else {
                        Self.logger.error("Failed to apply a Web document update")
                        self?.lastSentDocument = nil
                        return
                    }
                }
                lastSentDocument = document
            } catch {
                assertionFailure("Failed to encode ConversationWebUpdate: \(error)")
            }
        }

        private func handleAction(_ body: [String: Any]) {
            guard body["protocolVersion"] as? Int
                    == ConversationWebDocument.currentProtocolVersion,
                  body["conversationID"] as? String == sourceConversationID,
                  let revision = (body["revision"] as? NSNumber)?.uint64Value,
                  revision == rendererRevision else { return }

            if let actionID = body["actionID"] as? String,
               actionID.utf8.count <= 64,
               UUID(uuidString: actionID) != nil,
               let action = actionRegistry.resolve(actionID),
               let workspaceStore,
               let openURL {
                ConversationWebActionDispatcher.dispatch(
                    action,
                    turns: latestTurns,
                    timelineExtensions: latestTimelineExtensions,
                    store: workspaceStore,
                    openURL: openURL
                )
                return
            }

            // Ordinary Markdown URLs are visible by definition and do not need
            // an opaque registry entry, but still cross the native scheme gate.
            guard body["action"] as? String == "openURL",
                  let rawURL = body["value"] as? String,
                  rawURL.utf8.count <= 4_096,
                  let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let openURL else { return }
            openURL(url)
        }

        private func reportFatalFailure(_ message: String) {
            #if DEBUG
            NSLog("[AgentKit] %@", message)
            #endif
            Self.logger.fault("\(message, privacy: .public)")
            onFatalFailure?()
        }
    }
}

@MainActor
fileprivate final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
#endif
