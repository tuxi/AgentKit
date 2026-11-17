#if os(macOS)
import AppKit
import SwiftUI

@MainActor @Observable
final class MacComposerCompletionState {
    var items: [ComposerCompletionItem] = []
    var selected = 0
    var message: String?
    var onSelect: ((ComposerCompletionItem) -> Void)?
}

struct MacComposerCompletionList: View {
    @Bindable var state: MacComposerCompletionState
    var width: CGFloat
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let message = state.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        Button { state.onSelect?(item) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(item.kind)).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label).font(.system(size: 13)).lineLimit(1)
                                    if !item.detail.isEmpty { Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(index == state.selected ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).id(item.id)
                    }
                }.padding(5)
            }
            .onChange(of: state.selected) { _, index in
                guard state.items.indices.contains(index) else { return }
                proxy.scrollTo(state.items[index].id)
            }
        }
        .frame(width: width, height: min(320, CGFloat(max(1, state.items.count)) * 49 + (state.message == nil ? 10 : 36)))
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func icon(_ kind: String) -> String {
        switch kind { case "directory": "folder"; case "conversation": "bubble.left"; case "file": "doc"; default: "command" }
    }
}

final class MacComposerCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
