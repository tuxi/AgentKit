#if os(macOS)
import SwiftUI

enum SupplementStatusPresentation {
    static func description(_ record: TextSupplementDelivery, activeTurnID: String?) -> String {
        switch record.state {
        case "pending_apply":
            return record.request.expectedTurnID == activeTurnID
                ? "已接收，等待当前任务在下一次处理时加入。"
                : "目标轮已结束或切换，尚无应用回执。请查询最新状态。"
        case "cancelled": return "目标任务已取消，这条补充未加入任务。"
        case "failed": return "这条补充未能应用，可以放回草稿重新处理。"
        case "rejected": return "服务端拒绝了这次提交，原文已保留。"
        case "applied": return "已加入目标任务。"
        default: return "投递状态尚未确认，请查询原请求。"
        }
    }

    static func canRestore(_ state: String) -> Bool {
        ["cancelled", "failed", "rejected"].contains(state)
    }
}

struct MacSupplementStatusPanel: View {
    let conversation: ConversationViewModel
    @Bindable var vm: DraftComposerPanelViewModel
    let sessionID: String
    @State private var querying = false
    @State private var restoredIDs: Set<String> = []
    @State private var queryFailed = false

    private var records: [TextSupplementDelivery] {
        conversation.composerSupplementRecords.filter { $0.state != "applied" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("补充消息").font(.headline)
                Spacer()
                Button("查询状态") { Task { await query() } }.disabled(querying)
            }
            if queryFailed {
                Text("查询未完成，保留现有状态，请稍后再试。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if records.isEmpty {
                Text("补充均已加入任务，可在对话中查看。").font(.callout)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(records, id: \.request.requestID) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.request.text).font(.callout).textSelection(.enabled)
                            Text(SupplementStatusPresentation.description(record,
                                activeTurnID: conversation.activeSupplementTurnID))
                                .font(.caption).foregroundStyle(.secondary)
                            if SupplementStatusPresentation.canRestore(record.state) {
                                Button(restoredIDs.contains(record.request.requestID) ? "已放回草稿" : "放回草稿") {
                                    guard vm.sessionID == sessionID else { return }
                                    vm.text += (vm.text.isEmpty ? "" : "\n\n") + record.request.text
                                    vm.persistCurrentText()
                                    restoredIDs.insert(record.request.requestID)
                                }
                                .disabled(restoredIDs.contains(record.request.requestID) || vm.isSubmitting || conversation.isArchived)
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14).frame(width: 340)
        .task { await query() }
    }

    private func query() async {
        guard !querying, conversation.conversation?.id == sessionID else { return }
        querying = true
        queryFailed = false
        defer { querying = false }
        do { try await conversation.recoverComposerSupplements() }
        catch { queryFailed = true }
    }
}
#endif
