//
//  PreviewRFC8785.swift
//  AgentKit
//
//  RFC 8785 JSON Canonicalization Scheme (JCS) used by the frozen
//  preview.artifact.v1 revision_sha256 contract.
//

import CryptoKit
import Foundation
import ClientToolProtocol

public enum PreviewRFC8785Error: Error, Equatable, Sendable {
    case invalidJSON
    case nonFiniteNumber
    case unsupportedValue
}

/// RFC 8785 canonical JSON serialization.
///
/// The implementation intentionally serializes `JSONValue` rather than using
/// `JSONSerialization` output directly: JCS fixes object-key ordering, string
/// escaping, and ECMAScript number formatting, all of which are required for
/// revision idempotency across runtimes.
public enum PreviewRFC8785 {
    public static func canonicalize(_ data: Data) throws -> Data {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw PreviewRFC8785Error.invalidJSON
        }
        return try canonicalize(value)
    }

    public static func canonicalize(_ value: JSONValue) throws -> Data {
        var output = String()
        try append(value, to: &output)
        return Data(output.utf8)
    }

    public static func sha256(_ value: JSONValue) throws -> String {
        try sha256(canonicalData: canonicalize(value))
    }

    public static func sha256(canonicalData: Data) -> String {
        sha256(data: canonicalData)
    }

    public static func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    private static func append(_ value: JSONValue, to output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .string(let value):
            appendString(value, to: &output)
        case .integer(let value):
            output += try canonicalNumber(Double(value))
        case .number(let value):
            output += try canonicalNumber(value)
        case .array(let values):
            output.append("[")
            for (index, item) in values.enumerated() {
                if index > 0 { output.append(",") }
                try append(item, to: &output)
            }
            output.append("]")
        case .object(let object):
            output.append("{")
            let keys = object.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(",") }
                appendString(key, to: &output)
                output.append(":")
                try append(object[key] ?? .null, to: &output)
            }
            output.append("}")
        }
    }

    private static func appendString(_ value: String, to output: inout String) {
        output.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x00...0x1F:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }

    /// ECMAScript `Number::toString` as required by RFC 8785.
    ///
    /// Swift's `Double.description` supplies the shortest round-tripping
    /// decimal digits. This function normalizes the notation boundary and
    /// exponent spelling to ECMAScript's rules: fixed notation for
    /// `1e-6 <= abs(value) < 1e21`, scientific notation otherwise.
    private static func canonicalNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw PreviewRFC8785Error.nonFiniteNumber }
        guard value != 0 else { return "0" }

        let negative = value < 0
        let text = String(abs(value)).lowercased()
        var mantissa = text
        var explicitExponent = 0
        if let exponentIndex = mantissa.firstIndex(of: "e") {
            let exponentText = String(mantissa[mantissa.index(after: exponentIndex)...])
            guard let parsed = Int(exponentText) else {
                throw PreviewRFC8785Error.unsupportedValue
            }
            explicitExponent = parsed
            mantissa = String(mantissa[..<exponentIndex])
        }

        let decimalIndex: Int
        if let pointIndex = mantissa.firstIndex(of: ".") {
            decimalIndex = mantissa.distance(from: mantissa.startIndex, to: pointIndex)
        } else {
            decimalIndex = mantissa.count
        }

        var digits = mantissa.filter { $0 != "." }
        var leadingZeros = 0
        while digits.first == "0" {
            digits.removeFirst()
            leadingZeros += 1
        }
        guard !digits.isEmpty else { return "0" }

        let scientificExponent = explicitExponent + decimalIndex - 1 - leadingZeros
        while digits.last == "0" {
            digits.removeLast()
        }

        let magnitude: String
        if scientificExponent >= 21 || scientificExponent <= -7 {
            let first = digits.first!
            let remainder = digits.dropFirst()
            magnitude = remainder.isEmpty
                ? "\(first)e\(scientificExponent >= 0 ? "+" : "")\(scientificExponent)"
                : "\(first).\(remainder)e\(scientificExponent >= 0 ? "+" : "")\(scientificExponent)"
        } else if scientificExponent >= 0 {
            let integerDigits = scientificExponent + 1
            if digits.count <= integerDigits {
                magnitude = digits + String(repeating: "0", count: integerDigits - digits.count)
            } else {
                let split = digits.index(digits.startIndex, offsetBy: integerDigits)
                magnitude = String(digits[..<split]) + "." + String(digits[split...])
            }
        } else {
            magnitude = "0." + String(repeating: "0", count: -scientificExponent - 1) + digits
        }

        return negative ? "-\(magnitude)" : magnitude
    }
}
