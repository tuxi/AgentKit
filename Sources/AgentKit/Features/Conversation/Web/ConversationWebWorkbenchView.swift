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
    let workspaceRoot: URL?
    var workspaceID: String? = nil
    let previewViewerResolver: (any PreviewViewerResolver)?
    let previewAssetResolver: (any PreviewAssetResolver)?
    let extensionContributions: [String: [TimelineWebContribution]]
    let timelineExtensions: [any TimelineExtension]
    let isVisible: Bool
    /// Height of the floating macOS bottom bar. The workbench mirrors it as
    /// bottom document padding so pinned content rests above the bar while the
    /// scroll range still extends behind it.
    let bottomInset: CGFloat
    let onFatalFailure: @MainActor () -> Void
    /// Presents the shared native image previewer when the Web renderer
    /// reports a thumbnail click. Only asset identities cross the bridge;
    /// the host rebuilds the turn's mixed image list and resolves display
    /// URLs natively (signed https / staged file URLs).
    var onPreviewAssets: (@MainActor (AssetPreviewPresentation) -> Void)? = nil
    var onReachedTop: (@MainActor () -> Void)? = nil

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
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .clear
        // Expose the renderer to Safari's Develop menu for Web Inspector
        // debugging (macOS 13.3+). Required for CSP/network diagnosis.
        webView.isInspectable = true

        let hostView = ConversationWebWorkbenchHostView(webView: webView)

        context.coordinator.attach(
            hostView: hostView,
            webView: webView,
            messageProxy: messageProxy,
            schemeHandler: schemeHandler,
            previewViewerResolver: previewViewerResolver,
            previewAssetResolver: previewAssetResolver,
            onFatalFailure: onFatalFailure,
            onPreviewAssets: onPreviewAssets,
            onReachedTop: onReachedTop
        )
        context.coordinator.replaceSnapshot(
            snapshot,
            conversationID: conversationID,
            workspaceRoot: workspaceRoot,
            workspaceID: workspaceID,
            extensionContributions: extensionContributions,
            timelineExtensions: timelineExtensions,
            store: workspaceStore,
            openURL: openURL
        )
        context.coordinator.setVisible(isVisible)
        context.coordinator.installSecurityRulesAndLoadShell()
        return hostView
    }

    func updateNSView(_ hostView: ConversationWebWorkbenchHostView, context: Context) {
        context.coordinator.onReachedTop = onReachedTop
        context.coordinator.replaceSnapshot(
            snapshot,
            conversationID: conversationID,
            workspaceRoot: workspaceRoot,
            workspaceID: workspaceID,
            extensionContributions: extensionContributions,
            timelineExtensions: timelineExtensions,
            store: workspaceStore,
            openURL: openURL
        )
        context.coordinator.setVisible(isVisible)
        context.coordinator.updateBottomInset(bottomInset)
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
        webView.uiDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "agentkitWorkbench"
        private static let logger = Logger(
            subsystem: "AgentKit",
            category: "ConversationWebWorkbench"
        )

        private weak var hostView: ConversationWebWorkbenchHostView?
        private weak var webView: WKWebView?
        private var messageProxy: WeakScriptMessageHandler?
        private var schemeHandler: ConversationWebSchemeHandler?
        private var previewViewerResolver: (any PreviewViewerResolver)?
        private var previewAssetResolver: (any PreviewAssetResolver)?
        private var previewResolutionTasks: [String: Task<Void, Never>] = [:]
        private var pendingPreviewInitialURLs: Set<URL> = []
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
        private var sourceWorkspaceRoot: URL?
        private var sourceWorkspaceID: String?
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
        private var onPreviewAssets: (@MainActor (AssetPreviewPresentation) -> Void)?
        fileprivate var onReachedTop: (@MainActor () -> Void)?
        private var rendererFailureDates: [Date] = []
        private var recoveryViewport: ConversationWebUpdate.RecoveryViewport?
        private var shouldRestoreViewportAfterReload = false
        private var isViewportInteracting = false
        private var isVisible = true
        private var appliedBottomInset: CGFloat = 0
        private var appliedHostBackgroundHex: String?
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
            previewViewerResolver: (any PreviewViewerResolver)?,
            previewAssetResolver: (any PreviewAssetResolver)?,
            onFatalFailure: @escaping @MainActor () -> Void,
            onPreviewAssets: (@MainActor (AssetPreviewPresentation) -> Void)?,
            onReachedTop: (@MainActor () -> Void)?
        ) {
            self.hostView = hostView
            self.webView = webView
            self.messageProxy = messageProxy
            self.schemeHandler = schemeHandler
            self.previewViewerResolver = previewViewerResolver
            self.previewAssetResolver = previewAssetResolver
            self.onFatalFailure = onFatalFailure
            self.onPreviewAssets = onPreviewAssets
            self.onReachedTop = onReachedTop
            hostView.onEffectiveAppearanceChange = { [weak self] in
                self?.applyHostBackgroundToPage()
            }
        }

        func detach() {
            hostView = nil
            webView = nil
            messageProxy = nil
            schemeHandler = nil
            previewViewerResolver = nil
            previewAssetResolver = nil
            for task in previewResolutionTasks.values { task.cancel() }
            previewResolutionTasks.removeAll()
            pendingPreviewInitialURLs.removeAll()
            isPageReady = false
            sendTask?.cancel()
            sendTask = nil
            acknowledgementTimeoutTask?.cancel()
            acknowledgementTimeoutTask = nil
            actionRegistry.removeAll()
            schemeHandler?.removeAllLocalAssets()
            schemeHandler?.removeAllPreviewViewers()
            onFatalFailure = nil
            onPreviewAssets = nil
            onReachedTop = nil
        }

        func replaceSnapshot(
            _ snapshot: RuntimeSnapshot,
            conversationID: String?,
            workspaceRoot: URL?,
            workspaceID: String?,
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
                    || sourceWorkspaceRoot != workspaceRoot
                    || sourceWorkspaceID != workspaceID
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
                schemeHandler?.removeAllLocalAssets()
                schemeHandler?.removeAllPreviewViewers()
                pendingPreviewInitialURLs.removeAll()
                acknowledgedExtensionContributions = [:]
                inFlightExtensionContributions = nil
            }
            latestSnapshot = snapshot
            sourceGeneration = snapshot.generation
            sourceConversationID = resolvedConversationID
            sourceWorkspaceRoot = workspaceRoot
            sourceWorkspaceID = workspaceID
            sourceExtensionContributions = extensionContributions
            sourceVersion &+= 1
            scheduleLatestDocumentSend()
        }

        func setVisible(_ visible: Bool) {
            guard isVisible != visible else { return }
            isVisible = visible
            if visible {
                applyVisibilityToPage()
                // The page may have sat suspended through one or more
                // appearance changes while hidden. AppKit only re-resolves
                // effectiveAppearance for views that are actively drawing, so
                // any callback that fired while hidden carried a stale color
                // that the hex dedupe guard swallowed. Force a re-injection
                // with the current appearance now that the view is active.
                applyHostBackgroundToPage(force: true)
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

        func updateBottomInset(_ inset: CGFloat) {
            guard inset != appliedBottomInset else { return }
            appliedBottomInset = inset
            applyBottomInsetToPage()
        }

        /// Mirrors the floating bottom bar's height into the page. The page
        /// owns the padding via `setBottomInset` (a CSS variable on the root
        /// element, immune to React re-renders) and re-pins through its scroll
        /// controller so newest content lands exactly above the bar.
        private func applyBottomInsetToPage() {
            guard isPageReady, let webView else { return }
            webView.evaluateJavaScript(
                "window.AgentKitWorkbench?.setBottomInset(\(appliedBottomInset))"
            )
        }

        /// Re-pushes the resolved host background color to the page. Called on
        /// page-ready, whenever the effective appearance changes (light/dark
        /// switch), and with `force` when a suspended page is activated. The
        /// hex dedupe guard normally skips unchanged colors, but a page that
        /// sat hidden through an appearance change may hold a stale cached hex
        /// (AppKit only lazily re-resolves `effectiveAppearance` for views that
        /// are actively drawing), so activation forces a fresh injection.
        private func applyHostBackgroundToPage(force: Bool = false) {
            guard isPageReady, let webView, let hostView else { return }
            hostView.setNeedsDisplay(webView.bounds)
            guard let hex = Self.resolvedHostBackgroundHex(
                for: hostView.effectiveAppearance
            ) else { return }
            guard force || hex != appliedHostBackgroundHex else { return }
            appliedHostBackgroundHex = hex
            webView.evaluateJavaScript(
                "window.AgentKitWorkbench?.setHostBackground(\"\(hex)\")"
            )
        }

        /// The detail page's main background is SwiftUI `.bar` material, which
        /// is live-blurred and cannot be sampled offscreen (materials only
        /// render inside a window — an offscreen snapshot yields a constant,
        /// appearance-independent value). Since the macOS WKWebView canvas must
        /// be opaque anyway, approximate `.bar` with fixed solid colors per
        /// appearance: near-white in light mode, #2C2C2E in dark (matching the
        /// hand-tuned value previously used).
        @MainActor
        private static func resolvedHostBackgroundHex(
            for appearance: NSAppearance?
        ) -> String? {
            let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua])
                == .darkAqua
            if isDark {
               return "#1E1E1E" // "#1E1E1E"是NSColor.windowBackgroundColor在Dark主题时算出来的hex颜色值，为什么使用"#1E1E1E"而不是windowBackgroundColor，因为在系统切换主题时，首次拿到的ex(from: windowBackgroundColor)是#FFFFFF，导致错误的显示出白色
            } else {
                let color = NSColor(
                    calibratedRed: 249.0 / 255.0,
                    green: 249.0 / 255.0,
                    blue: 249.0 / 255.0,
                    alpha: 1
                )
                return hex(from: color)
            }
        }

        /// Colorspace-safe hex conversion: some NSColors (e.g. `clear`,
        /// grayscale/profile colors) reject `redComponent` with an exception
        /// unless converted first. Returns nil when conversion fails so the
        /// caller keeps the previous value instead of crashing.
        private static func hex(from color: NSColor) -> String? {
            guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
            let r = Int((srgb.redComponent * 255).rounded())
            let g = Int((srgb.greenComponent * 255).rounded())
            let b = Int((srgb.blueComponent * 255).rounded())
            return String(format: "#%02X%02X%02X", r, g, b)
        }

        func installSecurityRulesAndLoadShell() {
            guard let webView else { return }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "AgentKitConversationNetworkBlockV1",
                encodedContentRuleList: ConversationWebPreviewSecurity.networkBlockRulesJSON
            ) { [weak self, weak webView] list, error in
                Task { @MainActor in
                    guard let self, let webView else { return }
                    guard let list else {
                        self.reportFatalFailure(
                            "Conversation Web security rules failed to compile: \(error?.localizedDescription ?? "unknown error")"
                        )
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    self.loadShell()
                }
            }
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
            guard ConversationWebPreviewSecurity.acceptsScriptMessage(
                isMainFrame: message.frameInfo.isMainFrame
            ) else {
                Self.logger.notice("Rejected non-main-frame Conversation Web message")
                return
            }
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
                applyBottomInsetToPage()
                applyHostBackgroundToPage()
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
                schemeHandler?.removeAllLocalAssets()
                schemeHandler?.removeAllPreviewViewers()
                pendingPreviewInitialURLs.removeAll()
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
            case "reachedTop":
                if body["conversationID"] as? String == sourceConversationID {
                    onReachedTop?()
                }
            case "action":
                handleAction(body)
            case "resolveUserAssetURL":
                handleResolveUserAssetURL(body)
            case "resolveLocalAssetURL":
                handleResolveLocalAssetURL(body)
            case "resolveImageViewAssetURL":
                handleResolveImageViewAssetURL(body)
            case "resolvePreviewViewerURL":
                handleResolvePreviewViewerURL(body)
            case "resolvePreviewAssetURL":
                handleResolvePreviewAssetURL(body)
            case "previewTurnAssets":
                handlePreviewTurnAssets(body)
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
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            let decision = ConversationWebPreviewSecurity.navigationDecision(
                url: url,
                isMainFrame: isMainFrame,
                isNewWindow: navigationAction.targetFrame == nil,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                isInitialShellNavigation: navigationAction.navigationType == .other
                    && url == shellURL,
                shellURL: shellURL,
                pendingPreviewInitialURLs: pendingPreviewInitialURLs
            )
            guard decision == .allow else {
                decisionHandler(.cancel)
                return
            }
            if !isMainFrame {
                // The opaque viewer token gets exactly one initial frame load.
                pendingPreviewInitialURLs.remove(url)
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            let disposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?
                .lowercased() ?? ""
            let decision = ConversationWebPreviewSecurity.responseDecision(
                canShowMIMEType: navigationResponse.canShowMIMEType,
                isAttachment: disposition.contains("attachment")
            )
            decisionHandler(decision == .allow ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            completionHandler(false)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            completionHandler(nil)
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
            let buildResult = ConversationWebDocumentBuilder.buildWithStableTurns(
                snapshot: latestSnapshot,
                conversationID: sourceConversationID,
                revision: revision,
                extensionContributions: sourceExtensionContributions,
                reusing: reuseSource,
                supportsForkThroughTurn: workspaceStore?.supportsConversationForkThroughTurn ?? false,
                registerAction: { [actionRegistry] action in
                    actionRegistry.register(action)
                }
            )
            let document = buildResult.document
            actionRegistry.finishRevision(
                retaining: ConversationWebDocumentBuilder.actionTokens(in: document)
            )

            let update: ConversationWebUpdate?
            if let acknowledgedDocument {
                update = ConversationWebDocumentDiffer.update(
                    from: acknowledgedDocument,
                    to: document,
                    stableTurnIDs: buildResult.stableTurnIDs
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
//                Self.logger.debug(
//                    "Applied Web revision \(revision, privacy: .public) in \(duration, privacy: .public) ms"
//                )
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

        /// JS → Native：解析用户资产预览 URL（gateway 签名 URL）。
        /// JS 发送 `{type: "resolveUserAssetURL", assetID: Int64, requestID: String}`
        /// 原生调 `UserAssetPreviewResolving.previewURL(for:)` 获取签名 URL
        /// 通过 `evaluateJavaScript` 回调 `{type: "userAssetURLResolved", assetID, requestID, url}`
        private func handleResolveUserAssetURL(_ body: [String: Any]) {
            guard let assetID = (body["assetID"] as? NSNumber)?.int64Value,
                  assetID > 0,
                  let requestID = body["requestID"] as? String,
                  !requestID.isEmpty,
                  let resolver = workspaceStore?.userAssetPreviewResolver else { return }

            // 仅需 assetID 即可调 gateway API（resolver 只用 asset.assetID）
            let ref = UserAssetRef(assetID: assetID, mimeType: "image/jpeg", filename: "")

            Task { [weak self] in
                guard let self, let webView = self.webView else { return }
                let urlString: String?
                do {
                    let url = try await resolver.previewURL(for: ref)
                    // Upgrade to HTTPS so WKWebView won't block the image as
                    // mixed content when loaded from a custom-scheme origin.
                    if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       components.scheme == "http" {
                        components.scheme = "https"
                        urlString = components.string
                    } else {
                        urlString = url.absoluteString
                    }
                } catch {
                    urlString = nil
                }

                await MainActor.run {
                    let response = ResolveAssetResponse(
                        type: "userAssetURLResolved",
                        assetID: assetID,
                        requestID: requestID,
                        url: urlString
                    )
                    guard let jsonData = try? JSONEncoder().encode(response),
                          let json = String(data: jsonData, encoding: .utf8) else { return }
                    let cleanJSON = json.replacingOccurrences(of: "\\/", with: "/")
                    let js = "window.dispatchEvent(new CustomEvent('userAssetURLResolved', {detail: \(cleanJSON)}))"
                    webView.evaluateJavaScript(js) { _, error in
                        if let error {
                            print("[AgentKit] evaluateJavaScript failed for assetID=\(assetID): \(error)")
                        } else {
                            print("[AgentKit] evaluateJavaScript succeeded for assetID=\(assetID)")
                        }
                    }
                }
            }
        }

        /// Resolves a local history attachment through the Host, then exposes
        /// only an opaque, in-memory allowlisted scheme URL to Web content.
        private func handleResolveLocalAssetURL(_ body: [String: Any]) {
            guard let localAssetID = body["localAssetID"] as? String,
                  UUID(uuidString: localAssetID) != nil,
                  let conversationID = body["conversationID"] as? String,
                  conversationID == sourceConversationID,
                  let requestID = body["requestID"] as? String,
                  UUID(uuidString: requestID) != nil,
                  let resolver = workspaceStore?.localUserAssetPreviewResolver,
                  let workspaceRoot = sourceWorkspaceRoot,
                  let asset = latestTurns.lazy
                    .compactMap(\.userPrompt)
                    .flatMap(\.localAssets)
                    .first(where: { $0.id.caseInsensitiveCompare(localAssetID) == .orderedSame }),
                  asset.mimeType == "image/jpeg" || asset.mimeType == "image/png"
            else { return }

            let requestedSourceVersion = sourceVersion
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sourceURL: URL?
                do {
                    sourceURL = try await resolver.previewURL(
                        for: asset,
                        conversationID: conversationID,
                        workspaceRoot: workspaceRoot
                    )
                } catch {
                    sourceURL = nil
                    Self.logger.error(
                        "Local asset preview resolution failed for \(localAssetID, privacy: .public) in \(conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
                guard self.sourceConversationID == conversationID,
                      self.sourceVersion >= requestedSourceVersion,
                      let webView = self.webView else { return }
                let resolvedURL = sourceURL.flatMap {
                    self.schemeHandler?.registerLocalAsset(
                        sourceURL: $0,
                        mimeType: asset.mimeType
                    )
                }
                let response = ResolveLocalAssetResponse(
                    localAssetID: localAssetID,
                    conversationID: conversationID,
                    requestID: requestID,
                    url: resolvedURL?.absoluteString
                )
                guard let jsonData = try? JSONEncoder().encode(response),
                      let json = String(data: jsonData, encoding: .utf8) else { return }
                let script = "window.dispatchEvent(new CustomEvent('localAssetURLResolved', {detail: \(json)}))"
                _ = try? await webView.evaluateJavaScript(script)
            }
        }

        /// Resolves one structured image-view asset. The Web document sends
        /// only stable IDs; the host validates them against the exact tool
        /// result and exposes local bytes through the opaque scheme.
        private func handleResolveImageViewAssetURL(_ body: [String: Any]) {
            guard let conversationID = body["conversationID"] as? String,
                  conversationID == sourceConversationID,
                  let turnID = body["turnID"] as? String,
                  turnID.utf8.count <= 256,
                  let toolID = body["toolID"] as? String,
                  toolID.utf8.count <= 256,
                  let assetID = body["assetID"] as? String,
                  assetID.utf8.count <= 187,
                  let requestID = body["requestID"] as? String,
                  UUID(uuidString: requestID) != nil,
                  let workspaceRoot = sourceWorkspaceRoot,
                  let tool = latestTurns.lazy
                    .first(where: { $0.id == turnID })?
                    .blocks
                    .lazy
                    .compactMap({ block -> ToolNodePayload? in
                        guard case .toolGroup(let group) = block else { return nil }
                        return group.tools.first(where: { $0.callID == toolID })
                    })
                    .first(where: { tool in
                        StructuredImageActivityAssets.validatedAssetIDs(in: tool)?.contains(assetID) == true
                    }),
                  let asset = tool.assets.first(where: { $0.id == assetID }),
                  let resolvedAsset = WorkspaceImageAssetResolver.resolve(
                    asset: asset,
                    workspaceID: sourceWorkspaceID,
                    workspaceRoot: workspaceRoot
                  ) else {
                return
            }

            let registeredURL = schemeHandler?.registerLocalAsset(
                data: resolvedAsset.data,
                mimeType: resolvedAsset.mimeType
            )
            let response = ResolveImageViewAssetResponse(
                type: "imageViewAssetURLResolved",
                requestID: requestID,
                conversationID: conversationID,
                turnID: turnID,
                toolID: toolID,
                assetID: assetID,
                url: registeredURL?.absoluteString,
                errorCode: registeredURL == nil ? "image_view_asset_unavailable" : nil
            )
            guard let webView,
                  let jsonData = try? JSONEncoder().encode(response),
                  let json = String(data: jsonData, encoding: .utf8) else { return }
            let script = "window.dispatchEvent(new CustomEvent('imageViewAssetURLResolved', {detail: \(json)}))"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        /// Resolves verified viewer bytes and returns only an opaque,
        /// conversation-scoped preview scheme URL to the isolated frame.
        private func handleResolvePreviewViewerURL(_ body: [String: Any]) {
            guard let conversationID = body["conversationID"] as? String,
                  conversationID == sourceConversationID,
                  let artifactID = body["artifactID"] as? String,
                  artifactID.utf8.count <= 256,
                  let revision = (body["revision"] as? NSNumber)?.intValue,
                  revision > 0,
                  let requestID = body["requestID"] as? String,
                  UUID(uuidString: requestID) != nil,
                  let artifact = latestSnapshot?.previewArtifacts.first(where: {
                      $0.sessionID == conversationID
                          && $0.artifactID == artifactID
                          && $0.revision == revision
                  }),
                  artifact.kind == .interactiveHTML,
                  artifact.status == .ready
            else { return }
            guard let resolver = previewViewerResolver else {
                if let webView {
                    let response = ResolvePreviewViewerResponse(
                        type: "previewViewerURLResolved",
                        requestID: requestID,
                        artifactID: artifactID,
                        revision: revision,
                        url: nil,
                        errorCode: "preview_unsupported"
                    )
                    Task { @MainActor in
                        await Self.dispatchPreviewResolutionEvent(
                            "previewViewerURLResolved",
                            response: response,
                            webView: webView
                        )
                    }
                }
                return
            }

            previewResolutionTasks[requestID]?.cancel()
            previewResolutionTasks[requestID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.previewResolutionTasks.removeValue(forKey: requestID) }
                var resolvedURL: URL?
                var errorCode: String?
                do {
                    let resource = try await resolver.resolve(PreviewViewerRequest(
                        sessionID: conversationID,
                        artifactID: artifactID,
                        revision: revision
                    ))
                    guard resource.statusCode == 200 else {
                        throw PreviewResourceError(
                            code: "preview_render_failed",
                            message: "Viewer response was not successful."
                        )
                    }
                    try resource.validate(against: artifact)
                    _ = try ConversationWebPreviewSecurity.validateViewerDocument(resource.data)
                    resolvedURL = self.schemeHandler?.registerPreviewViewer(resource)
                    if resolvedURL == nil {
                        errorCode = "preview_render_failed"
                    }
                } catch {
                    errorCode = Self.previewErrorCode(error)
                    Self.logger.error(
                        "Preview viewer resolution failed for \(artifactID, privacy: .public) r\(revision, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }

                guard self.sourceConversationID == conversationID,
                      self.latestSnapshot?.previewArtifacts.contains(where: {
                          $0.sessionID == conversationID
                              && $0.artifactID == artifactID
                              && $0.revision == revision
                              && $0.status == .ready
                              && $0.kind == .interactiveHTML
                      }) == true,
                      let webView = self.webView else { return }
                if let resolvedURL {
                    self.pendingPreviewInitialURLs.insert(resolvedURL)
                }
                let response = ResolvePreviewViewerResponse(
                    type: "previewViewerURLResolved",
                    requestID: requestID,
                    artifactID: artifactID,
                    revision: revision,
                    url: resolvedURL?.absoluteString,
                    errorCode: errorCode
                )
                await Self.dispatchPreviewResolutionEvent(
                    "previewViewerURLResolved",
                    response: response,
                    webView: webView
                )
            }
        }

        /// Resolves a verified raster fallback and exposes it through the
        /// existing opaque local-asset scheme token.
        private func handleResolvePreviewAssetURL(_ body: [String: Any]) {
            guard let conversationID = body["conversationID"] as? String,
                  conversationID == sourceConversationID,
                  let artifactID = body["artifactID"] as? String,
                  artifactID.utf8.count <= 256,
                  let revision = (body["revision"] as? NSNumber)?.intValue,
                  revision > 0,
                  let assetID = body["assetID"] as? String,
                  assetID.utf8.count <= 256,
                  let requestID = body["requestID"] as? String,
                  UUID(uuidString: requestID) != nil,
                  let artifact = latestSnapshot?.previewArtifacts.first(where: {
                      $0.sessionID == conversationID
                          && $0.artifactID == artifactID
                          && $0.revision == revision
                  }),
                  artifact.fallback?.assetID == assetID
            else { return }
            guard let resolver = previewAssetResolver else {
                if let webView {
                    let response = ResolvePreviewAssetResponse(
                        type: "previewAssetURLResolved",
                        requestID: requestID,
                        artifactID: artifactID,
                        revision: revision,
                        assetID: assetID,
                        url: nil,
                        errorCode: "preview_unsupported"
                    )
                    Task { @MainActor in
                        await Self.dispatchPreviewResolutionEvent(
                            "previewAssetURLResolved",
                            response: response,
                            webView: webView
                        )
                    }
                }
                return
            }

            previewResolutionTasks[requestID]?.cancel()
            previewResolutionTasks[requestID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.previewResolutionTasks.removeValue(forKey: requestID) }
                var resolvedURL: URL?
                var errorCode: String?
                do {
                    let resource = try await resolver.resolveContent(PreviewAssetRequest(
                        sessionID: conversationID,
                        artifactID: artifactID,
                        revision: revision,
                        assetID: assetID
                    ))
                    guard resource.statusCode == 200 else {
                        throw PreviewResourceError(
                            code: "preview_asset_unavailable",
                            message: "Preview asset response was not successful."
                        )
                    }
                    try resource.validate(against: artifact)
                    resolvedURL = self.schemeHandler?.registerLocalAsset(
                        data: resource.data,
                        mimeType: resource.mimeType
                    )
                    if resolvedURL == nil {
                        errorCode = "preview_asset_unavailable"
                    }
                } catch {
                    errorCode = Self.previewErrorCode(error)
                    Self.logger.error(
                        "Preview asset resolution failed for \(artifactID, privacy: .public)/\(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }

                guard self.sourceConversationID == conversationID,
                      self.latestSnapshot?.previewArtifacts.contains(where: {
                          $0.sessionID == conversationID
                              && $0.artifactID == artifactID
                              && $0.revision == revision
                              && $0.fallback?.assetID == assetID
                      }) == true,
                      let webView = self.webView else { return }
                let response = ResolvePreviewAssetResponse(
                    type: "previewAssetURLResolved",
                    requestID: requestID,
                    artifactID: artifactID,
                    revision: revision,
                    assetID: assetID,
                    url: resolvedURL?.absoluteString,
                    errorCode: errorCode
                )
                await Self.dispatchPreviewResolutionEvent(
                    "previewAssetURLResolved",
                    response: response,
                    webView: webView
                )
            }
        }

        private static func dispatchPreviewResolutionEvent<Response: Encodable>(
            _ eventName: String,
            response: Response,
            webView: WKWebView
        ) async {
            guard let jsonData = try? JSONEncoder().encode(response),
                  let json = String(data: jsonData, encoding: .utf8) else { return }
            let script = "window.dispatchEvent(new CustomEvent('\(eventName)', {detail: \(json)}))"
            _ = try? await webView.evaluateJavaScript(script)
        }

        private static func previewErrorCode(_ error: Error) -> String {
            if let error = error as? PreviewResourceError { return error.code }
            if let error = error as? ConversationWebPreviewSecurityError { return error.code }
            if let runtimeError = error as? RuntimeHTTPError,
               case .preview(let preview) = runtimeError {
                return preview.error.code
            }
            return "preview_render_failed"
        }

        /// Web thumbnail click → open the shared native previewer for the
        /// turn's mixed image list. Only identities cross the bridge; display
        /// URLs are resolved natively because the private workbench scheme is
        /// loadable only inside this WebView.
        private func handlePreviewTurnAssets(_ body: [String: Any]) {
            guard let conversationID = body["conversationID"] as? String,
                  conversationID == sourceConversationID,
                  let turnID = body["turnID"] as? String,
                  turnID.utf8.count <= 256,
                  let assetKind = body["assetKind"] as? String,
                  let assetID = body["assetID"] as? String,
                  assetID.utf8.count <= 64,
                  let workspaceStore,
                  let workspaceRoot = sourceWorkspaceRoot,
                  let prompt = latestTurns.first(where: { $0.id == turnID })?.userPrompt
            else { return }

            let clicked: AssetPreviewItem.Source?
            switch assetKind {
            case "user":
                clicked = Int64(assetID).map { .userAsset($0) }
            case "local":
                clicked = UUID(uuidString: assetID) != nil ? .localAsset(assetID) : nil
            default:
                clicked = nil
            }
            guard let clicked else { return }

            let userAssets = prompt.userAssets
            let localAssets = prompt.localAssets
            let userResolver = workspaceStore.userAssetPreviewResolver
            let localResolver = workspaceStore.localUserAssetPreviewResolver
            Task { @MainActor [weak self] in
                guard let self else { return }
                let items = await UserAssetPreviewCollection.resolveItems(
                    userAssets: userAssets,
                    localAssets: localAssets,
                    userResolver: userResolver,
                    localResolver: localResolver,
                    conversationID: conversationID,
                    workspaceRoot: workspaceRoot
                )
                guard self.sourceConversationID == conversationID,
                      let index = items.firstIndex(where: { $0.id == clicked }),
                      let onPreviewAssets
                else { return }
                onPreviewAssets(AssetPreviewPresentation(items: items, initialIndex: index))
            }
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
    /// Fired when the window's effective appearance changes (light/dark
    /// switch), so the coordinator can re-inject the host background color.
    var onEffectiveAppearanceChange: (() -> Void)?

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
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
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard ConversationWebPreviewSecurity.acceptsScriptMessage(
            isMainFrame: message.frameInfo.isMainFrame
        ) else { return }
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - User asset URL resolution bridge

private struct ResolveAssetResponse: Encodable {
    let type: String
    let assetID: Int64
    let requestID: String
    let url: String?
}

private struct ResolveLocalAssetResponse: Encodable {
    let localAssetID: String
    let conversationID: String
    let requestID: String
    let url: String?
}

private struct ResolveImageViewAssetResponse: Encodable {
    let type: String
    let requestID: String
    let conversationID: String
    let turnID: String
    let toolID: String
    let assetID: String
    let url: String?
    let errorCode: String?
}

private struct ResolvePreviewViewerResponse: Encodable {
    let type: String
    let requestID: String
    let artifactID: String
    let revision: Int
    let url: String?
    let errorCode: String?
}

private struct ResolvePreviewAssetResponse: Encodable {
    let type: String
    let requestID: String
    let artifactID: String
    let revision: Int
    let assetID: String
    let url: String?
    let errorCode: String?
}
#endif
