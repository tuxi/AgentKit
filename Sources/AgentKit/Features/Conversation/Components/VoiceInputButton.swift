//
//  VoiceInputButton.swift
//  AgentKit
//
//  语音输入按钮 — 录后转写模式。
//  .idle → 点击开始录音 / .recording → 点击停止并转写。
//  .error → 点击弹出引导去系统设置开启权限。
//

import SwiftUI

public struct VoiceInputButton: View {
    @ObservedObject var service: VoiceInputService

    public init(service: VoiceInputService) {
        self.service = service
    }

    public var body: some View {
        Button {
            handleTap()
        } label: {
            buttonLabel
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .accessibilityLabel(accessibilityLabel)
        .disabled(service.state == .preparing || service.state == .transcribing)
        
#if os(macOS)
        .help(tooltip)
#endif
    }

    // MARK: - Label

    @ViewBuilder
    private var buttonLabel: some View {
        switch service.state {
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: iconSize, weight: .medium))
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        case .recording:
            let pulsing = service.state == .recording
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulsing ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)

                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.red)
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        case .error:
            Image(systemName: "mic.slash")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Helpers

    private var iconSize: CGFloat {
#if os(macOS)
        15
#else
        17
#endif
    }

    private var foregroundColor: Color {
        switch service.state {
        case .idle:                     return .secondary
        case .recording:                return .red
        case .error:                    return .orange
        case .preparing, .transcribing: return .secondary.opacity(0.6)
        }
    }

    private var accessibilityLabel: String {
        switch service.state {
        case .idle:          return AgentKitLocalized.string("composer.voice_input")
        case .preparing:     return AgentKitLocalized.string("composer.voice_input.preparing")
        case .recording:     return AgentKitLocalized.string("composer.voice_input.recording")
        case .transcribing:  return AgentKitLocalized.string("composer.voice_input.processing")
        case .error:         return AgentKitLocalized.string("composer.voice_input")
        }
    }

    private var tooltip: String {
        switch service.state {
        case .idle:    return AgentKitLocalized.string("composer.voice_input")
        case .recording: return AgentKitLocalized.string("composer.voice_input.stop_recording")
        case .error:   return AgentKitLocalized.string("composer.voice_input.no_permission")
        default:       return ""
        }
    }

    // MARK: - Action

    private func handleTap() {
        switch service.state {
        case .idle:
            Task { @MainActor [weak service] in
                await service?.startRecording()
            }
        case .error:
            // 再次点击时重新尝试录音（用户可能已从设置返回），若仍失败会再次触发 .error → 弹窗
            Task { @MainActor [weak service] in
                await service?.startRecording()
            }
        case .recording:
            service.stopRecordingAndTranscribe()
        case .preparing, .transcribing:
            break
        }
    }
}
