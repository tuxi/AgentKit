//
//  VoiceRecordingOverlay.swift
//  AgentKit
//
//  录音浮层 — 替换输入框区域，显示波形 + 时长 + 停止按钮。
//  Codex 风格：录音时不显示实时转写，只给用户"正在被倾听"的反馈。
//

import SwiftUI

/// 录音中/转写中的浮层，替换 DraftComposerPanel 的输入区域。
struct VoiceRecordingOverlay: View {
    @ObservedObject var service: VoiceInputService
    let onStop: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if case .transcribing = service.state {
                transcribingView
            } else {
                recordingView
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Recording

    private var recordingView: some View {
        HStack(spacing: 12) {
            // 波形
            WaveformBar(audioLevel: service.audioLevel)
                .frame(height: 38)
                .frame(maxWidth: .infinity)

            // 时长
            Text(formatDuration(service.recordingDuration))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            // 停止按钮
            Button {
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.red, in: Circle())
            .accessibilityLabel(AgentKitLocalized.string("composer.voice_input.stop_recording"))

            // 发送按钮
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.draftSendForeground)
            .background(Color.draftSendBackground, in: Circle())
            .accessibilityLabel(AgentKitLocalized.string("composer.send"))
        }
    }

    // MARK: - Transcribing

    private var transcribingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(AgentKitLocalized.string("composer.voice_input.processing"))
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(height: 44)
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Waveform Bar

/// 简易音频波形条 — 用 16 根竖条模拟，高度随 audioLevel 变化。
private struct WaveformBar: View {
    let audioLevel: Float

    private let barCount = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 2.5)
                    .frame(height: barHeight(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: audioLevel)
    }

    private func barHeight(for index: Int) -> CGFloat {
        // 用 index 和 audioLevel 生成一个自然的波动
        let base: Float = 0.12
        // 中间高、两端低
        let positionFactor = 1.0 - abs(Float(index) - Float(barCount) / 2.0) / Float(barCount) * 1.6
        // 随机种子让每个波形看起来不一样
        let seed = sin(Float(index) * 1.7 + Float(Int(audioLevel * 100)) * 0.3)
        let variation = (seed * 0.15 + audioLevel * 0.7 + base) * max(0, positionFactor)
        return CGFloat(max(4, variation * 38))
    }
}
