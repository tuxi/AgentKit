#if os(macOS)
import SwiftUI
import AppKit
import ClientToolProtocol
import WebKit

/// Shared native content for a docked pane or the click-to-open rail popup.
public struct SessionRailView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.sessionRailIsVisible) private var visible
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    private var model: SessionRailModel { store.sessionRail }
    private var conversationID: String? { store.selectedConversation?.id }
    private var vm: ConversationViewModel? {
        guard store.activeConversationViewModel?.conversation?.id == conversationID else { return nil }
        return store.activeConversationViewModel
    }
    private var taskKey: String { "\(conversationID ?? "")|\(visible)|\(scenePhase == .active)" }
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            if let route = model.route, model.conversationID == conversationID {
                HStack(spacing: 8) {
                    Button { model.back(); search = "" } label: { Image(systemName: "chevron.left").frame(width: 24, height: 26) }
                        .help("返回上一层").accessibilityLabel("返回上一层")
                    Text(title(route)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { Task { await model.loadDetail() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新详情").disabled(model.detailLoading)
                }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 38)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.conversationID != conversationID || (model.snapshot == nil && model.error == nil) {
                        if conversationID == nil { note("选择对话后查看会话信息") }
                        else { HStack { ProgressView().controlSize(.small); note("正在读取会话信息…") } }
                    } else if let route = model.route {
                        if model.detailLoading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                        if let error = model.detailError { message(error) { Task { await model.loadDetail() } } }
                        detail(route)
                    } else {
                        if let error = model.error { message(error) { Task { await model.refresh(); await vm?.backgroundJobs.refresh() } } }
                        if let snapshot = model.snapshot { root(snapshot) }
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("session-rail.content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: taskKey) {
            guard visible, scenePhase == .active, let conversationID else { return }
            await model.run(conversationID: conversationID) { vm?.isTurnActive == true || (vm?.backgroundJobs.runningCount ?? 0) > 0 }
        }
        .task(id: "\(visible)|\(scenePhase == .active)|\(model.snapshot?.snapshotID ?? "")") {
            guard visible, scenePhase == .active, model.conversationID == conversationID,
                  model.hasTaskSurface(for: conversationID) else { return }
            // The shared registry model owns cancellation and terminal races.
            // Rail refresh drives it; do not start a second job poller.
            vm?.backgroundJobs.setVisible(false)
            await vm?.backgroundJobs.refresh()
        }
        .task(id: "\(visible)|\(scenePhase == .active)|\(model.stateID)|\(String(describing: model.route))") {
            guard visible, scenePhase == .active else { return }
            search = ""; await model.loadDetail()
        }
    }

    private func root(_ s: SessionRailSnapshot) -> some View {
        VStack(spacing: 0) {
            section("environment", "Environment", summary: s.sections.environment.data?.workspace?.name ?? "", section: s.sections.environment) { environment($0) }
            section("context", "Context", summary: contextSummary(s.sections.context.data), section: s.sections.context) { context($0) }
            section("connectors", "Connectors", summary: s.sections.connectors.data.map { "\($0.items.filter { $0.status == "connected" }.count) 已连接" } ?? "", section: s.sections.connectors) { connectors($0) }
            section("outputs", "Outputs", summary: s.sections.outputs.data.map { "\($0.totalCount) 个已记录产物" } ?? "", section: s.sections.outputs) { outputs($0, compact: true) }
            section("changes", "Changes", summary: s.sections.changes.data.map { $0.isGitRepository ? "\($0.fileCount) 个文件" : "未使用 Git" } ?? "", section: s.sections.changes) { changes($0, compact: true) }
            section("tasks", "Background tasks", summary: s.sections.backgroundTasks.data.map { "\($0.activeCount.map(String.init) ?? "未知") 运行中" } ?? "", section: s.sections.backgroundTasks) { jobs($0, compact: true) }
            HStack {
                if model.isRefreshing { ProgressView().controlSize(.mini) }
                Text(model.isRefreshing ? "正在更新" : "更新于 \(date(s.generatedAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh(); await vm?.backgroundJobs.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新会话信息").disabled(model.isRefreshing)
            }.buttonStyle(.plain).padding(.top, 12)
        }
    }
    private func section<T: Decodable & Sendable, Content: View>(_ key: String, _ title: String, summary: String,
        section value: SessionRailSection<T>, @ViewBuilder content: @escaping (T) -> Content) -> some View {
        VStack(spacing: 10) {
            DisclosureGroup(isExpanded: Binding(get: { model.isExpanded(key) }, set: { model.setExpanded($0, for: key) })) {
                VStack(alignment: .leading, spacing: 5) {
                    if value.isUsable, let data = value.data {
                        if value.state == "stale" { note("部分信息尚未更新") }
                        content(data)
                    } else { note(sectionMessage(value.state, code: value.code)) }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text(value.isUsable ? summary : sectionMessage(value.state, code: value.code))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.disclosureGroupStyle(SessionRailDisclosureStyle())
                .accessibilityIdentifier("session-rail.section.\(key)")
            Divider()
        }.padding(.vertical, 10)
    }

    private func environment(_ value: SessionRailEnvironment) -> some View {
        VStack(spacing: 3) {
            row("desktopcomputer", value.runtime.displayName, trailing: value.runtime.runtimeProfile) { model.navigate(.environment) }
            if let workspace = value.workspace {
                row("folder", workspace.name ?? "工作区", trailing: nil) { model.navigate(.environment) }
                    .help(workspace.runtimeCWD ?? workspace.rootPath)
            }
            if let head = value.head {
                row("arrow.triangle.branch", head.name ?? (head.kind == "detached" ? String((head.commit ?? "").prefix(8)) : headLabel(head.kind)), trailing: nil) { model.navigate(.environment) }
            }
            if let worktree = value.worktree { row("square.on.square", "独立工作树", trailing: worktree.state) { model.navigate(.environment) } }
            if value.needsRebind { note("工作区需要重新绑定") }
        }
    }
    private func contextCapacity(_ value: SessionRailContext) -> Int? {
        let capacity = value.measurementWindow.flatMap { $0 > 0 ? $0 : nil } ?? value.snapshot.model.contextWindow
        return capacity > 0 ? capacity : nil
    }
    private func contextSummary(_ value: SessionRailContext?) -> String {
        guard let value, let tokens = value.promptTokens else { return "尚未测量" }
        guard let capacity = contextCapacity(value) else { return "占用比例未知" }
        return String(format: "%.0f%% 已用", Double(max(0, tokens)) / Double(capacity) * 100)
    }
    private func contextNumber(_ value: Int) -> String {
        let magnitude = value >= 1_000_000 ? 1_000_000.0 : value >= 1000 ? 1000.0 : 1.0
        let suffix = magnitude == 1_000_000 ? "M" : magnitude == 1000 ? "k" : ""
        return (Double(value) / magnitude).formatted(.number.precision(.fractionLength(0...1))) + suffix
    }
    private func context(_ value: SessionRailContext) -> some View {
        let capacity = contextCapacity(value)
        let buffer = capacity.flatMap { window -> Int? in
            let threshold = value.snapshot.model.compactThreshold
            guard window == value.snapshot.model.contextWindow, threshold > 0, threshold < window else { return nil }
            return window - threshold
        }
        let estimateCapacity = value.request.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil } ?? capacity
        return VStack(alignment: .leading, spacing: 10) {
            Button { model.navigate(.context) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(contextSummary(value)).font(.system(size: 15))
                    Spacer(minLength: 0)
                    Text("\(value.promptTokens.map(contextNumber) ?? "—") / \(capacity.map(contextNumber) ?? "未知")")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }.frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help("查看上下文详情；已用量来自上次测量")
            if let capacity, let tokens = value.promptTokens {
                ProgressView(value: min(1, max(0, Double(tokens) / Double(capacity))))
                    .tint(.blue).accessibilityLabel("上次测量的上下文用量")
            }
            if value.historyState == "history_changed" || value.latestRequestSnapshotID != value.measurementSnapshotID {
                note("内容已更新，等待新的测量")
            }
            if let request = value.request {
                ForEach(categoryOrder.filter { request.categories[$0] != nil }, id: \.self) { key in
                    contextCategory(categoryName(key), tokens: max(0, request.categories[key] ?? 0), capacity: estimateCapacity,
                                    color: categoryColor(key), estimated: true) {
                        if key == "mcp_tools" { model.navigate(.tools(snapshotID: request.snapshotID, origin: "mcp")) }
                        else if key == "system_tools" { model.navigate(.tools(snapshotID: request.snapshotID, origin: "system")) }
                        else { model.navigate(.context) }
                    }
                }
                note("组成数量与百分比为估算值，按请求窗口计算。")
                if request.multimodalUnestimated { note("图片等多模态成本未计入组成估算。") }
            } else { note("当前记录尚无请求组成与来源。") }
            if let capacity, let buffer {
                contextCategory("Autocompact buffer", tokens: buffer, capacity: capacity,
                                color: .gray.opacity(0.5), estimated: false) { model.navigate(.context) }
                    .help("根据当前模型的自动压缩阈值计算的预留窗口")
            }
            if let capacity, let tokens = value.promptTokens {
                contextCategory("Free space", tokens: max(0, capacity - max(0, tokens) - (buffer ?? 0)), capacity: capacity,
                                color: Color(nsColor: .tertiaryLabelColor), estimated: false) { model.navigate(.context) }
            }
            if let measuredAt = value.measuredAt { note("上次测量于 \(date(measuredAt))") }
            else if value.promptTokens != nil { note("上次测量时间未记录") }
            else { note("本轮完成后获取新的用量测量") }
            if value.windowSource == "fallback", value.measurementWindow == nil { note("窗口容量使用 Runtime 默认值") }
            if let measuredWindow = value.measurementWindow, measuredWindow > 0,
               value.snapshot.model.contextWindow > 0, measuredWindow != value.snapshot.model.contextWindow {
                note("上方为上次测量对应窗口；当前模型窗口为 \(contextNumber(value.snapshot.model.contextWindow))。")
            }
        }
    }
    private func contextCategory(_ title: String, tokens: Int, capacity: Int?, color: Color,
                                 estimated: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Text((estimated ? "≈" : "") + contextNumber(tokens))
                    .foregroundStyle(.secondary).frame(minWidth: 42, alignment: .trailing)
                Text(capacity.map { String(format: "%.1f%%", Double(tokens) / Double($0) * 100) } ?? "—")
                    .frame(width: 44, alignment: .trailing)
            }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 3)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title + (estimated ? " · 估算组成" : " · 根据上次测量计算"))
    }
    private func categoryColor(_ key: String) -> Color {
        switch key {
        case "mcp_tools": .blue
        case "system_tools": .orange
        case "system_prompt": .teal
        case "skills": .yellow
        case "memory_files": .purple
        default: .gray
        }
    }
    private func connectors(_ value: SessionRailConnectors) -> some View {
        VStack(spacing: 4) {
            if value.items.isEmpty { note("当前工作区没有已记录的连接") }
            ForEach(value.items, id: \.connectorID) { item in
                row(item.kind == "mcp" ? "puzzlepiece.extension" : "desktopcomputer", item.displayName,
                    trailing: "\(status(item.status)) · \(item.availableToolCount.map(String.init) ?? "?")") { model.navigate(.connector(item.connectorID)) }
            }
            if !value.diagnostics.isEmpty { note("配置存在异常，详情保留有效连接。") }
            if value.clientCapabilitiesState != "registered_tools_only" { note("本机能力尚未提供注册信息") }
        }
    }
    private func outputs(_ value: SessionRailOutputs, compact: Bool) -> some View {
        VStack(spacing: 4) {
            if value.coverage == "legacy_incomplete" { note("旧记录不完整，仅展示可证明的产物。") }
            if value.items.isEmpty { note(value.coverage == "legacy_incomplete" ? "暂未找到可证明的产物" : "尚无生成产物") }
            ForEach(compact ? Array(value.items.prefix(5)) : value.items, id: \.outputID) { item in
                row(item.kind == "image" ? "photo" : item.kind == "preview" ? "rectangle.on.rectangle" : "doc", item.title,
                    trailing: item.state == "deleted" ? "已删除" : nil) { model.navigate(.output(item.outputID)) }
            }
            if compact, value.totalCount > 0 { more("查看全部 \(value.totalCount) 个产物") { model.navigate(.outputs) } }
            if !compact, value.nextCursor != nil { more("显示更多") { Task { await model.loadMoreOutputs() } }.disabled(model.detailLoading) }
        }
    }
    private func changes(_ value: SessionRailChanges, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !value.isGitRepository { note("未使用 Git") }
            else {
                row("plus.forwardslash.minus", "\(value.fileCount) 个文件", trailing: "+\(value.addedLines) −\(value.removedLines)") { model.navigate(.changes) }
                note(value.uncountedFiles > 0 ? "相对 HEAD · \(value.uncountedFiles) 项无文本行数" : "相对 HEAD")
                ForEach(compact ? Array(value.files.prefix(3)) : value.files, id: \.fileID) { file in
                    row(file.conflict ? "exclamationmark.triangle" : "doc.text", file.path, trailing: fileStatus(file)) {
                        model.navigate(.patch(snapshotID: value.snapshotID, fileID: file.fileID, path: file.path))
                    }
                }
                if value.fileCount == 0 { note("工作区无变更") }
                if compact, value.fileCount > 0 { more("查看全部变更") { model.navigate(.changes) } }
            }
        }
    }
    private func jobs(_ value: SessionRailJobs, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waiting = vm?.snapshot.backgroundContinuation, waiting.isWaiting {
                Text(waiting.title).font(.system(size: 12, weight: .medium))
                Button(vm?.isCancelling == true ? "正在停止本轮" : "停止本轮自动继续") { Task { await vm?.cancelTurn() } }
                    .font(.system(size: 12)).disabled(vm?.isCancelling == true)
            }
            if value.items.isEmpty { note("尚无后台任务") }
            ForEach(compact ? Array(value.items.prefix(3)) : value.items, id: \.jobID) { item in
                jobRow(item)
            }
            if value.unknownCount > 0 { note("\(value.unknownCount) 个历史任务的当前状态未知") }
            if compact, value.totalCount > 0 { more("查看全部 \(value.totalCount) 个任务") { model.navigate(.jobs) } }
            if !compact, value.nextCursor != nil { more("显示更多") { Task { await model.loadMoreJobs() } }.disabled(model.detailLoading) }
        }
    }
    private func jobRow(_ item: SessionRailJob) -> some View {
        let live = vm?.backgroundJobs.jobs.first { $0.jobID == item.jobID && $0.turnID == item.turnID && $0.callID == item.callID }
        let stopping = live?.cancelRequested == true || vm?.backgroundJobs.stopping.contains(.init(jobID: item.jobID, turnID: item.turnID, callID: item.callID)) == true
        return HStack(spacing: 5) {
            row("terminal", String(item.command.prefix(180)), trailing: stopping ? "停止中" : jobStatus(live?.status ?? item.status)) { model.navigate(.job(item.jobID)) }
            if let live, live.status == .running {
                Button { Task { await vm?.backgroundJobs.stop(live.owner); await model.refresh() } } label: { Image(systemName: "stop.circle").frame(width: 24, height: 26) }
                    .buttonStyle(.plain).help("停止后台任务")
                    .disabled(stopping || vm?.backgroundJobs.canControl != true || model.error != nil)
            }
        }
    }

    @ViewBuilder private func detail(_ route: SessionRailRoute) -> some View {
        switch route {
        case .environment:
            if let value = model.snapshot?.sections.environment.data {
                facts([("运行环境", value.runtime.displayName), ("版本", value.runtime.runtimeVersion), ("Profile", value.runtime.runtimeProfile),
                       ("工作目录", value.workspace?.runtimeCWD ?? value.workspace?.rootPath ?? "未知"), ("执行策略", value.executionPolicy),
                       ("分支", value.head?.name ?? value.head?.commit ?? "未知")])
                if let path = value.workspace?.runtimeCWD ?? value.workspace?.rootPath { copyButton("复制工作目录", path) }
            }
        case .context:
            if let value = model.snapshot?.sections.context.data {
                context(value)
                facts([("测量时间", value.measuredAt.map(date) ?? "无时间记录"), ("测量模型", value.measurementModel ?? value.snapshot.model.name),
                       ("窗口来源", value.windowSource == "fallback" ? "默认容量" : "配置容量"),
                       ("输入预算", value.snapshot.model.inputTokenBudget.map(number) ?? "未知"), ("输出预留", value.snapshot.model.outputTokenBudget.map(number) ?? "未知"),
                       ("压缩次数", String(value.snapshot.compaction.totalCount))])
                if let request = value.request {
                    if request.sourceCoverage != "recorded" { note("来源记录尚不完整") }
                    if request.multimodalUnestimated { note("图片等多模态成本未计入组成估算") }
                    ForEach(request.sources ?? [], id: \.sourceID) { source in
                        row("doc.text", source.displayPath ?? source.label, trailing: "≈\(number(source.estimatedTokens))") { model.navigate(.source(snapshotID: request.snapshotID, sourceID: source.sourceID, title: source.label)) }
                    }
                    more("查看请求中的全部工具") { model.navigate(.tools(snapshotID: request.snapshotID, origin: nil)) }
                }
            }
        case .connectors:
            if let value = model.snapshot?.sections.connectors.data { connectors(value) }
        case .connector:
            if let value = model.connector {
                facts([("名称", value.displayName), ("类型", value.kind == "mcp" ? "MCP 服务" : "本机能力"), ("状态", status(value.status)),
                       ("配置来源", value.source), ("发现工具", count(value.discoveredToolCount)), ("已注册", count(value.registeredToolCount)),
                       ("可用", count(value.availableToolCount)), ("上次成功请求中暴露", count(value.exposedToolCount))])
                if let reason = value.reason { note(reason == "registration_does_not_imply_permission" ? "已注册不代表已获得权限或当前可执行。" : reason) }
                if value.health == "not_probed" { note("读取现有 SDK 连接状态，未额外探活。") }
                ForEach(value.tools ?? [], id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 4) { Text(tool.name).font(.system(size: 12, weight: .medium)); note(tool.description) }.padding(.vertical, 6)
                }
            }
        case .tools(_, let origin):
            TextField("搜索工具", text: $search).textFieldStyle(.roundedBorder)
            if let request = model.request {
                ForEach((request.tools ?? []).filter { (origin == nil || $0.origin == origin) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }, id: \.name) { tool in
                    row("wrench.and.screwdriver", tool.name, trailing: "≈\(number(tool.estimatedTokens))") {
                        model.navigate(.source(snapshotID: request.snapshotID, sourceID: tool.sourceID, title: tool.name))
                    }
                }
            }
        case .source:
            if let source = model.source {
                facts([("来源", source.displayPath ?? source.label), ("范围", source.scope ?? "运行时"), ("版本", source.version.flatMap { $0.isEmpty ? nil : $0 } ?? String(source.sha256.prefix(12)))])
                textContent(source.content)
            }
        case .outputs:
            if let value = model.outputs { outputs(value, compact: false) }
        case .output:
            if let value = model.output {
                Text(value.title).font(.headline).textSelection(.enabled)
                facts([("内容方式", value.contentMode == "immutable" ? "不可变产物版本" : "工作区当前文件"), ("来源轮次", value.latest.turnID),
                       ("写入/版本记录", String(value.versionCount)), ("更新时间", date(value.latest.updatedAt))])
                if let asset = value.latest.asset, value.state != "deleted" {
                    Button("打开产物预览") { store.showInspector(.asset(.init(asset: asset, conversationID: conversationID))) }
                } else if value.state == "deleted" { note("最后记录为已删除，历史报告不包含旧文件字节。") }
                else if value.latest.artifact == nil { note("旧记录未保存可读取的资源引用。") }
                if let artifact = value.latest.artifact {
                    Text("版本 \(artifact.revision) · \(artifact.status.rawValue)").font(.callout)
                    if artifact.viewer != nil {
                        Button("打开此版本预览") { Task { await model.loadPreview(artifact) } }.disabled(model.detailLoading)
                    }
                    if let html = model.previewHTML { SessionRailPreview(html: html).frame(height: 360) }
                }
                ForEach(Array((value.versions ?? []).enumerated()), id: \.offset) { _, version in
                    Text("\(version.turnID) · \(version.operation) · \(date(version.updatedAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .changes:
            if let value = model.changes { changes(value, compact: false) }
        case .patch:
            if let value = model.patch {
                if value.state == "untracked" { note("未跟踪文件，尚无相对 HEAD 的文本 diff。") }
                else if value.state == "binary" { note("二进制变更，没有文本行数。") }
                else if value.state == "submodule" { note("子模块引用或工作区发生变化。") }
                if !value.patch.isEmpty { textContent(value.patch) }
            }
        case .jobs:
            if let value = model.jobs { jobs(value, compact: false) }
        case .job(let id):
            if let job = model.jobs?.items.first(where: { $0.jobID == id }) ?? model.snapshot?.sections.backgroundTasks.data?.items.first(where: { $0.jobID == id }) {
                facts([("命令", job.command), ("状态", jobStatus(job.status)), ("开始", job.startedAt.map(date) ?? "未知"), ("结束", job.finishedAt.map(date) ?? "未知"),
                       ("耗时", job.durationMs.map { String(format: "%.1fs", Double($0) / 1000) } ?? "未知")])
                jobRow(job)
                Button("查看完整日志") { store.showInspector(.childStream(.init(childID: job.jobID, kind: .job, title: String(job.command.prefix(100))))) }
                if let error = vm?.backgroundJobs.stopErrors[.init(jobID: job.jobID, turnID: job.turnID, callID: job.callID)] { note(error) }
            }
        }
    }
    private func row(_ symbol: String, _ label: String, trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 17)
                Text(label).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
            }.font(.system(size: 13)).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label)
    }
    private func more(_ title: String, action: @escaping () -> Void) -> some View { Button(title, action: action).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5) }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
    private func message(_ text: String, retry: @escaping () -> Void) -> some View { VStack(alignment: .leading, spacing: 6) { note(text); Button("重试", action: retry).font(.system(size: 12)) }.padding(.vertical, 6) }
    private func facts(_ values: [(String, String)]) -> some View { VStack(alignment: .leading, spacing: 10) { ForEach(Array(values.enumerated()), id: \.offset) { _, pair in VStack(alignment: .leading, spacing: 3) { Text(pair.0).font(.system(size: 11)).foregroundStyle(.secondary); Text(pair.1).font(.system(size: 13)).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading) }
    private func copyButton(_ label: String, _ value: String) -> some View { Button(label) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }.font(.system(size: 12)) }
    private func textContent(_ text: String) -> some View { VStack(alignment: .leading, spacing: 8) { copyButton("复制完整内容", text); if text.count > 100_000 { note("内容较长，显示前 100,000 个字符。") }; Text(String(text.prefix(100_000))).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    private func number(_ value: Int) -> String { value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : String(value) }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "未知" }
    private func date(_ value: String) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; guard let d = f.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value.isEmpty ? "未知" : value }; return d.formatted(date: .abbreviated, time: .shortened) }
    private func status(_ value: String) -> String { ["connected":"已连接", "connecting":"连接中", "disconnected":"已断开", "failed":"连接失败", "disabled":"已停用", "unknown":"未知"][value] ?? value }
    private func jobStatus(_ value: BackgroundJobStatus) -> String { switch value { case .running: "运行中"; case .exited: "已完成"; case .failed: "失败"; case .canceled: "已取消"; case .unknown: "当前状态未知" } }
    private func headLabel(_ value: String) -> String { ["not_git":"未使用 Git", "unborn":"尚无提交", "detached":"Detached HEAD"][value] ?? "Git 信息未知" }
    private func fileStatus(_ file: SessionRailChangedFile) -> String { if file.conflict { return "冲突" }; if file.binary { return "二进制" }; if file.submodule { return "子模块" }; if file.status == "untracked" { return "未跟踪" }; if let a = file.addedLines, let d = file.removedLines { return "+\(a) −\(d)" }; return file.status }
    private func sectionMessage(_ state: String, code: String?) -> String { if code == "invalid_section_payload" { return "数据格式不匹配，请更新 Runtime" }; switch state { case "loading": return "正在读取…"; case "empty": return "暂无记录"; case "error": return "读取失败"; case "unavailable": return "当前不可用"; default: return "状态未知" } }
    private let categoryOrder = ["mcp_tools", "system_tools", "system_prompt", "skills", "mcp_server_instructions", "messages", "memory_files", "other_tools"]
    private func categoryName(_ key: String) -> String { ["messages":"Messages", "mcp_tools":"MCP tools", "system_tools":"System tools", "system_prompt":"System prompt", "skills":"Skills", "mcp_server_instructions":"MCP server instructions", "memory_files":"Memory files", "other_tools":"Other tools"][key] ?? key }
    private func categorySymbol(_ key: String) -> String { key.contains("tools") ? "wrench.and.screwdriver" : key == "messages" ? "text.bubble" : "doc.text" }
    private func title(_ route: SessionRailRoute) -> String { switch route { case .environment: "Environment"; case .context: "Context"; case .connectors: "Connectors"; case .outputs: "Outputs"; case .changes: "Changes"; case .jobs: "Background tasks"; case .tools: "请求中的工具"; case .source(_, _, let title): title; case .connector: "连接详情"; case .output: "产物详情"; case .patch(_, _, let path): path; case .job: "任务详情" } }
}

/// Use one native button for the whole header, including the trailing summary.
/// Keeping the toggle in a style avoids competing label/chevron tap gestures.
private struct SessionRailDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
                .accessibilityHint("展开或收起分组")
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct SessionRailPreview: NSViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "session-rail-no-network", encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]") { rules, _ in
            Task { @MainActor in
                guard context.coordinator.html == html, let rules else { return }
                view.configuration.userContentController.add(rules)
                view.loadHTMLString(html, baseURL: nil)
            }
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}
#endif
