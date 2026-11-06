import SwiftUI

struct BackgroundContinuationBanner: View {
    let status: BackgroundContinuationStatus
    let isCancelling: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.state == "needs_attention" ? "exclamationmark.circle" : "hourglass")
                .foregroundStyle(status.state == "needs_attention" ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(isCancelling ? "正在停止本轮" : status.title).font(.callout.weight(.medium))
                Text(status.state == "needs_attention"
                     ? "状态已保留，可发送新消息或停止本轮。"
                     : "结果就绪后自动继续，也可发送新消息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("停止本轮", action: stop)
                .disabled(isCancelling)
                .help("停止本轮的自动继续；后台进程仍可在任务窗口中单独停止")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }
}
