//
//  TrajectoryInspectorView.swift
//  AgentKit
//
//  P8.9 — 调用轨迹查看器（DSH 式调用过程展示）。
//  按 invocation_id 把「请求形状 → 思考过程 → token 消耗」折成一张张调用卡，
//  让用户看清一次模型调用到底带了什么、想了什么、花了多少。
//
//  入口：
//    - turn footer 可点 → 只看该轮（selection.turnID != nil）
//    - 会话 toolbar 按钮 → 全会话跨 turn 汇总（selection.turnID == nil）
//  数据实时取自 WorkspaceStore.activeConversationViewModel.snapshot.turns，
//  live 流变化时视图自动刷新。老服务端（无 model_request）→ 空态提示。
//

import SwiftUI
import ClientToolProtocol

// MARK: - TrajectoryInspectorView

struct TrajectoryInspectorView: View {
    let selection: TrajectorySelection
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "暂无调用轨迹",
                    systemImage: "waveform.path.ecg",
                    description: Text("该会话没有 model_request 事件（服务端需 v1.4+）")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryHeader
                        ForEach(items) { item in
                            TrajectoryTurnSection(item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 320, idealWidth: 380, minHeight: 300)
#endif
        .navigationTitle(selection.title)
    }

    /// (turn, invocations) 列表，按 turn 顺序排列。
    private var items: [TrajectoryTurnItem] {
        let turns = store.activeConversationViewModel?.snapshot.turns ?? []
        let filtered = selection.turnID == nil
            ? turns
            : turns.filter { $0.id == selection.turnID }
        return filtered.enumerated().compactMap { turnIndex, turn in
            let invocations = turn.invocations
            guard !invocations.isEmpty else { return nil }
            return TrajectoryTurnItem(
                id: turn.id,
                turnNumber: turnIndex + 1,
                userPrompt: turn.userPrompt?.text,
                invocations: invocations
            )
        }
    }

    private var allInvocations: [ModelInvocation] {
        items.flatMap { $0.invocations }
    }

