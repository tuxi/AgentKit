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
    let isVisible: Bool
    let onFatalFailure: @MainActor () -> Void

    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ConversationWebWorkbenchHostView {
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

        let hostView = ConversationWebWorkbenchHostView(webView: webView)

        context.coordinator.attach(
            hostView: hostView,
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
        context.coordinator.setVisible(isVisible)
        context.coordinator.loadShell()
        return hostView
    }

    func updateNSView(_ hostView: ConversationWebWorkbenchHostView, context: Context) {
        context.coordinator.replaceSnapshot(
            snapshot,
            conversationID: conversationID,
            extensionContributions: extensionContributions,
            timelineExtensions: timelineExtensions,
            store: workspaceStore,
            openURL: openURL
        )
        context.coordinator.setVisible(isVisible)
    }

    static func dismantleNSView(
        _ hostView: ConversationWebWorkbenchHostView,
        coordinator: Coordinator
    ) {
        let webView = hostView.webView
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

        private weak var hostView: ConversationWebWorkbenchHostView?
        private weak var webView: WKWebView?
        private var messageProxy: WeakScriptMessageHandler?
        private var schemeHandler: ConversationWebSchemeHandler?
        private var latestSnapshot: RuntimeSnapshot?
        private var acknowledgedSnapshot: RuntimeSnapshot?
        private var inFlightSnapshot: RuntimeSnapshot?
        private var acknowledgedDocument: ConversationWebDocument?
        private var inFlightDocument: ConversationWebDocument?
        private var acknowledgedRevision: UInt64 = 0
        private var isPageReady = false
        private var shellURL: URL?
        private var sourceGeneration: UInt64?
        private var sourceConversationID: String?
        private var sourceExtensionContributions: [String: [TimelineWebContribution]] = [:]
        private var acknowledgedExtensionContributions: [String: [TimelineWebContribution]] = [:]
        private var inFlightExtensionContributions: [String: [TimelineWebContribution]]?
        private var sourceVersion: UInt64 = 0
        private var inFlightSourceVersion: UInt64?
        private var sendTask: Task<Void, Never>?
        private var acknowledgementTimeoutTask: Task<Void, Never>?
        private var latestTurns: [ConversationTurn] = []
        private var latestTimelineExtensions: [any TimelineExtension] = []
        private weak var workspaceStore: WorkspaceStore?
        private var openURL: OpenURLAction?
        private var onFatalFailure: (@MainActor () -> Void)?
        private var rendererFailureDates: [Date] = []
        private var recoveryViewport: ConversationWebUpdate.RecoveryViewport?
        private var shouldRestoreViewportAfterReload = false
        private var isViewportInteracting = false
        private var isVisible = true
        private var lastApplyDurationMilliseconds: Double = 0
        private let actionRegistry = ConversationWebActionRegistry()

        /// Conversation text does not benefit from display-refresh-rate DOM
        /// replacement. Leaving budget between Markdown/layout passes keeps
        /// scrolling responsive and lets snapshot churn coalesce.
        private static let minimumStreamingIntervalMilliseconds = 50
        private static let maximumStreamingIntervalMilliseconds = 160

        fileprivate func attach(
            hostView: ConversationWebWorkbenchHostView,
            webView: WKWebView,
            messageProxy: WeakScriptMessageHandler,
            schemeHandler: ConversationWebSchemeHandler,
            onFatalFailure: @escaping @MainActor () -> Void
        ) {
            self.hostView = hostView
            self.webView = webView
            self.messageProxy = messageProxy
            self.schemeHandler = schemeHandler
            self.onFatalFailure = onFatalFailure
        }

        func detach() {
            hostView = nil
            webView = nil
            messageProxy = nil
            schemeHandler = nil
            isPageReady = false
            sendTask?.cancel()
            sendTask = nil
            acknowledgementTimeoutTask?.cancel()
            acknowledgementTimeoutTask = nil
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
                sendTask?.cancel()
                sendTask = nil
                acknowledgementTimeoutTask?.cancel()
                acknowledgementTimeoutTask = nil
                acknowledgedDocument = nil
                acknowledgedSnapshot = nil
                inFlightDocument = nil
                inFlightSnapshot = nil
                acknowledgedRevision = 0
                sourceVersion = 0
                inFlightSourceVersion = nil
                recoveryViewport = nil
                shouldRestoreViewportAfterReload = false
                isViewportInteracting = false
                lastApplyDurationMilliseconds = 0
                actionRegistry.removeAll()
                acknowledgedExtensionContributions = [:]
                inFlightExtensionContributions = nil
            }
            latestSnapshot = snapshot
            sourceGeneration = snapshot.generation
            sourceConversationID = resolvedConversationID
            sourceExtensionContributions = extensionContributions
            sourceVersion &+= 1
            scheduleLatestDocumentSend()
        }

        func setVisible(_ visible: Bool) {
            guard isVisible != visible else { return }
            isVisible = visible
            if visible {
                applyVisibilityToPage()
                scheduleLatestDocumentSend(delayMilliseconds: 0)
            } else {
                sendTask?.cancel()
                sendTask = nil
                applyVisibilityToPage()
            }
        }

        private func applyVisibilityToPage() {
            guard isPageReady else { return }
            webView?.evaluateJavaScript(
                "window.AgentKitWorkbench?.setSuspended(\(!isVisible))"
            )
        }

        func loadShell() {
            let indexURL = ConversationWebSchemeHandler.indexURL
            shellURL = indexURL
            isPageReady = false
            hostView?.concealWebView()
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
                applyVisibilityToPage()
                // A fresh Web process has no document even when Swift retains
                // an acknowledged revision from before a reload.
                inFlightDocument = nil
                inFlightSnapshot = nil
                inFlightSourceVersion = nil
                acknowledgedDocument = nil
                acknowledgedSnapshot = nil
                acknowledgedExtensionContributions = [:]
                inFlightExtensionContributions = nil
                acknowledgementTimeoutTask?.cancel()
                acknowledgementTimeoutTask = nil
                actionRegistry.removeAll()
                if isVisible {
                    scheduleLatestDocumentSend(delayMilliseconds: 0)
                }
            case "ack":
                handleAcknowledgement(body)
            case "resync":
                Self.logger.notice("Web renderer requested a full document resync")
                if let currentRevision = (body["currentRevision"] as? NSNumber)?.uint64Value {
                    acknowledgedRevision = max(acknowledgedRevision, currentRevision)
                }
                inFlightDocument = nil
                inFlightSnapshot = nil
                inFlightSourceVersion = nil
                acknowledgedDocument = nil
                acknowledgedSnapshot = nil
                acknowledgedExtensionContributions = [:]
                inFlightExtensionContributions = nil
                acknowledgementTimeoutTask?.cancel()
                acknowledgementTimeoutTask = nil
                actionRegistry.removeAll()
                scheduleLatestDocumentSend(delayMilliseconds: 0)
            case "viewport":
                handleViewport(body)
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
            recoverRendererOrFallback(reason: "Web content process terminated")
        }

        private func recoverRendererOrFallback(reason: String) {
            let now = Date()
            rendererFailureDates = rendererFailureDates.filter {
                now.timeIntervalSince($0) < 30
            }
            rendererFailureDates.append(now)
            Self.logger.error(
                "\(reason, privacy: .public); recent count=\(self.rendererFailureDates.count, privacy: .public)"
            )
            if rendererFailureDates.count >= 3 {
                reportFatalFailure("Conversation Web renderer failed repeatedly")
                return
            }
            isPageReady = false
            sendTask?.cancel()
            sendTask = nil
            acknowledgementTimeoutTask?.cancel()
            acknowledgementTimeoutTask = nil
            inFlightDocument = nil
            inFlightSnapshot = nil
            inFlightSourceVersion = nil
            acknowledgedDocument = nil
            acknowledgedSnapshot = nil
            acknowledgedExtensionContributions = [:]
            inFlightExtensionContributions = nil
            shouldRestoreViewportAfterReload = recoveryViewport != nil
            loadShell()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            reportFatalFailure("Conversation Web shell failed to load: \(error.localizedDescription)")
        }

        private func scheduleLatestDocumentSend(delayMilliseconds: Int? = nil) {
            guard isVisible else { return }
            guard !isViewportInteracting else { return }
            guard sendTask == nil else { return }
            let resolvedDelay = delayMilliseconds ?? nextStreamingDelayMilliseconds
            sendTask = Task { @MainActor [weak self] in
                if resolvedDelay > 0 {
                    try? await Task.sleep(for: .milliseconds(resolvedDelay))
                }
                guard !Task.isCancelled else { return }
                self?.sendTask = nil
                self?.sendLatestDocumentIfPossible()
            }
        }

        /// Sends at most one update at a time. Snapshot churn while WebKit is
        /// applying a revision is coalesced into the latest source state and is
        /// diffed only after the displayed revision acknowledges.
        private func sendLatestDocumentIfPossible() {
            guard isPageReady,
                  isVisible,
                  !isViewportInteracting,
                  inFlightDocument == nil,
                  let webView,
                  let latestSnapshot,
                  let sourceConversationID else { return }

            let revision = acknowledgedRevision &+ 1
            actionRegistry.beginRevision(revision)
            let reuseSource = acknowledgedSnapshot.flatMap { snapshot in
                acknowledgedDocument.map { document in
                    ConversationWebDocumentBuilder.ReuseSource(
                        snapshot: snapshot,
                        document: document,
                        extensionContributions: acknowledgedExtensionContributions
                    )
                }
            }
            let document = ConversationWebDocumentBuilder.build(
                snapshot: latestSnapshot,
                conversationID: sourceConversationID,
                revision: revision,
                extensionContributions: sourceExtensionContributions,
                reusing: reuseSource,
                registerAction: { [actionRegistry] action in
                    actionRegistry.register(action)
                }
            )
            actionRegistry.finishRevision(
                retaining: ConversationWebDocumentBuilder.actionTokens(in: document)
            )

            let update: ConversationWebUpdate?
            if let acknowledgedDocument {
                update = ConversationWebDocumentDiffer.update(
                    from: acknowledgedDocument,
                    to: document
                )
            } else {
                update = ConversationWebDocumentDiffer.reset(
                    document,
                    recoveryViewport: shouldRestoreViewportAfterReload
                        ? recoveryViewport
                        : nil
                )
            }

            guard let update else {
                actionRegistry.retainRevisions(
                    acknowledgedRevision == 0 ? [] : [acknowledgedRevision]
                )
                return
            }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let payload = try encoder.encode(update).base64EncodedString()
                let script = "window.AgentKitWorkbench?.applyUpdateBase64('\(payload)')"
                inFlightDocument = document
                inFlightSnapshot = latestSnapshot
                inFlightSourceVersion = sourceVersion
                inFlightExtensionContributions = sourceExtensionContributions
                actionRegistry.retainRevisions(
                    Set([acknowledgedRevision, revision].filter { $0 > 0 })
                )
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard let self, error != nil else { return }
                    Self.logger.error("Failed to apply a Web document update")
                    self.acknowledgementTimeoutTask?.cancel()
                    self.acknowledgementTimeoutTask = nil
                    self.inFlightDocument = nil
                    self.inFlightSnapshot = nil
                    self.inFlightSourceVersion = nil
                    self.inFlightExtensionContributions = nil
                    self.acknowledgedDocument = nil
                    self.actionRegistry.retainRevisions(
                        self.acknowledgedRevision == 0 ? [] : [self.acknowledgedRevision]
                    )
                    self.scheduleLatestDocumentSend(delayMilliseconds: 0)
                }
                startAcknowledgementTimeout(for: revision)
            } catch {
                inFlightDocument = nil
                inFlightSnapshot = nil
                inFlightSourceVersion = nil
                inFlightExtensionContributions = nil
                actionRegistry.retainRevisions(
                    acknowledgedRevision == 0 ? [] : [acknowledgedRevision]
                )
                assertionFailure("Failed to encode ConversationWebUpdate: \(error)")
            }
        }

        private func handleAcknowledgement(_ body: [String: Any]) {
            guard body["conversationID"] as? String == sourceConversationID,
                  let revision = (body["revision"] as? NSNumber)?.uint64Value,
                  let inFlightDocument,
                  inFlightDocument.revision == revision else { return }

            let appliedSourceVersion = inFlightSourceVersion
            acknowledgementTimeoutTask?.cancel()
            acknowledgementTimeoutTask = nil
            acknowledgedDocument = inFlightDocument
            acknowledgedSnapshot = inFlightSnapshot
            acknowledgedExtensionContributions = inFlightExtensionContributions ?? [:]
            acknowledgedRevision = revision
            self.inFlightDocument = nil
            inFlightSnapshot = nil
            inFlightSourceVersion = nil
            inFlightExtensionContributions = nil
            shouldRestoreViewportAfterReload = false
            actionRegistry.retainRevisions([revision])
            hostView?.revealWebView()

            if let duration = body["applyDurationMilliseconds"] as? Double {
                lastApplyDurationMilliseconds = duration
                Self.logger.debug(
                    "Applied Web revision \(revision, privacy: .public) in \(duration, privacy: .public) ms"
                )
            }
            if appliedSourceVersion != sourceVersion, isVisible, !isViewportInteracting {
                scheduleLatestDocumentSend()
            }
        }

        private var nextStreamingDelayMilliseconds: Int {
            let adaptiveDelay = Int((lastApplyDurationMilliseconds * 2).rounded(.up))
            return min(
                Self.maximumStreamingIntervalMilliseconds,
                max(Self.minimumStreamingIntervalMilliseconds, adaptiveDelay)
            )
        }

        private func startAcknowledgementTimeout(for revision: UInt64) {
            acknowledgementTimeoutTask?.cancel()
            acknowledgementTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled,
                      let self,
                      self.inFlightDocument?.revision == revision else { return }
                self.acknowledgementTimeoutTask = nil
                self.recoverRendererOrFallback(
                    reason: "Timed out waiting for Web revision \(revision) acknowledgement"
                )
            }
        }

        private func handleViewport(_ body: [String: Any]) {
            guard body["conversationID"] as? String == sourceConversationID,
                  let revision = (body["revision"] as? NSNumber)?.uint64Value,
                  revision == acknowledgedRevision
                    || revision == inFlightDocument?.revision,
                  let pinned = body["pinned"] as? Bool else { return }

            let wasInteracting = isViewportInteracting
            isViewportInteracting = body["interacting"] as? Bool ?? false
            let anchorID = body["anchorID"] as? String
            guard anchorID?.utf8.count ?? 0 <= 256 else { return }
            recoveryViewport = .init(
                pinned: pinned,
                anchorID: anchorID,
                anchorTop: body["anchorTop"] as? Double
            )
            if wasInteracting, !isViewportInteracting,
               inFlightDocument == nil {
                scheduleLatestDocumentSend(delayMilliseconds: 0)
            }
        }

        private func handleAction(_ body: [String: Any]) {
            guard body["protocolVersion"] as? Int
                    == ConversationWebDocument.currentProtocolVersion,
                  body["conversationID"] as? String == sourceConversationID,
                  let revision = (body["revision"] as? NSNumber)?.uint64Value,
                  revision == acknowledgedRevision
                    || revision == inFlightDocument?.revision else { return }

            if let actionID = body["actionID"] as? String,
               actionID.utf8.count <= 64,
               UUID(uuidString: actionID) != nil,
               let action = actionRegistry.resolve(actionID, revision: revision),
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

/// Keeps WebKit's provisional white backing surface out of the presentation.
/// The transparent host lets the SwiftUI timeline background remain the single
/// source of truth before and after the first document acknowledgement.
@MainActor
final class ConversationWebWorkbenchHostView: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        webView.alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func concealWebView() {
        webView.alphaValue = 0
    }

    func revealWebView() {
        webView.alphaValue = 1
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
