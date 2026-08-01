//
//  InspectorWorkbenchView.swift
//  AgentKit
//
//  Created by Codex on 2026/8/1.
//

import SwiftUI

/// Inspector 的推荐主入口。
///
/// 无选中内容时展示稳定的五入口工作台；从时间线打开产物后，继续复用
/// `InspectorNavigationView` 或旧的 `InspectorView` 内容链路。
///
/// 第一阶段由宿主通过 `onOpenEntry` 接管入口动作。后续 tab/session 状态
/// 会收敛到工作台模型中，而不会继续扩充 `InspectorSelection`。
public struct InspectorWorkbenchView: View {
    public let selection: InspectorSelection?
    public let fileProvider: (any FileContentProvider)?
    public let usesNavigationStack: Bool
    public let onOpenEntry: (InspectorEntry) -> Void

    public init(
        selection: InspectorSelection?,
        fileProvider: (any FileContentProvider)? = nil,
        usesNavigationStack: Bool = true,
        onOpenEntry: @escaping (InspectorEntry) -> Void
    ) {
        self.selection = selection
        self.fileProvider = fileProvider
        self.usesNavigationStack = usesNavigationStack
        self.onOpenEntry = onOpenEntry
    }

    public var body: some View {
        Group {
            if selection == nil {
                InspectorLandingView(onOpenEntry: onOpenEntry)
            } else if usesNavigationStack {
                InspectorNavigationView(
                    initialSelection: selection,
                    fileProvider: fileProvider
                )
            } else {
                InspectorView(selection: selection)
            }
        }
    }
}

private struct InspectorLandingView: View {
    let onOpenEntry: (InspectorEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 4) {
                ForEach(InspectorEntry.allCases) { entry in
                    Button {
                        onOpenEntry(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.systemImage)
                                .frame(width: 20)

                            Text(entry.title)

                            Spacer(minLength: 24)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inspector.entry.\(entry.rawValue)")
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.landing")
    }
}

#Preview("Inspector Workbench Landing") {
    InspectorWorkbenchView(selection: nil) { _ in }
        .frame(width: 520, height: 640)
}
