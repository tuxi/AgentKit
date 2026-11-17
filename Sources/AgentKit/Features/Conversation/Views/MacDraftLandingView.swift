#if os(macOS)
import AppKit
import SwiftUI

/// Receives only the free space above the pinned composer, including after a
/// terminal/sidebar resize. A low window scrolls this region, never the editor.
struct MacDraftLandingView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.composerDiagnostic) private var connectionDiagnostic
    @Environment(\.composerRecheckEnvironment) private var recheck
    @Environment(\.composerOpenModelSettings) private var openModels
    @Environment(\.sessionRailOpenSettings) private var openSettings
    @State private var dismissedDiagnostic: String?
    @State private var expandedDiagnostic: String?
    @State private var checking = false
    @State private var diagnosticHeight: CGFloat = 120

    private var diagnostic: ComposerDiagnostic? {
        if let connectionDiagnostic { return connectionDiagnostic }
        if case .failed(let message) = store.draft?.state {
            return ComposerDiagnostic(id: "draft:\(store.draft?.id.uuidString ?? ""):\(message)",
                title: "任务准备失败", message: "草稿已保留，检查原因后可在输入框中重新发送。",
                details: CommandDisplayRedactor.redact(message), destination: .environment, blocksSubmission: false)
        }
        return nil
    }

    var body: some View {
        GeometryReader { page in
          VStack(spacing: 0) {
            if let diagnostic, diagnostic.id != dismissedDiagnostic {
                ScrollView {
                    diagnosticCard(diagnostic)
                        .padding(.horizontal, MacConversationLayout.contentInset)
                        .frame(maxWidth: MacConversationLayout.shellMaximumWidth)
                        .padding(.horizontal, MacConversationLayout.outerInset)
                        .padding(.top, 12)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { diagnosticHeight = $0 }
                }
                .frame(height: min(diagnosticHeight, max(64, page.size.height * 0.5)))
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        MacDraftWorkspaceCard()
                            .frame(maxWidth: 320)
                            .padding(.horizontal, 20)
                        Spacer(minLength: 0)
                            .frame(height: max(0, geometry.size.height * 0.08))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 16)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
          }
        }
        .onChange(of: diagnostic?.id) { _, value in
            expandedDiagnostic = nil
            if value == nil { dismissedDiagnostic = nil }
        }
        .accessibilityIdentifier("draft.landing")
    }

    private func diagnosticCard(_ item: ComposerDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).fontWeight(.medium)
                    Text(item.message).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { dismissedDiagnostic = item.id } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help("关闭提示")
            }
            HStack(spacing: 12) {
                Button(item.destination == .models ? "打开模型设置" : "打开环境设置") {
                    if item.destination == .models { openModels?() }
                    else { openSettings?(.environment) }
                }
                .disabled(item.destination == .models ? openModels == nil : openSettings == nil)
                Button(checking ? "检查中…" : "重新检查") { check() }
                    .disabled(checking)
                Spacer(minLength: 0)
                Button(expandedDiagnostic == item.id ? "收起详情" : "详情") {
                    expandedDiagnostic = expandedDiagnostic == item.id ? nil : item.id
                }.buttonStyle(.plain)
            }
            .controlSize(.small)
            if expandedDiagnostic == item.id {
                ScrollView {
                    Text(item.details).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.details, forType: .string)
                }.buttonStyle(.plain).font(.caption)
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.65)) }
        .accessibilityIdentifier("draft.diagnostic")
    }

    private func check() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            await recheck?()
            await store.refreshRuntimeState()
        }
    }
}
#endif
