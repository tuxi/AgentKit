#if os(macOS) && DEBUG
import SwiftUI

/// Explicit test surface; ordinary composer behavior remains unchanged.
struct TextSupplementDebugPanel: View {
    let viewModel: ConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var target: String?
    @State private var supported = false
    @State private var text = ""
    @State private var busy = false
    @State private var status = "正在检查服务端能力…"
    @State private var records: [TextSupplementDelivery] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("运行中补充 · 联调").font(.headline)
            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("目标轮次：\(target ?? "无运行中的轮次")").font(.caption).textSelection(.enabled)
            TextEditor(text: $text).font(.body).frame(height: 100).disabled(busy)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("提交补充") {
                    guard let target else { return }
                    let content = text
                    busy = true
                    Task {
                        do {
                            try await viewModel.submitTextSupplement(content, expectedTurnID: target)
                            status = "请求已返回，请查看下方服务端状态。"
                            text = ""
                        } catch { status = "提交未确认或被拒绝：\(error.localizedDescription)；请查询原请求状态。" }
                        records = viewModel.debugSupplementDeliveries()
                        busy = false
                    }
                }.disabled(!supported || target == nil || busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("查询恢复") {
                    busy = true
                    Task {
                        do { try await viewModel.debugRecoverSupplements(); status = "查询结束；未确认项保留原身份，不自动重发。" }
                        catch { status = "查询失败：\(error.localizedDescription)" }
                        records = viewModel.debugSupplementDeliveries()
                        busy = false
                    }
                }.disabled(busy || !supported)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(records, id: \.request.requestID) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.request.text).lineLimit(3)
                            Text("\(record.state) · \(record.request.requestID)").font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
            Text("pending_apply：等待加入上下文；applied：已加入上下文，不代表模型已理解。仅支持文本。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 560)
        .task {
            target = viewModel.debugSupplementTargetID
            supported = await viewModel.debugSupplementSupported()
            status = supported ? "服务端文本补充能力已开启。目标在打开面板时固定。" : "服务端尚未开启 user_supplement_text_v1。"
            records = viewModel.debugSupplementDeliveries()
        }
    }
}
#endif
