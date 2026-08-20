import SwiftUI

struct BranchCreateSheet: View {
    @Binding var name: String
    let isCreating: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("创建并检出分支")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Text("分支名称")
                .font(.headline)
            TextField("feature/my-branch", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCreate)
            Text("将从当前分支创建，并立即切换到新分支。工作区必须没有未提交修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("关闭", action: onCancel)
                Button("创建并检出", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .overlay {
            if isCreating { ProgressView().controlSize(.small) }
        }
    }
}
