//
//  VoiceInputService.swift
//  AgentKit
//
//  语音输入服务：录后转写模式（Codex 风格）。
//  录音到临时文件 → 停止后用 SFSpeechURLRecognitionRequest 一次性识别，
//  彻底避免实时流式识别中 utterance 重置导致的文本覆盖/重复问题。
//

import Foundation
import Combine
@preconcurrency import Speech
@preconcurrency import AVFoundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public final class VoiceInputService: ObservableObject, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case recording
        case transcribing
        case error(String)
    }

    // MARK: - Published

    @Published public private(set) var state: State = .idle
    @Published public private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    /// 当前录音已持续秒数（每秒更新一次）。
    @Published public private(set) var recordingDuration: TimeInterval = 0

    /// 音频电平 0.0~1.0，供波形动画使用（录音时 ~10Hz 更新）。
    @Published public private(set) var audioLevel: Float = 0

    // MARK: - Callbacks (主线程调用)

    public var onTranscriptionComplete: ((String) -> Void)?

    // MARK: - Internal

    private let speechRecognizer: SFSpeechRecognizer?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var durationTimer: Timer?
    private var levelTimer: Timer?

    // MARK: - Init

    public init() {
        self.speechRecognizer = SFSpeechRecognizer()
        speechRecognizer?.supportsOnDeviceRecognition = true
    }

    // MARK: - Public API

    /// 请求语音识别 + 麦克风权限（两者都必须授权才返回 true）。
    /// macOS 上 Speech 与 Microphone 是两套独立的 TCC 权限，必须分别请求；
    /// 仅 SFSpeechRecognizer.requestAuthorization 返回 .authorized 不代表麦克风可用。
    public func requestAuthorization() async -> Bool {
        // 1. 请求语音识别权限
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        await updateOnMain { self.authorizationStatus = speechStatus }

        // 2. 请求麦克风权限（iOS / macOS 均需显式请求）
        //    macOS 上不能依赖 AVAudioRecorder.record() 隐式触发弹窗，
        //    必须调用 AVAudioApplication.requestRecordPermission() 驱动 TCC 状态机。
        let micAuthorized = await requestMicrophonePermission()

        return speechStatus == .authorized && micAuthorized
    }

    /// 开始录音。
    public func startRecording() async {
        let current = await readOnMain { self.state }
        guard current != .recording else { return }

        await updateOnMain {
            self.recordingDuration = 0
            self.audioLevel = 0
            self.state = .preparing
        }

        let authorized = await requestAuthorization()
        guard authorized else {
            await updateOnMain { self.state = .error(AgentKitLocalized.string("composer.voice_input.no_permission")) }
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            await updateOnMain { self.state = .error(AgentKitLocalized.string("composer.voice_input.no_speech_recognition")) }
            return
        }

        // 麦克风权限已在上方 requestAuthorization() 中统一请求（iOS / macOS 均包含），
        // 此处不再重复请求。

        do {
            try startAudioSession()
            try beginAudioRecording()

            // 验证录音确实已启动
            guard let recorder = audioRecorder, recorder.isRecording else {
                await updateOnMain { self.state = .error(AgentKitLocalized.string("composer.voice_input.no_permission")) }
                return
            }

            // 验证实际捕获到非静音音频。
            // macOS 上当麦克风 TCC 权限为 .denied / .notDetermined 时，
            // AVAudioRecorder.isRecording 仍为 true，但录制的是全零静音数据，
            // 导致后续语音识别必然失败。此处通过电平检测主动拦截。
            try? await Task.sleep(nanoseconds: 300_000_000)
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            // -50dB 以下视为静音（正常环境底噪通常在 -35dB ~ -10dB）
            if power < -50 {
                print("[VoiceInput] silence detected after 0.3s: power=\(power)dB — microphone permission likely denied or input device unavailable")
                recorder.stop()
                self.audioRecorder = nil
                self.cleanupRecordingFile()
                await updateOnMain { self.state = .error(AgentKitLocalized.string("composer.voice_input.no_permission")) }
                return
            }

            await updateOnMain {
                self.state = .recording
                self.startTimers()
            }
        } catch {
            await updateOnMain { self.state = .error(error.localizedDescription) }
        }
    }

    /// 停止录音并开始转写。完成后通过 `onTranscriptionComplete` 回调传递文本。
    public func stopRecordingAndTranscribe() {
        guard state == .recording else { return }

        // 停止录音
        stopTimers()
        audioRecorder?.stop()
        audioRecorder = nil

        guard let url = recordingURL, FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async { [weak self] in
                self?.state = .idle
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.state = .transcribing
        }

        // 文件级识别
        guard let recognizer = speechRecognizer else {
            DispatchQueue.main.async { [weak self] in self?.state = .idle }
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // macOS 上 on-device 识别可能不适用（语言包未下载等），允许回退到服务端。
#if os(macOS)
        request.requiresOnDeviceRecognition = false
#else
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
#endif

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // 识别错误：记录并通知用户
            if let error {
                let nsError = error as NSError
                print("[VoiceInput] recognition error: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
                let message = nsError.localizedDescription
                DispatchQueue.main.async {
                    self.state = .error(message.isEmpty ? "Speech recognition failed" : message)
                    self.stopAudioSession()
                }
                self.cleanupRecordingFile()
                return
            }

            let transcript = result?.bestTranscription.formattedString ?? ""

            DispatchQueue.main.async {
                self.state = .idle
                self.stopAudioSession()

                if !transcript.isEmpty {
                    self.onTranscriptionComplete?(transcript)
                }
            }

            self.cleanupRecordingFile()
        }
    }

    /// 取消录音（丢弃录音文件）。
    public func cancelRecording() {
        guard state == .recording || state == .preparing else { return }

        stopTimers()
        audioRecorder?.stop()
        audioRecorder = nil

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        stopAudioSession()

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = 0
            self?.recordingDuration = 0
            self?.state = .idle
        }
    }

    public func reset() {
        cancelRecording()
        DispatchQueue.main.async { [weak self] in
            self?.state = .idle
        }
    }

    /// 打开系统设置中对应平台麦克风/语音识别权限页面。
    public static func openSystemSettings() {
#if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
#elseif os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#endif
    }

    // MARK: - Private: Recording

    private func beginAudioRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "agentkit_voice_\(UUID().uuidString).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        self.recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record()
        self.audioRecorder = recorder
    }

    private func startTimers() {
        let startTime = Date()

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, self.state == .recording else { return }
            recorder.updateMeters()
            let level = recorder.averagePower(forChannel: 0)
            // 归一化: -60dB ~ 0dB → 0.0 ~ 1.0
            let normalized = max(0, min(1, (level + 60) / 60))
            DispatchQueue.main.async {
                self.audioLevel = normalized
            }
        }
    }

    private func cleanupRecordingFile() {
        guard let url = recordingURL else { return }
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil
    }

    private func stopTimers() {
        durationTimer?.invalidate()
        durationTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Private: Permissions

    private func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Private: Audio Session

    private func startAudioSession() throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif
        // macOS 上无 AVAudioSession（该 API 仅 iOS/tvOS/watchOS 可用），
        // AVAudioRecorder 会自行通过 CoreAudio 管理输入路由，无需显式配置。
    }

    private func stopAudioSession() {
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    // MARK: - Private: Main thread helpers

    private func updateOnMain(_ block: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                block()
                continuation.resume()
            }
        }
    }

    private func readOnMain<T>(_ block: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: block())
            }
        }
    }
}
