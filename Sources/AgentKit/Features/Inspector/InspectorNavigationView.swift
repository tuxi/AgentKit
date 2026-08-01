//
//  InspectorNavigationView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import SwiftUI

/// 带 NavigationStack 的 Inspector 容器。
///
/// 替代单层 `InspectorView(selection:)` 的平铺切换模式，
/// 提供 path-based 多层导航：tool call → tool result → file preview/diff。
///
/// ## 使用方式
///
/// ### iOS (Sheet)
/// ```swift
/// .sheet(isPresented: $showInspector) {
///     InspectorNavigationView(
///         initialSelection: store.inspectorSelection,
///         fileProvider: fileContentProvider
///     )
///     .presentationDetents([.medium, .large])
///     .environment(store)
/// }
/// ```
///
/// ### macOS / iPad (inspector column)
/// ```swift
/// .inspector(isPresented: $store.isInspectorPresented) {
///     InspectorNavigationView(
///         initialSelection: store.inspectorSelection,
///         fileProvider: fileProvider
///     )
///     .environment(store)
/// }
/// ```
public struct InspectorNavigationView: View {

    /// 初始 inspector 选择（等同于现有 InspectorSelection）
    let initialSelection: InspectorSelection?

    /// 文件内容提供者（用于 filePreview / diffPreview destination）
    let fileProvider: (any FileContentProvider)?

    @State private var ownedPath = InspectorPathState()

    /// 外部传入时，导航历史由 conversation/tab session 持有。
    private let externalPath: InspectorPathState?

    public init(
        initialSelection: InspectorSelection?,
        fileProvider: (any FileContentProvider)? = nil,
        pathState: InspectorPathState? = nil
    ) {
        self.initialSelection = initialSelection
        self.fileProvider = fileProvider
        self.externalPath = pathState
    }

    public var body: some View {
        InspectorNavigationContent(
            initialSelection: initialSelection,
            fileProvider: fileProvider,
            path: externalPath ?? ownedPath
        )
    }
}

private struct InspectorNavigationContent: View {
    let initialSelection: InspectorSelection?
    let fileProvider: (any FileContentProvider)?
    let path: InspectorPathState

    var body: some View {
        @Bindable var path = path

        NavigationStack(path: $path.path) {
            InspectorView(selection: initialSelection)
                .navigationDestination(
                    for: InspectorDestination.self
                ) { destination in
                    destinationView(for: destination)
                }
        }
        .environment(\.inspectorPathState, path)
        .onChange(of: initialSelection) { _, _ in
            path.popToRoot()
        }
        .onAppear {
            path.isActive = true
        }
        .onDisappear {
            path.isActive = false
        }
    }

    // MARK: - Destination Views

    @ViewBuilder
    private func destinationView(for destination: InspectorDestination) -> some View {
        switch destination {
        case .toolResult(let callID):
            ToolResultDetailView(callID: callID)

        case .filePreview(let filePath):
            filePreviewDestination(filePath: filePath)

        case .diffPreview(let filePath, let baseRef):
            diffPreviewDestination(filePath: filePath, baseRef: baseRef)

        case .agentStateDetail:
            AgentStateDetailView()

        case .assetDetail(let payload):
            AssetPreviewInspectorView(payload: payload)
        }
    }

    @ViewBuilder
    private func filePreviewDestination(filePath: String) -> some View {
        if let provider = fileProvider {
            FilePreviewPlaceholder(
                filePath: filePath,
                provider: provider
            )
        } else {
            ContentUnavailableView(
                "文件预览不可用",
                systemImage: "doc.text",
                description: Text("未提供 FileContentProvider")
            )
        }
    }

    @ViewBuilder
    private func diffPreviewDestination(filePath: String, baseRef: String?) -> some View {
        if let provider = fileProvider {
            DiffDetailView(
                filePath: filePath,
                baseRef: baseRef,
                provider: provider
            )
        } else {
            ContentUnavailableView(
                "Diff 对比不可用",
                systemImage: "arrow.left.arrow.right",
                description: Text("未提供 FileContentProvider")
            )
        }
    }
}

// MARK: - File Preview Placeholder

/// 文件预览占位视图。
/// 当 FileViewerKit 的 FilePreviewHost 接入后替换此实现。
private struct FilePreviewPlaceholder: View {
    let filePath: String
    let provider: any FileContentProvider

    @State private var content: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载文件...")
            } else if let content {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "无法加载文件",
                    systemImage: "doc.text"
                )
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        isLoading = true
        defer { isLoading = false }
        content = try? await provider.content(for: filePath)
    }
}
