//
//  DeviceContext.swift
//  AgentKit
//
//  设备上下文 —— 稳定设备标识 + 平台信息。
//  X-Device-ID 生成一次存入 Keychain，之后永久使用同一值。
//

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - DeviceContext

/// 设备上下文，提供 Gateway 要求的设备 Header。
///
/// X-Device-ID 使用 UUID 在 Keychain 中持久化，首次生成后不再变化。
/// 这与 `UIDevice.identifierForVendor` 的区别：即使 app 被卸载重装，ID 仍然稳定。
public enum DeviceContext {

    private static let deviceIDKey = "device_id"
    private static let keychain = KeychainStore(service: "com.codeagent.device")

    // MARK: - Device ID

    /// 稳定不变的设备标识符。首次生成后持久化到 Keychain。
    public static var deviceID: String {
        if let existing = keychain.string(for: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        keychain.set(new, for: deviceIDKey)
        return new
    }

    // MARK: - Device Info

    /// 设备类型字符串（对应 Gateway 的 X-Device-Type）。
    public static var deviceType: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    /// 设备名称（如 "iPhone 16 Pro"）。
    public static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown"
        #endif
    }

    /// OS 版本（如 "18.0"）。
    public static var osVersion: String {
        #if os(iOS)
        return UIDevice.current.systemVersion
        #elseif os(macOS)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// App 版本。
    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0.0.0"
    }

    // MARK: - Header Injection

    /// 将设备 Header 注入到 URLRequest 中。
    /// - Parameter request: 目标请求（inout）
    public static func apply(to request: inout URLRequest) {
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(deviceType, forHTTPHeaderField: "X-Device-Type")
        request.setValue(deviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(osVersion, forHTTPHeaderField: "X-OS-Version")
        request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
    }
}
