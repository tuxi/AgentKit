#if os(macOS)
import SwiftUI
import AppKit
import ImageIO
import QuickLook
import UniformTypeIdentifiers

/// Semantic appearance values stay dynamic so changing themes never replaces the editor.
enum MacComposerStyle {
    static let surface = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.65)
    static let hover = Color(nsColor: .quaternaryLabelColor).opacity(0.12)
    static let radius: CGFloat = 16
    static let attachmentSize = CGSize(width: 72, height: 96)
}

struct MacComposerLayoutBudget {
    let availableHeight: CGFloat
    let hasAttachments: Bool
    let hasIssue: Bool
    var collapseAttachments: Bool { hasAttachments && availableHeight < 380 }
    var attachmentScale: CGFloat { availableHeight < 500 ? 0.75 : 1 }
    var attachmentHeight: CGFloat { !hasAttachments ? 0 : (collapseAttachments ? 40 : 96 * attachmentScale + 24) }
    var editorMaximum: CGFloat { max(48, min(360, availableHeight * 0.45) - attachmentHeight - 24 - (hasIssue ? 32 : 0)) }
}

struct MacComposerSurface: View {
    @Environment(\.undoManager) private var undoManager
    @Environment(\.sessionRailOpenSettings) private var openSettings
    @Bindable var vm: DraftComposerPanelViewModel
    let placeholder: String
    @State private var suggestion: ComposerSuggestion?
    @State private var dismissedSuggestionTurn: String?
    @State private var showModelPicker = false
    @State private var showPermissionPicker = false
    @State private var focused = false
    @State private var dragTargeted = false
    @State private var showAttachments = false
    @State private var availableHeight: CGFloat = 800
    @State private var permissions: WorkspacePermissions?
    @State private var permissionError: String?
    @State private var permissionUpdating = false

    private var workspacePath: String? {
        vm.isDraft ? vm.workspaceStore.draft?.workspace?.url.path : vm.conversationViewModel?.workspacePermissionPath
    }

    private var suggestionSource: String? {
        guard !vm.isDraft, !vm.isTurnRunning,
              let turn = vm.conversationViewModel?.snapshot.turns.last,
              !turn.isLive, turn.finishedAt != nil else { return nil }
        return turn.runtimeTurnID
    }

    private var visibleSuggestion: String? {
        guard vm.text.isEmpty, vm.tokens.isEmpty, vm.attachments.isEmpty, vm.fileReferences.isEmpty,
              !vm.isSubmitting, let suggestion, suggestion.turnID == suggestionSource,
              suggestion.turnID != dismissedSuggestionTurn, !suggestion.text.isEmpty else { return nil }
        return suggestion.text
    }

    private var submissionIssue: String? {
        guard let issue = vm.workspaceStore.composerSubmissionIssue, issue.key == vm.loadedStateKey else { return nil }
        return issue.message
    }

    private var modelDisplayTitle: String {
        guard let id = vm.selectedModel?.model else { return "选择模型" }
        return vm.modelSettings.descriptor(for: id)?.displayName ?? vm.modelSettings.displayName(for: id)
    }

