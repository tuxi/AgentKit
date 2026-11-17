#if os(macOS)
import SwiftUI

/// The model list scrolls independently; reasoning controls stay reachable.
struct MacComposerModelPicker: View {
    @Bindable var vm: DraftComposerPanelViewModel
    let onClose: () -> Void
    @State private var showEfforts = false
    @State private var hoverEffort = false
    @State private var hoveredModel: String?
    @State private var scrollID: String?
    @FocusState private var focusedModel: String?

    init(vm: DraftComposerPanelViewModel, onClose: @escaping () -> Void) {
        self.vm = vm
        self.onClose = onClose
        _scrollID = State(initialValue: (vm.modelSettings.unifiedModels?.map(\.id) ?? vm.modelSettings.availableModelIDs).first(where: vm.isCurrentModel))
    }

    private var ids: [String] { vm.modelSettings.unifiedModels?.map(\.id) ?? vm.modelSettings.availableModelIDs }
    private var selectedID: String? { ids.first(where: vm.isCurrentModel) }
    private var efforts: [ModelReasoningEffort] {
        guard let id = selectedID else { return [] }
        return vm.modelSettings.availableReasoningEfforts(for: id)
    }
    private var effectiveEffort: ModelReasoningEffort? {
        guard let id = selectedID else { return nil }
        return vm.effectiveReasoningEffort(for: id, supported: efforts)
    }
    private var listHeight: CGFloat { min(308, CGFloat(max(1, ids.count)) * 52) }

    var body: some View {
        VStack(spacing: 0) {
            Text(vm.isDraft ? "模型 · 新任务" : "模型 · 此对话")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(ids, id: \.self) { id in
                        modelRow(id).id(id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .frame(height: listHeight)
            .scrollPosition(id: $scrollID, anchor: .center)
            .task(id: selectedID) {
                // Apply the initial position once the popover has a viewport.
                await Task.yield()
                focusedModel = selectedID ?? ids.first
                scrollID = selectedID
            }
            .onChange(of: focusedModel) { _, id in if let id { scrollID = id } }
            .onChange(of: selectedID) { _, id in
                showEfforts = false
                focusedModel = id
                scrollID = id
            }
            Divider().padding(.horizontal, 16)
            Button { showEfforts.toggle() } label: {
                HStack(spacing: 8) {
                    Text("Effort")
                    Spacer(minLength: 12)
                    Text(effectiveEffort?.name ?? "默认").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 36)
                .contentShape(Rectangle())
                .background(showEfforts || hoverEffort ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .disabled(efforts.isEmpty)
            .onHover { hoverEffort = $0 }
            .accessibilityIdentifier("composer.effort")
            .help(efforts.isEmpty ? "此模型没有可选的推理强度" : "选择当前模型的推理强度")
            .popover(isPresented: $showEfforts, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                if let id = selectedID {
                    MacComposerEffortPicker(values: efforts, selected: effectiveEffort,
                        defaultValue: vm.modelSettings.descriptor(for: id)?.reasoningEffort,
                        onSelect: { value in
                            if let value { vm.applyReasoningEffort(value, for: id) }
                            else { vm.resetReasoningEffort(for: id) }
                            showEfforts = false
                            onClose()
                        })
                }
            }
        }
        .frame(width: 304)
        .padding(.bottom, 3)
        .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(1); return .handled }
        .onKeyPress(.leftArrow) {
            guard !efforts.isEmpty else { return .ignored }
            showEfforts = true; return .handled
        }
        .onKeyPress(.return) {
            guard let id = focusedModel else { return .ignored }
            select(id); return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func modelRow(_ id: String) -> some View {
        Button { select(id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.modelSettings.displayName(for: id))
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if let model = vm.modelSettings.descriptor(for: id) {
                        Text(model.providerDisplayName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if vm.isCurrentModel(id) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).frame(height: 48)
            .contentShape(Rectangle())
            .background(hoveredModel == id || focusedModel == id ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focused($focusedModel, equals: id)
        .focusEffectDisabled()
        .onHover { hoveredModel = $0 ? id : nil }
        .accessibilityValue(vm.isCurrentModel(id) ? "已选择" : "")
        .help(vm.modelSettings.selectionDisplayName(for: id))
    }

    private func select(_ id: String) {
        vm.selectModel(id, reasoningEffort: nil)
        onClose()
    }
    private func moveFocus(_ offset: Int) {
        guard !ids.isEmpty else { return }
        let current = focusedModel.flatMap { ids.firstIndex(of: $0) }
            ?? selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusedModel = ids[min(ids.count - 1, max(0, current + offset))]
    }
}

struct MacComposerEffortPicker: View {
    let values: [ModelReasoningEffort]
    let selected: ModelReasoningEffort?
    let defaultValue: ModelReasoningEffort?
    let onSelect: (ModelReasoningEffort?) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("提高推理强度可能增加响应时间与用量。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
            effortRow(nil)
            Divider().padding(.horizontal, 10)
            ForEach(values) { value in effortRow(value) }
        }
        .padding(6).frame(width: 264)
    }

    private func effortRow(_ value: ModelReasoningEffort?) -> some View {
        let id = value?.rawValue ?? "default"
        return Button { onSelect(value) } label: {
            HStack(spacing: 8) {
                Text(value?.name ?? "默认")
                if let value, value == defaultValue {
                    Text("默认").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.3)))
                }
                Spacer()
                if selected == value { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
            .background(hovered == id ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
        .accessibilityValue(selected == value ? "已选择" : "")
    }
}
#endif
