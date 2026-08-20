//
//  RuntimeSharingBase64.swift
//  AgentKit
//

import Foundation

/// Decodes the 32-byte SHA-256 values used by the daemon. Go's
/// base64.RawStdEncoding omits padding, while Foundation's default decoder
/// historically required padding on some OS releases.
func decodeRuntimeSHA256(_ value: String) -> Data? {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    normalized.append(
        String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    )
    guard let data = Data(base64Encoded: normalized), data.count == 32 else {
        return nil
    }
    return data
}
