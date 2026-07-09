//
//  SettingsView.swift
//  AgentKit
//
//  设置页 v2：Account / Provider / Usage 三段式。
//  支持 Gateway 登录 + BYOK key 管理 + 使用量展示。
//

import SwiftUI

// MARK: - SettingsView

public struct SettingsView: View {
    @Environment(AccountManager.self) private var accountManager
    @Environment(ModelSettingsStore.self) private var modelSettings
    @Environment(\.dismiss) private var dismiss
    @State private var credentialSettings = CredentialSettingsStore()
    @State private var showLogin = false
    @State private var showKey = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                accountSection
                providerSection
                legacySection
                if accountManager.state.isAuthenticated {
                    usageSection
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
                    .environment(accountManager)
            }
            .task {
                // 同步 Gateway 模型列表到 UI store
                credentialSettings.gatewayModelIDs = modelSettings.availableModelIDs
                for id in modelSettings.availableModelIDs {
                    credentialSettings.modelDisplayNames[id] = modelSettings.displayName(for: id)
                }
                // 初始化模型选择：优先 last_used_model，否则 default_model
                if credentialSettings.model.isEmpty {
                    credentialSettings.model = modelSettings.effectiveModel
                }
                await credentialSettings.refresh()
                if accountManager.state.isAuthenticated {
                    try? await accountManager.fetchUsage()
                }
            }
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            switch accountManager.state {
            case .anonymous:
                Button {
                    showLogin = true
                } label: {
                    Label("Sign In to Agent Gateway", systemImage: "person.crop.circle.badge.plus")
                }
                Button {
                    Task {
                        do {
                            try await accountManager.registerAnonymous()
                        } catch {
                            print("匿名注册失败：", error)
                        }
                    }
                } label: {
                    Label("Continue as Guest", systemImage: "theatermasks")
                }

            case .authenticated(let info):
                HStack {
                    Label(info.email ?? info.userId, systemImage: "person.crop.circle.fill")
                    Spacer()
                    Text(info.subscriptionTier.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Sign Out", role: .destructive) {
                    Task { try? await accountManager.logout() }
                }

            case .expired(let info):
                Label("Session Expired", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(info.email ?? info.userId)
                    .foregroundStyle(.secondary)
                Button("Sign In Again") { showLogin = true }

            case .offline(let info):
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                Text(info.email ?? info.userId)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Provider Section

    @ViewBuilder
    private var providerSection: some View {
        Section("Models & Credentials") {
            // Provider mode
            Picker("Provider", selection: $credentialSettings.selectedProvider) {
                Text("Agent Gateway").tag(ProviderMode.gateway)
                Text("Bring Your Own Key").tag(ProviderMode.byok)
            }
            .pickerStyle(.segmented)

            if credentialSettings.selectedProvider == .byok {
                byokDetail
            }

            // Model selection — dynamic from Gateway when available
            Picker("Model", selection: $credentialSettings.model) {
                if let gatewayIDs = credentialSettings.gatewayModelIDs, !gatewayIDs.isEmpty {
                    ForEach(gatewayIDs, id: \.self) { modelID in
                        Text(credentialSettings.modelDisplayNames[modelID] ?? modelID)
                            .tag(modelID)
                    }
                } else {
                    ForEach(AgentSettings.availableModels, id: \.self) { model in
                        Text(model.isEmpty ? "Default" : model).tag(model)
                    }
                }
            }
            .onChange(of: credentialSettings.model) {
                credentialSettings.saveModel()
            }
        }
    }

    @ViewBuilder
    private var byokDetail: some View {
        ForEach(credentialSettings.byokProviders) { provider in
            HStack {
                Button {
                    credentialSettings.selectedBYOKName = provider.name
                } label: {
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        if provider.isConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                if provider.isConfigured {
                    Button(role: .destructive) {
                        Task { try? await credentialSettings.removeBYOKKey(provider.name) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        if let selectedName = credentialSettings.selectedBYOKName {
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key for \(selectedName.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if showKey {
                        TextField("sk-...", text: $credentialSettings.byokKey)
                    } else {
                        SecureField("sk-...", text: $credentialSettings.byokKey)
                    }
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Button("Save to Keychain") {
                    Task { try? await credentialSettings.saveBYOKKey() }
                }
                .disabled(credentialSettings.byokKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Legacy Section (hidden by default, for backward compat)

    @ViewBuilder
    private var legacySection: some View {
        Section {
            DisclosureGroup("Legacy Settings (DeepSeek API Key)") {
                Text("This is the legacy key path. Configure BYOK keys above for the recommended experience.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Usage Section

    @ViewBuilder
    private var usageSection: some View {
        if let usage = accountManager.usage {
            Section("Usage") {
                VStack(spacing: 12) {
                    HStack {
                        UsageMeter(
                            label: "Today",
                            used: usage.dailyUnits,
                            limit: nil
                        )
                        UsageMeter(
                            label: "Week",
                            used: usage.weeklyUnits,
                            limit: nil
                        )
                        UsageMeter(
                            label: "Month",
                            used: usage.monthlyUnits,
                            limit: usage.monthlyLimit
                        )
                    }

                    if let model = usage.currentModel {
                        LabeledContent("Model", value: model)
                    }
                    LabeledContent("Tier", value: usage.subscriptionTier.rawValue.capitalized)
                }
            }
        }
    }
}

// MARK: - Usage Meter

struct UsageMeter: View {
    let label: String
    let used: Int
    let limit: Int?

    var body: some View {
        VStack(spacing: 4) {
            Text(formatted(used))
                .font(.title3.bold())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let limit {
                ProgressView(value: Double(used), total: Double(limit))
                    .tint(used > limit ? .red : .blue)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formatted(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