    private var summaryHeader: some View {
        let invocations = allInvocations
        let totalMs = invocations.reduce(0) { $0 + ($1.elapsedMs ?? 0) }
        let totalTokens = invocations.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        let cachedTokens = invocations.reduce(0) { $0 + ($1.cachedPromptTokens ?? 0) }
        let finished = invocations.filter(\.isFinished).count
        return VStack(alignment: .leading, spacing: 6) {
            Text(selection.title)
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(invocations.count) 次调用", systemImage: "arrow.trianglehead.clockwise")
                Label(elapsedText(totalMs), systemImage: "clock")
                if totalTokens > 0 {
                    Label(formatCount(totalTokens), systemImage: "text.wordCount")
                }
                if cachedTokens > 0 {
                    Label("缓存 \(formatCount(cachedTokens))", systemImage: "bolt")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if finished < invocations.count {
                Text("\(invocations.count - finished) 次调用仍在进行")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func elapsedText(_ ms: Int) -> String {
        ms >= 1000
            ? String(format: "%.1fs", Double(ms) / 1000.0)
            : "\(ms)ms"
    }

    private func formatCount(_ value: Int) -> String {
        value >= 1000
            ? String(format: "%.1fK", Double(value) / 1000.0)
            : "\(value)"
    }
}

// MARK: - TrajectoryTurnItem

/// 一个 turn 的轨迹段（全会话视图按 turn 分节；单轮视图只有一节）。
private struct TrajectoryTurnItem: Identifiable {
    let id: String
    let turnNumber: Int
    let userPrompt: String?
    let invocations: [ModelInvocation]
}

// MARK: - TrajectoryTurnSection

private struct TrajectoryTurnSection: View {
    let item: TrajectoryTurnItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Turn 标头（全会话视图区分轮次）
            VStack(alignment: .leading, spacing: 2) {
                Text("第 \(item.turnNumber) 轮")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let prompt = item.userPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            ForEach(item.invocations) { invocation in
                InvocationCardView(invocation: invocation)
            }
        }
    }
}

// MARK: - InvocationCardView

/// 一次模型调用一张卡：
///   #N · model · 耗时          ← 头行
///   🔧 调用 run_command, read_file   ← 实际调用工具（折叠态可见）
///   定义 8 · msgs 42 · sys 18.3K · temp 0.3   ← 请求摘要（可展开看全量）
///   → 24.9K prompt (12.1K cached) · 1.8K out   ← 用量行
///   ▸ 思考过程                                 ← thinking 折叠
private struct InvocationCardView: View {
    let invocation: ModelInvocation

    @State private var requestExpanded = false
    @State private var thinkingExpanded = false
    @State private var toolNamesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if !invocation.executedTools.isEmpty {
                executedToolsRow
            }
            if let request = invocation.request {
                requestSummary(request)
                if requestExpanded {
                    requestDetail(request)
                }
            }
            usageRow
            if hasThinking {
                thinkingRow
            }
            if let err = invocation.err, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: 头行
    
   private var modelName: String {
        if let request = invocation.request,
            let modelName = request.modelName,
            let provider = request.provider {
            return "\(provider)/\(modelName)"
        }
        return invocation.request?.modelName ?? "model"
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("#\(invocation.index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(modelName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if invocation.request?.streamed == true {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            let elapsed = invocation.formattedElapsed
            if !elapsed.isEmpty {
                Text(elapsed)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 实际调用（折叠态可见）

    private var executedToolsRow: some View {
        Label(executedToolsSummaryText, systemImage: "wrench.and.screwdriver")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var executedToolsSummaryText: String {
        let tools = invocation.executedTools
        if tools.count > 3 {
            return "调用 \(tools.prefix(3).joined(separator: ", ")) 等 \(tools.count) 个"
        }
        return "调用 \(tools.joined(separator: ", "))"
    }

    // MARK: 请求摘要

    @ViewBuilder
    private func requestSummary(_ request: ModelRequestInfo) -> some View {
        Button {
            requestExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: requestExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                Text(requestSummaryText(request))
                    .font(.caption2)
                    .lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func requestSummaryText(_ request: ModelRequestInfo) -> String {
        var parts: [String] = []
        if !request.toolNames.isEmpty { parts.append("定义 \(request.toolNames.count)") }
        if let count = request.messageCount { parts.append("msgs \(count)") }
        if let chars = request.systemPromptChars { parts.append("sys \(formatCount(chars))") }
        if let chars = request.toolsPromptChars { parts.append("tools def \(formatCount(chars))") }
        if let temp = request.temperature { parts.append("temp \(temp)") }
        return parts.isEmpty ? "no request shape" : parts.joined(separator: " · ")
    }

    // MARK: 请求详情（展开）

    @ViewBuilder
    private func requestDetail(_ request: ModelRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            detailRow("Provider", request.provider ?? "—")
            detailRow("Base URL", request.baseURL ?? "—")
            if !invocation.executedTools.isEmpty {
                detailRow("实际调用", invocation.executedTools.joined(separator: ", "))
            }
            Button {
                toolNamesExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: toolNamesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("可用工具")
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if toolNamesExpanded {
                if !request.toolNames.isEmpty {
                    detailRow("", request.toolNames.joined(separator: ", "))
                }
            }
            detailRow("消息条数", request.messageCount.map(String.init) ?? "—")
            detailRow("System prompt", request.systemPromptChars.map(formatCount) ?? "—")
            detailRow("工具定义", request.toolsPromptChars.map(formatCount) ?? "—")
            if let temp = request.temperature {
                detailRow("温度", String(temp))
            }
            if let choice = request.toolChoice, let text = JSONValue.prettyString(from: choice) {
                detailRow("tool_choice", text)
            }
            detailRow("流式", request.streamed == true ? "是" : "否")
        }
        .padding(.leading, 12)
        .padding(.top, 2)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: 用量行

    @ViewBuilder
    private var usageRow: some View {
        Text(usageRowText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var usageRowText: String {
        var parts: [String] = []
        if let prompt = invocation.promptTokens {
            if let cached = invocation.cachedPromptTokens, cached > 0 {
                parts.append("→ \(formatCount(prompt)) prompt（缓存 \(formatCount(cached))）")
            } else {
                parts.append("→ \(formatCount(prompt)) prompt")
            }
        }
        if let completion = invocation.completionTokens {
            parts.append("\(formatCount(completion)) out")
        }
        if let total = invocation.totalTokens {
            parts.append("共 \(formatCount(total))")
        }
        if let units = invocation.billingUnits {
            parts.append("\(units) units")
        }
        if parts.isEmpty {
            parts.append(invocation.isFinished ? "无用量数据" : "调用进行中…")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 思考

    private var hasThinking: Bool {
        !(invocation.thinkingText ?? "").isEmpty
    }

    private var thinkingRow: some View {
        Button {
            thinkingExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("思考过程")
                        .font(.caption2.weight(.medium))
                    Spacer()
                }
                if thinkingExpanded, let text = invocation.thinkingText {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func formatCount(_ value: Int) -> String {
        value >= 1000
            ? String(format: "%.1fK", Double(value) / 1000.0)
            : "\(value)"
    }
}