    private var layoutBudget: MacComposerLayoutBudget {
        MacComposerLayoutBudget(availableHeight: availableHeight,
            hasAttachments: !vm.attachments.isEmpty || !vm.fileReferences.isEmpty,
            hasIssue: vm.attachmentIssue != nil || vm.imageInputIssue != nil || vm.referenceLimitIssue != nil || submissionIssue != nil || vm.trimmed.count > 100_000)
    }
    private var editorMaximum: CGFloat { layoutBudget.editorMaximum }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                if layoutBudget.hasAttachments {
                    if layoutBudget.collapseAttachments {
                        HStack {
                            Button("附件与文件引用 · \(vm.attachments.count + vm.fileReferences.count)") { showAttachments = true }
                                .buttonStyle(.plain).font(.caption)
                                .popover(isPresented: $showAttachments) { attachmentStrip(scale: 1).frame(width: 360).padding(12) }
                            Spacer()
                        }.frame(height: 28).padding(.horizontal, 14).padding(.top, 12)
                    } else {
                        attachmentStrip(scale: layoutBudget.attachmentScale)
                            .padding(.horizontal, 14).padding(.top, 12)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { vm.pickAttachments() } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(AgentKitLocalized.string("composer.add_attachment"))
                    .accessibilityLabel(AgentKitLocalized.string("composer.add_attachment"))
                    .disabled(vm.isSubmitting || vm.attachments.count + vm.fileReferences.count >= vm.maxFilesCount || !vm.workspaceStore.canSelectUserAssets)

                    MacComposerTextView(text: $vm.text, height: $vm.composerHeight,
                        placeholder: placeholder, isEnabled: !vm.isSubmitting,
                        minHeight: 24, maxHeight: editorMaximum,
                        onSend: { vm.send() },
                        onFileDrop: { urls in
                            guard !vm.isSubmitting, vm.workspaceStore.canStageLocalUserAssets else { return false }
                            vm.handleDroppedImages(urls)
                            return true
                        }, onDropTargetChange: { dragTargeted = $0 }, suggestionText: visibleSuggestion,
                        onDismissSuggestion: { dismissedSuggestionTurn = suggestionSource },
                        completionScope: workspacePath ?? "", onImagePaste: { vm.importPastedImage($0) }, tokens: $vm.tokens,
                        queryCompletions: { kind, query, revision in
                            try await vm.workspaceStore.client.composerQuery(ComposerQuery(
                                sessionID: vm.isDraft ? nil : vm.sessionID,
                                workspacePath: vm.isDraft ? workspacePath : nil,
                                kind: kind, query: query, revision: revision))
                        }, resolveReference: { item in
                            guard let sourceID = item.sessionID else { throw RuntimeHTTPError.unsupported }
                            let scope = ComposerQuery(sessionID: vm.isDraft ? nil : vm.sessionID,
                                workspacePath: vm.isDraft ? workspacePath : nil, kind: "reference", query: "", revision: 0)
                            let snapshot = try await vm.workspaceStore.client.composerReference(scope, sourceSessionID: sourceID)
                            var resolved = item
                            resolved.label = snapshot.label
                            resolved.insertText = snapshot.label
                            resolved.contextText = snapshot.contextText
                            resolved.contextRevision = snapshot.historyRevision
                            return resolved
                        }, onCompletionAction: { action in
                            if action == "model" { showModelPicker = true }
                            if action == "permissions" { showPermissionPicker = true }
                            if action == "skills" { openSettings?(.skills) }
                        }, onFocusChange: { focused = $0 })
                        .frame(height: min(vm.composerHeight, editorMaximum))
                    primaryAction
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                if let issue = vm.attachmentIssue ?? vm.imageInputIssue ?? vm.referenceLimitIssue ?? submissionIssue {
                    HStack {
                        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(1).help(issue)
                        Spacer()
                        if vm.imageInputIssue == nil && vm.referenceLimitIssue == nil {
                            Button("关闭") { vm.attachmentIssue = nil; vm.workspaceStore.composerSubmissionIssue = nil }.buttonStyle(.plain).font(.caption)
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 10)
                }
                if vm.trimmed.count > 100_000 {
                    Text("内容超过 100,000 字符，请缩短后发送。")
                        .lineLimit(1).help("内容超过 100,000 字符，请缩短后发送。")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            .background(MacComposerStyle.surface, in: RoundedRectangle(cornerRadius: MacComposerStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: MacComposerStyle.radius)
                    .strokeBorder((focused || dragTargeted) ? Color.accentColor.opacity(0.65) : MacComposerStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if dragTargeted {
                    RoundedRectangle(cornerRadius: MacComposerStyle.radius).fill(Color.accentColor.opacity(0.05))
                        .overlay { Text("添加图片或引用文件").font(.caption).foregroundStyle(Color.accentColor).padding(6).background(MacComposerStyle.surface, in: Capsule()) }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragTargeted) { providers in
                guard !vm.isSubmitting else { return false }
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                                let url: URL?
                                if let value = value as? URL { url = value }
                                else if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                                else { url = nil }
                                continuation.resume(returning: url)
                            }
                        }
                        if let url, url.isFileURL { urls.append(url) }
                    }
                    if !urls.isEmpty { vm.handleDroppedImages(urls) }
                }
                return true
            }
            .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
            .background {
                WindowHeightReader { availableHeight = $0 }
            }

            HStack(spacing: 8) {
                if vm.isDraft {
                    WorkspaceChipBar(compactComposer: true, forceCompactComposer: true, iconOnlyComposer: vm.contentWidth < 480)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                } else { Spacer(minLength: 0) }
                environmentControls.fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 12))
            .frame(minHeight: 28)
            .disabled(vm.isSubmitting)
        }
        .task(id: suggestionSource) {
            suggestion = nil
            guard let turnID = suggestionSource, let sessionID = vm.sessionID else { return }
            guard let value = try? await vm.workspaceStore.client.composerSuggestion(sessionID: sessionID, turnID: turnID),
                  !Task.isCancelled, vm.sessionID == sessionID, suggestionSource == turnID else { return }
            suggestion = value
        }
        .task(id: workspacePath) { await loadPermissions() }
        .onChange(of: vm.tokens) { _, _ in vm.persistCurrentText() }
        .popover(isPresented: $showPermissionPicker) {
            VStack(alignment: .leading, spacing: 10) {
                Text("工作区权限").font(.headline)
                ForEach(permissions?.available ?? [], id: \.self) { mode in
                    Button(vm.approvalModeTitle(mode)) { updatePermission(mode); showPermissionPicker = false }
                        .buttonStyle(.plain)
                }
                Text("下一轮起生效 · 作用于工作区全部对话").font(.caption).foregroundStyle(.secondary)
                if let permissionError { Text(permissionError).font(.caption).foregroundStyle(.red) }
            }.padding(16).frame(minWidth: 260)
        }
    }

    private func attachmentStrip(scale: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(vm.attachments) { attachment in
                    MacComposerAttachment(attachment: attachment,
                        resolver: vm.workspaceStore.userAssetDraftPreviewResolver,
                        onRemove: { vm.removeAttachmentWithUndo(attachment.id, manager: undoManager) },
                        onRetry: { vm.retryAttachment(attachment.id) })
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 72 * scale, height: 96 * scale, alignment: .topLeading)
                        .clipped()
                }
                ForEach(vm.fileReferences) { reference in
                    MacComposerPathCard(reference: reference) {
                        vm.removeFileReferenceWithUndo(reference.id, manager: undoManager)
                    }
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: 72 * scale, height: 96 * scale, alignment: .topLeading)
                    .clipped()
                }
            }.padding(.vertical, 2)
        }
        .frame(height: 96 * scale + 8)
        .disabled(vm.isSubmitting)
    }

    private var primaryAction: some View {
        Button {
            if vm.isTurnRunning { vm.stop() } else { vm.send() }
        } label: {
            Group {
                if vm.isSubmitting { ProgressView().controlSize(.small) }
                else { Image(systemName: vm.isTurnRunning ? "stop.fill" : "return") }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!vm.isTurnRunning && !vm.canSend)
        .accessibilityLabel(AgentKitLocalized.string(vm.isTurnRunning ? "composer.stop" : "composer.send"))
        .help(AgentKitLocalized.string(vm.isTurnRunning ? "composer.stop" : "composer.send"))
    }

    private var environmentControls: some View {
        HStack(spacing: 12) {
            modelMenu
            permissionMenu
            if vm.sessionID != nil {
                Button { vm.isContextPresented = true; vm.refreshContext() } label: {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                        Circle().trim(from: 0, to: vm.contextRingProgress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 12, height: 12).frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.contextButtonAccessibilityLabel)
                .popover(isPresented: $vm.isContextPresented, arrowEdge: .bottom) {
                    ContextWindowDetailView(snapshot: vm.contextSnapshot, isLoading: vm.isContextLoading,
                        errorMessage: vm.contextError, onRefresh: { vm.refreshContext() },
                        onCompact: { vm.compactContext() }, isCompacting: vm.isContextCompacting,
                        canCompact: !vm.isTurnRunning && !vm.isSubmitting,
                        compactionMessage: vm.contextCompactionMessage)
                        .frame(width: 360)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var modelMenu: some View {
        Button { showModelPicker = true } label: {
            HStack(spacing: 6) {
                Text(modelDisplayTitle).lineLimit(1).truncationMode(.middle)
                if vm.contentWidth >= 540, let id = vm.selectedModel?.model,
                   let effort = vm.effectiveReasoningEffort(for: id, supported: vm.modelSettings.availableReasoningEfforts(for: id)) {
                    Text(effort.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .frame(width: vm.contentWidth > 0 ? min(180, max(64, vm.contentWidth * 0.28)) : 180, height: 28, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(vm.modelButtonTitle)
        .disabled(vm.modelSettings.availableModelIDs.isEmpty)
        .accessibilityLabel(AgentKitLocalized.string("composer.select_model"))
        .popover(isPresented: $showModelPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            MacComposerModelPicker(vm: vm, onClose: { showModelPicker = false })
        }
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(permissions?.available ?? [], id: \.self) { mode in
                Button { updatePermission(mode) } label: {
                    HStack { Text(vm.approvalModeTitle(mode)); if mode == permissions?.mode { Image(systemName: "checkmark") } }
                }
            }
            Divider()
            Text("下一轮起生效 · 作用于工作区全部对话")
            if let permissionError { Text(permissionError) }
        } label: {
            Text(permissions?.mode.capitalized ?? "权限").lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .disabled(permissions == nil || permissionUpdating)
        .help(permissionError ?? "工作区权限")
    }

    private func loadPermissions() async {
        permissions = nil; permissionError = nil
        guard let path = workspacePath else { return }
        do {
            let value = try await vm.workspaceStore.client.getWorkspacePermissions(workspacePath: path)
            guard !Task.isCancelled, workspacePath == path else { return }
            permissions = value
        } catch {
            guard !Task.isCancelled, workspacePath == path else { return }
            permissionError = error.localizedDescription
        }
    }

    private func updatePermission(_ mode: String) {
        guard let path = workspacePath, !permissionUpdating else { return }
        permissionUpdating = true
        Task {
            defer { permissionUpdating = false }
            do {
                let value = try await vm.workspaceStore.client.setWorkspacePermissions(workspacePath: path, mode: mode)
                guard workspacePath == path else { return }
                permissions = value; permissionError = nil
            } catch { if workspacePath == path { permissionError = error.localizedDescription } }
        }
    }
}

private struct MacComposerPathCard: View {
    let reference: ComposerFileReference
    let onRemove: () -> Void
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reference.displayPath).font(.system(size: 11)).lineLimit(4).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(reference.typeLabel).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(8).frame(width: 72, height: 96)
        .background(MacComposerStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(MacComposerStyle.border) }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.secondary, MacComposerStyle.surface) }
                    .buttonStyle(.plain).padding(3).accessibilityLabel("移除文件引用")
            }
        }
        .onHover { hovering = $0 }.help(reference.path)
        .contextMenu { Button("移除引用", action: onRemove) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reference.path)
        .accessibilityAction(named: "移除引用", onRemove)
    }
}

private struct MacComposerAttachment: View {
    let attachment: DraftAttachmentReference
    let resolver: (any UserAssetDraftPreviewResolving)?
    let onRemove: () -> Void
    let onRetry: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var previewURL: URL?
    @State private var resolvedPreviewURL: URL?

    private var path: String {
        guard let url = URL(string: attachment.resourceURI), url.isFileURL else { return attachment.displayName }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(path).font(.system(size: 11)).lineLimit(4).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text((attachment.displayName as NSString).pathExtension.uppercased())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }
            .frame(width: 72, height: 96)
            .background(MacComposerStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(attachment.state == .failed ? Color.red.opacity(0.65) : MacComposerStyle.border) }
            if hovering {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.secondary, MacComposerStyle.surface) }
                    .buttonStyle(.plain).padding(3).accessibilityLabel("移除 \(attachment.displayName)")
            }
            if attachment.state == .preparing {
                ProgressView().controlSize(.small).padding(6)
            }
            if attachment.state == .failed {
                Button(action: onRetry) { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").padding(6) }
                    .buttonStyle(.plain).help(attachment.failure?.message ?? "重新准备附件")
            }
        }
        .frame(width: 72, height: 96)
        .onHover { hovering = $0 }
        .help(path)
        .contextMenu { Button("移除附件", action: onRemove); if attachment.state == .failed { Button("重试", action: onRetry) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.displayName)
        .accessibilityAction(named: "移除附件", onRemove)
        .onTapGesture { previewURL = resolvedPreviewURL }
        .quickLookPreview($previewURL)
        .task(id: attachment.resourceURI) {
            guard let url = await MacComposerImagePreview.url(for: attachment, resolver: resolver), !Task.isCancelled else { return }
            resolvedPreviewURL = url
            let result = await MacComposerImagePreview.thumbnail(at: url)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private final class ComposerWindowObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private struct WindowHeightReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> HeightView { HeightView(onChange: onChange) }
    func updateNSView(_ view: HeightView, context: Context) { view.onChange = onChange; view.report() }
    final class HeightView: NSView {
        var onChange: (CGFloat) -> Void
        private var observer: ComposerWindowObservation?
        private var lastHeight: CGFloat = 0
        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer = nil
            observer = window.map { window in
                ComposerWindowObservation(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }
        func report() {
            guard let height = window?.contentView?.bounds.height, abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            Task { @MainActor [weak self] in self?.onChange(height) }
        }
    }
}
/// Dropped images use file URLs and do not require the optional host resolver.
/// Decode only a bounded thumbnail, off the main actor.
enum MacComposerImagePreview {
    static func url(for attachment: DraftAttachmentReference, resolver: (any UserAssetDraftPreviewResolving)?) async -> URL? {
        if let resolved = try? await resolver?.previewURL(for: attachment), resolved.isFileURL { return resolved }
        guard let source = URL(string: attachment.resourceURI), source.isFileURL else { return nil }
        return source
    }

    static func thumbnail(at url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 288,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: .zero)
        }.value
    }
}
#endif
