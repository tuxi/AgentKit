//
//  RuntimeSharedDeviceRegistry.swift
//  AgentKit
//

import Foundation
import Observation

@MainActor
@Observable
public final class RuntimeSharedDeviceRegistry {
    public private(set) var devices: [RuntimeSharedDevice]

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let account = "paired-devices/v1"

    public init(
        keychain: KeychainStore = KeychainStore(
            service: "com.agentkit.runtime-sharing"
        )
    ) {
        self.keychain = keychain
        if let value = keychain.string(for: account),
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder.runtimeSharing.decode(
               [RuntimeSharedDevice].self,
               from: data
           ) {
            self.devices = decoded
        } else {
            self.devices = []
        }
    }

    public var activeDevices: [RuntimeSharedDevice] {
        devices.filter { $0.revokedAt == nil }
    }

    func persist(enrollment: RuntimePendingSharedEnrollment) throws {
        let device = RuntimeSharedDevice(
            deviceID: enrollment.deviceID,
            credentialSHA256: enrollment.credentialSHA256,
            displayName: enrollment.deviceName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty ?? "Paired Device",
            platform: enrollment.platform ?? "unknown",
            pairedAt: Date(),
            revokedAt: nil
        )
        if let index = devices.firstIndex(where: { $0.deviceID == device.deviceID }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        try save()
    }

    public func rename(deviceID: String, displayName: String) throws {
        guard let index = devices.firstIndex(where: { $0.deviceID == deviceID }) else {
            return
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        devices[index].displayName = trimmed
        try save()
    }

    func markRevoked(deviceID: String) throws {
        guard let index = devices.firstIndex(where: { $0.deviceID == deviceID }) else {
            return
        }
        devices[index].revokedAt = Date()
        try save()
    }

    public func removeRevoked(deviceID: String) throws {
        devices.removeAll {
            $0.deviceID == deviceID && $0.revokedAt != nil
        }
        try save()
    }

    func validationRecords() -> [RuntimeSharedDeviceValidationRecord] {
        activeDevices.map {
            RuntimeSharedDeviceValidationRecord(
                deviceID: $0.deviceID,
                credentialSHA256: $0.credentialSHA256
            )
        }
    }

    private func save() throws {
        guard let data = try? JSONEncoder.runtimeSharing.encode(devices),
              let encoded = String(data: data, encoding: .utf8),
              keychain.set(encoded, for: account) else {
            throw RuntimeSharingError.keychainWriteFailed
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
