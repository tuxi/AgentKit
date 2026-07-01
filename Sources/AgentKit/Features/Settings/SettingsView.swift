//
//  SettingsView.swift
//  AgentKit
//
//  设置页：填入 DeepSeek API key（存 Keychain）、选择模型。
//  保存后在 iOS 上热重载内嵌 runtime 配置，不换端口、不打断 WS。
//

import SwiftUI

public struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AgentSettingsStore()
    @State private var showKey = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        keyField
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("DeepSeek API Key")
                } footer: {
                    Text("存于设备钥匙串（Keychain），不会上传、不进源码。")
                }

                Section("模型") {
                    Picker("模型", selection: $settings.model) {
                        ForEach(AgentSettings.availableModels, id: \.self) { model in
                            Text(model.isEmpty ? "默认" : model).tag(model)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveAndDismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var keyField: some View {
        if showKey {
            TextField("sk-…", text: $settings.apiKey)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            SecureField("sk-…", text: $settings.apiKey)
        }
    }

    private func saveAndDismiss() {
        settings.save()
        #if os(iOS)
        // v1.2: 热切配置，不换端口。runtime 尚未启动时，下次 launch 会读取已保存设置。
        try? AgentRuntime.shared.reconfigure(
            secretsJSON: AgentSettings.secretsJSON(),
            modelName: AgentSettings.model
        )
        #endif
        dismiss()
    }
}
