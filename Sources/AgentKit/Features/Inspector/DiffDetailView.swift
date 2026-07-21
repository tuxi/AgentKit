//
//  DiffDetailView.swift
//  AgentKit
//
//  Created by xiaoyuan on 2026/7/21.
//

import SwiftUI

/// 文件变更对比详情视图。
///
/// 通过 FileContentProvider 加载 diff 数据并渲染。
/// 当 provider 未提供或数据加载失败时展示占位状态。
struct DiffDetailView: View {
    let filePath: String
    let baseRef: String?
    let provider: any FileContentProvider

    @State private var diffContent: DiffContent?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载变更...")
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let diff = diffContent {
                diffContentView(diff)
            } else {
                ContentUnavailableView(
                    "无变更内容",
                    systemImage: "arrow.left.arrow.right"
                )
            }
        }
        .navigationTitle(diffNavigationTitle)
        .task {
            await loadDiff()
        }
    }

    private var diffNavigationTitle: String {
        (filePath as NSString).lastPathComponent
    }

    // MARK: - Diff Content

    @ViewBuilder
    private func diffContentView(_ diff: DiffContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Stats header
                statsHeader(diff)

                Divider()
                    .padding(.vertical, 8)

                // Diff hunks
                if diff.hunks.isEmpty {
                    fallbackDiffView(diff)
                } else {
                    ForEach(diff.hunks) { hunk in
                        hunkView(hunk)
                    }
                }
            }
            .padding()
        }
    }

    private func statsHeader(_ diff: DiffContent) -> some View {
        HStack(spacing: 16) {
            if !diff.original.isEmpty {
                Label("原始 \(diff.original.components(separatedBy: "\n").count) 行", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label("修改 \(diff.modified.components(separatedBy: "\n").count) 行", systemImage: "plus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fallbackDiffView(_ diff: DiffContent) -> some View {
        // Simple side-by-side fallback when no hunks
        VStack(alignment: .leading, spacing: 8) {
            if !diff.original.isEmpty {
                Text("原始版本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(diff.original)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if !diff.modified.isEmpty {
                Text("修改版本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Text(diff.modified)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func hunkView(_ hunk: DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

            // Hunk lines
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                diffLineView(line)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffLine) -> some View {
        switch line {
        case .unchanged(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        case .added(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.08))
        case .removed(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.08))
        }
    }

    // MARK: - Data Loading

    private func loadDiff() async {
        isLoading = true
        defer { isLoading = false }

        do {
            if let content = try await provider.changes(for: filePath, baseRef: baseRef) {
                diffContent = content
            } else {
                errorMessage = "无法获取变更内容"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
