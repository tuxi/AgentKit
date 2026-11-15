//
//  UIPreviewCardView.swift
//  AgentKit
//
//  Native timeline card for `ui_preview_result.v1` on iOS. The card mirrors the
//  Web workbench presentation: mode, artifact identity, lineage facts, fallback
//  image and the isolated interactive viewer. Viewer HTML is fetched by the
//  authenticated runtime client and loaded locally — the bearer token never
//  appears in a URL, page content, or log line.
//

#if os(iOS)

import ClientToolProtocol
import SwiftUI
import UIKit
import WebKit

struct UIPreviewCardSection: View {
    let models: [UIPreviewCardModel]
    let conversationID: String?
    let previewViewerResolver: (any PreviewViewerResolver)?
    let previewAssetResolver: (any PreviewAssetResolver)?
    let onOpenInspector: (String) -> Void
    let onOpenAsset: (AgentAssetRef) -> Void

    var body: some View {
        ForEach(models) { model in
            UIPreviewCardView(
                model: model,
                conversationID: conversationID,
                previewViewerResolver: previewViewerResolver,
                previewAssetResolver: previewAssetResolver,
                onOpenInspector: onOpenInspector,
                onOpenAsset: onOpenAsset
            )
        }
    }
}

struct UIPreviewCardView: View {
    let model: UIPreviewCardModel
    let conversationID: String?
    let previewViewerResolver: (any PreviewViewerResolver)?
    let previewAssetResolver: (any PreviewAssetResolver)?
    let onOpenInspector: (String) -> Void
    let onOpenAsset: (AgentAssetRef) -> Void

    @StateObject private var viewer = UIPreviewViewerModel()
    @StateObject private var fallback = UIPreviewFallbackModel()
    @State private var contentRules: WKContentRuleList?
    @State private var rulesReady = false

    private var loadKey: String {
        "\(model.id)|\(conversationID ?? "unbound")"
    }

