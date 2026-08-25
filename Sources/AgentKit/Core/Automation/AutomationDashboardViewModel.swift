//
//  AutomationDashboardViewModel.swift
//  AgentKit
//
//  自动化控制面板 ViewModel：负责加载/刷新任务列表、创建、部分更新（含暂停/启用）、
//  删除、运行历史拉取，以及调度描述的人类可读化。
//

import Foundation
import SwiftUI

// MARK: - AutomationDashboardViewModel

@MainActor
@Observable
public final class AutomationDashboardViewModel {

    // MARK: - State

    /// 从 Runtime 拉取的全部任务（清单，服务端按 newest-first 返回）。
    public private(set) var automations: [Automation] = []
    /// 当前选中任务的运行历史。
    public private(set) var runs: [AutomationRun] = []

    public private(set) var isLoading = false
    public private(set) var isLoadingRuns = false
    public private(set) var isMutating = false
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false

    /// 当前筛选标签。
    public var selectedTab: AutomationDashboardTab = .all {
        didSet { applyFilter() }
    }

    /// 展示用（已按 `selectedTab` 过滤）。
    public private(set) var filteredAutomations: [Automation] = []

    @ObservationIgnored private let client: RuntimeClient
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // MARK: - Init

    public init(client: RuntimeClient) {
        self.client = client
    }

    // MARK: - Derived

    public var activeCount: Int { automations.filter { $0.status == .active }.count }
    public var pausedCount: Int { automations.filter { $0.status == .paused }.count }
    public var completedCount: Int { automations.filter { $0.status == .completed }.count }

    /// 有正在运行的任务时显示"勿关机"提示。
    public var hasRunningAutomation: Bool {
        automations.contains { $0.lastStatus == AutomationRunStatus.running.rawValue }
    }

    // MARK: - Load

    public func load(force: Bool = false) async {
        if loadTask != nil && !force { return }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            automations = try await client.listAutomations()
            hasLoaded = true
            applyFilter()
        } catch {
            errorMessage = Self.message(for: error) ?? "加载自动化任务失败"
        }
    }

    // MARK: - Runs

    public func loadRuns(for id: String) async {
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            runs = try await client.listAutomationRuns(id: id)
        } catch {
            errorMessage = Self.message(for: error) ?? "加载运行历史失败"
        }
    }

    // MARK: - Mutations

    /// 创建任务（返回创建的 Automation，供恢复现场）。
    @discardableResult
    public func create(_ request: AutomationCreateRequest) async throws -> Automation {
        isMutating = true
        defer { isMutating = false }
        do {
            let created = try await client.createAutomation(request)
            try await reloadAfterMutation(backfill: created)
            return created
        } catch {
            errorMessage = Self.message(for: error) ?? "创建失败"
            throw error
        }
    }

    /// 部分更新（`patch` 只填要改的字段）。
    @discardableResult
    public func update(id: String, patch: AutomationPatchRequest) async throws -> Automation {
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await client.updateAutomation(id: id, request: patch)
            try await reloadAfterMutation(backfill: updated)
            return updated
        } catch {
            errorMessage = Self.message(for: error) ?? "保存失败"
            throw error
        }
    }

    /// 暂停 / 启用：`enabled=false` → PAUSED，`true` → ACTIVE。
    @discardableResult
    public func setEnabled(id: String, enabled: Bool) async throws -> Automation {
        try await update(id: id, patch: AutomationPatchRequest(enabled: enabled))
    }

    /// 软删除。
    public func delete(id: String) async throws {
        isMutating = true
        defer { isMutating = false }
        do {
            try await client.deleteAutomation(id: id)
            automations.removeAll { $0.id == id }
            applyFilter()
        } catch {
            errorMessage = Self.message(for: error) ?? "删除失败"
            throw error
        }
    }

    /// 变更后刷新：优先用服务端权威响应回填本地，再后台拉一次列表对齐。
    private func reloadAfterMutation(backfill: Automation) async throws {
        if let idx = automations.firstIndex(where: { $0.id == backfill.id }) {
            automations[idx] = backfill
        } else {
            automations.insert(backfill, at: 0)
        }
        applyFilter()
        await refreshFromServer()
        applyFilter()
    }

    /// 重新从服务端拉全量列表覆盖本地状态（用于变更后对齐）。
    private func refreshFromServer() async {
        do {
            automations = try await client.listAutomations()
        } catch {
            // 静默降级：保留已回填的权威响应，避免本地误删。
        }
    }

    // MARK: - Filter

    private func applyFilter() {
        switch selectedTab {
        case .all:
            filteredAutomations = automations
        case .active:
            filteredAutomations = automations.filter { $0.status == .active }
        case .paused:
            filteredAutomations = automations.filter { $0.status == .paused }
        case .completed:
            filteredAutomations = automations.filter { $0.status == .completed }
        }
    }

    // MARK: - Error

    private static func message(for error: Error) -> String? {
        (error as? LocalizedError)?.errorDescription
    }
}