    private var viewerHeight: CGFloat {
        CGFloat(min(max(model.minHeight ?? 360, 260), 560))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            facts
            if model.isInteractiveReady {
                viewerArea
            } else if let text = model.fallbackText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            fallbackArea
            actions
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .task(id: loadKey) {
            if !rulesReady {
                contentRules = await Self.compileContentRules()
                rulesReady = true
            }
            if model.isInteractiveReady {
                await viewer.load(
                    sessionID: conversationID,
                    artifactID: model.artifactID,
                    revision: model.revision,
                    resolver: previewViewerResolver
                )
            }
            await fallback.load(
                sessionID: conversationID,
                artifactID: model.artifactID,
                revision: model.revision,
                assetID: model.fallback.assetID,
                expectedSHA256: model.fallback.sha256,
                resolver: previewAssetResolver
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.isAdaptation
                    ? "rectangle.on.rectangle"
                    : "sparkle.magnifyingglass")
                    .font(.caption)
                Text(model.modeLabel)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(model.statusLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor)
            }
            .foregroundStyle(.secondary)

            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch model.tone {
        case "success": return .green
        case "danger": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 3) {
            fact("Artifact", "\(model.artifactID) · r\(model.revision)")
            fact("Revision SHA-256", model.revisionSHA256)
            if let lineage = model.lineage {
                fact("Layout", "\(lineage.layoutArtifactID) · r\(lineage.layoutRevision)")
                fact("Layout SHA-256", lineage.layoutRevisionSHA256)
                fact("Source asset", lineage.sourceAssetID)
                fact("Source SHA-256", lineage.sourceAssetSHA256)
                fact("Evidence SHA-256", lineage.evidenceSHA256 ?? "none")
                fact("Target / state", "\(lineage.target) / \(lineage.state)")
                fact(
                    "Target matrix",
                    ([lineage.targetMatrixID] + lineage.targetMatrixTargets).joined(separator: " · ")
                )
                fact(
                    "Approval",
                    lineage.approvalEvidenceRef.map {
                        "\(lineage.approvalState) · \($0)"
                    } ?? lineage.approvalState
                )
            } else {
                Text("Explore Preview — standalone, with no layout lineage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Viewer

    @ViewBuilder
    private var viewerArea: some View {
        switch viewer.phase {
        case .idle, .loading:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing interactive preview…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: viewerHeight)
        case .ready(let html):
            Group {
                if let contentRules {
                    UIPreviewViewerRepresentable(html: html, contentRules: contentRules)
                } else {
                    Color.clear
                }
            }
            .frame(height: viewerHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .failed(let code):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Preview render failed (\(code)). Showing the fallback below.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Retry") {
                    Task {
                        await viewer.load(
                            sessionID: conversationID,
                            artifactID: model.artifactID,
                            revision: model.revision,
                            resolver: previewViewerResolver,
                            force: true
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Fallback

    @ViewBuilder
    private var fallbackArea: some View {
        switch fallback.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        case .ready(let image):
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(fallbackCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        case .failed:
            Text("Fallback image unavailable.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var fallbackCaption: String {
        var parts = [model.fallback.displayName]
        if let width = model.fallback.width, let height = model.fallback.height {
            parts.append("\(width) × \(height)")
        }
        if let sha = model.fallback.sha256 {
            parts.append(sha)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Lineage Inspector") {
                onOpenInspector(model.callID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let layoutJSON = model.layoutJSON {
                Button("layout.json") { onOpenAsset(layoutJSON) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let evidenceJSON = model.evidenceJSON {
                Button("evidence.json") { onOpenAsset(evidenceJSON) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Content rules

    @MainActor
    private static func compileContentRules() async -> WKContentRuleList? {
        let identifier = "agentkit-preview-native-v1"
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: ConversationWebPreviewSecurity.networkBlockRulesJSON
            ) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }
}

// MARK: - Viewer state

@MainActor
final class UIPreviewViewerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var loadID = UUID()
    private var currentRequest: LoadRequest?

    private struct LoadRequest: Equatable {
        let sessionID: String
        let artifactID: String
        let revision: Int
    }

    func load(
        sessionID: String?,
        artifactID: String,
        revision: Int,
        resolver: (any PreviewViewerResolver)?,
        force: Bool = false
    ) async {
        guard let sessionID, !sessionID.isEmpty else {
            phase = .failed("preview_invalid_request")
            return
        }
        guard let resolver else {
            phase = .failed("preview_unsupported")
            return
        }
        let request = LoadRequest(
            sessionID: sessionID,
            artifactID: artifactID,
            revision: revision
        )
        if !force, request == currentRequest {
            switch phase {
            case .loading, .ready:
                return
            case .idle, .failed:
                break
            }
        }
        currentRequest = request
        let id = UUID()
        loadID = id
        phase = .loading
        do {
            let html = try await Self.resolveWithTimeout(
                sessionID: sessionID,
                artifactID: artifactID,
                revision: revision,
                resolver: resolver
            )
            guard loadID == id else { return }
            phase = .ready(html)
        } catch let error as ViewerTimeout {
            guard loadID == id else { return }
            phase = .failed(error.code)
        } catch {
            guard loadID == id else { return }
            phase = .failed(Self.errorCode(error))
        }
    }

    private struct ViewerTimeout: Error {
        let code = "preview_resolve_timeout"
    }

    private static func resolveWithTimeout(
        sessionID: String,
        artifactID: String,
        revision: Int,
        resolver: any PreviewViewerResolver
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let resource = try await resolver.resolve(PreviewViewerRequest(
                    sessionID: sessionID,
                    artifactID: artifactID,
                    revision: revision
                ))
                // The runtime-owned viewer is validated before any bytes reach
                // WebKit: CSP must be present and remote resources forbidden.
                return try ConversationWebPreviewSecurity.validateViewerDocument(resource.data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ViewerTimeout()
            }
            guard let first = try await group.next() else {
                throw ViewerTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? PreviewResourceError { return error.code }
        if let error = error as? PreviewHTTPError { return error.error.code }
        if let error = error as? RuntimeHTTPError {
            switch error {
            case .preview(let preview):
                return preview.error.code
            case .notFound:
                return "preview_artifact_missing"
            case .unexpectedStatus(let status, _):
                return "preview_http_\(status)"
            default:
                return "preview_render_failed"
            }
        }
        if let error = error as? ConversationWebPreviewSecurityError { return error.code }
        if let error = error as? PreviewArtifactError { return error.code }
        return "preview_render_failed"
    }
}

// MARK: - Fallback state

@MainActor
final class UIPreviewFallbackModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(UIImage)
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    private var currentRequest: LoadRequest?

    private struct LoadRequest: Equatable {
        let sessionID: String
        let artifactID: String
        let revision: Int
        let assetID: String
        let expectedSHA256: String?
    }

    func load(
        sessionID: String?,
        artifactID: String,
        revision: Int,
        assetID: String,
        expectedSHA256: String?,
        resolver: (any PreviewAssetResolver)?
    ) async {
        guard let sessionID, !sessionID.isEmpty, let resolver else {
            phase = .failed
            return
        }
        let request = LoadRequest(
            sessionID: sessionID,
            artifactID: artifactID,
            revision: revision,
            assetID: assetID,
            expectedSHA256: expectedSHA256
        )
        if request == currentRequest {
            switch phase {
            case .loading, .ready:
                return
            case .idle, .failed:
                break
            }
        }
        currentRequest = request
        phase = .loading
        do {
            let resource = try await resolver.resolveContent(PreviewAssetRequest(
                sessionID: sessionID,
                artifactID: artifactID,
                revision: revision,
                assetID: assetID
            ))
            if let expectedSHA256,
               Self.normalizedDigest(resource.sha256)
                   != Self.normalizedDigest(expectedSHA256) {
                phase = .failed
                return
            }
            guard let image = UIImage(data: resource.data) else {
                phase = .failed
                return
            }
            phase = .ready(image)
        } catch {
            phase = .failed
        }
    }

    private static func normalizedDigest(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "sha256:", with: "")
    }
}

// MARK: - WKWebView host

struct UIPreviewViewerRepresentable: UIViewRepresentable {
    let html: String
    let contentRules: WKContentRuleList

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(contentRules)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedHTML: String?

        func load(_ html: String, in webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isInitialLocalLoad = navigationAction.navigationType == .other
                && (url == nil || url?.scheme == "about")
            decisionHandler(isInitialLocalLoad ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

#endif