// MARK: - AutomationDashboardTab

public enum AutomationDashboardTab: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "进行中"
    case paused = "已暂停"
    case completed = "已完成"

    public var id: String { rawValue }
}

// MARK: - Schedule description (human-readable)

/// 把 `schedule_type` + `rrule`/`scheduled_at` 渲染成中文调度描述。
public enum AutomationScheduleFormatter {

    /// 主描述：给列表副标题 / 详情用。
    /// - `once` → "2026/8/26 15:00 执行一次"
    /// - recurring + rrule → "每天 16:00" / "每周一 09:00" / "每 30 分钟"
    /// - 解析失败 → 回退原始 rrule 字符串，不崩溃。
    public static func describe(_ automation: Automation) -> String {
        switch automation.scheduleType {
        case .once:
            if let at = automation.scheduledAt, let date = parseRFC3339(at) {
                return "\(formatDate(date)) \(formatTime(date)) 执行一次"
            }
            return "执行一次"
        case .recurring:
            if let rrule = automation.rrule, !rrule.isEmpty {
                return describeRRule(rrule)
            }
            return "重复执行"
        }
    }

    /// 时区提示（IANA 时区名），无有效时区时返回空串。
    public static func timezoneHint(for automation: Automation) -> String {
        guard !automation.timezone.isEmpty else { return "" }
        return "（\(automation.timezone)）"
    }

    /// 下次触发描述的右侧文案。
    public static func nextRunText(for automation: Automation) -> String {
        switch automation.status {
        case .completed:
            return "已完成"
        case .paused:
            return "已暂停"
        case .active:
            if let next = automation.nextRunAt, let date = parseRFC3339(next) {
                return "下次 \(formatDate(date)) \(formatTime(date))"
            }
            if automation.scheduleType == .once {
                return "待执行"
            }
            return "无下次触发"
        }
    }

    // MARK: - RRule parsing (minimal, RFC5545 subset)

    static func describeRRule(_ rrule: String) -> String {
        // Split into FREQ / INTERVAL / BYHOUR / BYMINUTE / BYDAY / BYMONTHDAY ...
        var freq: String?
        var interval: String?
        var byHour: String?
        var byMinute: String?
        var byDay: String?

        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).uppercased()
            let value = String(kv[1])
            switch key {
            case "FREQ": freq = value.uppercased()
            case "INTERVAL": interval = value
            case "BYHOUR": byHour = value
            case "BYMINUTE": byMinute = value
            case "BYDAY": byDay = value
            default: break
            }
        }

        let time = timeText(hour: byHour, minute: byMinute)
        let intervalInt = Int(interval ?? "1") ?? 1

        guard let freq else {
            // 无法解析 → 回退原始字符串
            return rrule
        }

        switch freq {
        case "DAILY":
            if intervalInt > 1 { return time.isEmpty ? "每 \(intervalInt) 天" : "每 \(intervalInt) 天 \(time)" }
            return time.isEmpty ? "每天" : "每天 \(time)"
        case "WEEKLY":
            let day = weekdayText(byDay)
            if intervalInt > 1 {
                return day.isEmpty ? "每 \(intervalInt) 周" : "每 \(intervalInt) 周\(day)"
            }
            return day.isEmpty
                ? (time.isEmpty ? "每周" : "每周 \(time)")
                : (time.isEmpty ? "\(day)" : "\(day) \(time)")
        case "MONTHLY":
            if intervalInt > 1 { return "每 \(intervalInt) 月" }
            return "每月"
        case "MINUTELY":
            if intervalInt > 1 { return "每 \(intervalInt) 分钟" }
            return "每分钟"
        case "HOURLY":
            if intervalInt > 1 { return "每 \(intervalInt) 小时" }
            return "每小时"
        case "YEARLY":
            if intervalInt > 1 { return "每 \(intervalInt) 年" }
            return "每年"
        default:
            return rrule
        }
    }

    private static func timeText(hour: String?, minute: String?) -> String {
        guard let hour, let h = Int(hour) else { return "" }
        let m = Int(minute ?? "0") ?? 0
        return String(format: "%02d:%02d", h, m)
    }

    private static func weekdayText(_ byDay: String?) -> String {
        guard let byDay, !byDay.isEmpty else { return "" }
        // BYDAY can be e.g. "MO" or "MO,TU,WE".
        let codes = byDay.split(separator: ",").map(String.init)
        let names: [String] = codes.compactMap { code in
            switch code.uppercased() {
            case "MO": return "周一"
            case "TU": return "周二"
            case "WE": return "周三"
            case "TH": return "周四"
            case "FR": return "周五"
            case "SA": return "周六"
            case "SU": return "周日"
            default: return nil
            }
        }
        guard !names.isEmpty else { return "" }
        return "周" + names.map { String($0.last!) }.joined()
    }

    // MARK: - RFC3339 helpers

    /// 把 `Date` 编码成 RFC3339（含时区偏移），供 `scheduled_at` 上传。
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d"
        return f.string(from: date)
    }

    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
