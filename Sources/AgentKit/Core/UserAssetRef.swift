//
//  UserAssetRef.swift
//  AgentKit
//
//  Gateway-managed user attachment references from Agent Wire v1.5.
//  This type is intentionally separate from the v1.3 AgentAssetRef tool-output schema.
//

import Foundation
import ClientToolProtocol

public struct UserAssetRef: Sendable, Hashable, Codable, Identifiable {
    public let assetID: Int64
    public let sha256: String?
    public let kind: String
    public let mimeType: String
    public let filename: String

    public var id: Int64 { assetID }

    public init(
        assetID: Int64,
        sha256: String? = nil,
        kind: String = "image",
        mimeType: String,
        filename: String
    ) {
        self.assetID = assetID
        self.sha256 = sha256
        self.kind = kind
        self.mimeType = mimeType
        self.filename = filename
    }

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case sha256, kind
        case mimeType = "mime_type"
        case filename
    }

    public func validate() throws {
        guard assetID > 0 else { throw UserAssetValidationError.invalidAssetID(assetID) }
        guard kind == "image" else { throw UserAssetValidationError.unsupportedKind(kind) }
        guard mimeType == "image/jpeg" || mimeType == "image/png" else {
            throw UserAssetValidationError.unsupportedMIMEType(mimeType)
        }
        if let sha256 {
            let isValid = sha256.utf8.count == 64
                && sha256.utf8.allSatisfy { byte in
                    (48...57).contains(byte) || (97...102).contains(byte)
                }
            guard isValid else { throw UserAssetValidationError.invalidSHA256 }
        }
        let filenameBytes = filename.utf8.count
        guard (1...255).contains(filenameBytes),
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains("\0"),
              filename != ".",
              filename != ".."
        else { throw UserAssetValidationError.invalidFilename }
    }
}

/// Workspace-relative attachment reference consumed by the local Runtime.
///
/// The host stages picker-owned files into the conversation's final workspace
/// before this value is created. No security-scoped URL or absolute path crosses
/// Agent Wire.
public struct LocalUserAssetRef: Sendable, Hashable, Codable, Identifiable {
    public enum TransferPolicy: String, Sendable, Hashable, Codable {
        case localOnly = "local_only"
    }

    public let id: String
    public let relativePath: String
    public let filename: String
    public let mimeType: String
    public let kind: String
    public let sizeBytes: Int64
    public let sha256: String
    public let transferPolicy: TransferPolicy

    public init(
        id: String,
        relativePath: String,
        filename: String,
        mimeType: String,
        kind: String,
        sizeBytes: Int64,
        sha256: String,
        transferPolicy: TransferPolicy = .localOnly
    ) {
        self.id = id
        self.relativePath = relativePath
        self.filename = filename
        self.mimeType = mimeType
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.transferPolicy = transferPolicy
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, kind, sha256
        case relativePath = "relative_path"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case transferPolicy = "transfer_policy"
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil else {
            throw LocalUserAssetValidationError.invalidID
        }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0")
        else {
            throw LocalUserAssetValidationError.invalidRelativePath
        }
        let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw LocalUserAssetValidationError.invalidRelativePath
        }
        let filenameBytes = filename.utf8.count
        guard (1...255).contains(filenameBytes),
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains("\0"),
              filename != ".",
              filename != "..",
              pathComponents.last == Substring(filename)
        else {
            throw LocalUserAssetValidationError.invalidFilename
        }
        guard !mimeType.isEmpty,
              mimeType.contains("/"),
              !mimeType.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw LocalUserAssetValidationError.invalidMIMEType
        }
        guard !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalUserAssetValidationError.invalidKind
        }
        guard sizeBytes >= 0 else {
            throw LocalUserAssetValidationError.invalidSize
        }
        let isValidSHA = sha256.utf8.count == 64
            && sha256.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        guard isValidSHA else {
            throw LocalUserAssetValidationError.invalidSHA256
        }
        guard transferPolicy == .localOnly else {
            throw LocalUserAssetValidationError.invalidTransferPolicy
        }
    }
}

public enum LocalUserAssetValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidID
    case invalidRelativePath
    case invalidFilename
    case invalidMIMEType
    case invalidKind
    case invalidSize
    case invalidSHA256
    case invalidTransferPolicy
    case duplicateID(String)
    case duplicateRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidID: return "本地附件 ID 无效"
        case .invalidRelativePath: return "本地附件路径必须位于工作区内"
        case .invalidFilename: return "本地附件文件名无效"
        case .invalidMIMEType: return "本地附件 MIME 类型无效"
        case .invalidKind: return "本地附件类型无效"
        case .invalidSize: return "本地附件大小无效"
        case .invalidSHA256: return "本地附件摘要格式无效"
        case .invalidTransferPolicy: return "本地附件传输策略无效"
        case .duplicateID: return "同一轮不能重复添加同一本地附件"
        case .duplicateRelativePath: return "同一轮不能重复引用同一工作区文件"
        }
    }
}

public enum UserAssetValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidAssetID(Int64)
    case unsupportedKind(String)
    case unsupportedMIMEType(String)
    case invalidSHA256
    case invalidFilename
    case duplicateAssetID(Int64)
    case tooManyAssets(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAssetID: return "图片资产 ID 无效"
        case .unsupportedKind: return "当前版本只支持图片附件"
        case .unsupportedMIMEType: return "当前版本只支持 JPEG 和 PNG"
        case .invalidSHA256: return "图片摘要格式无效"
        case .invalidFilename: return "图片文件名无效"
        case .duplicateAssetID: return "同一轮不能重复添加同一图片"
        case .tooManyAssets: return "每轮最多发送 4 张图片"
        }
    }
}

public struct AgentInputRejection: Sendable, Equatable, Error, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Host hook for resolving an ephemeral thumbnail/read URL. Returned URLs are
/// presentation-only and must never be persisted into Agent Wire history.
public protocol UserAssetPreviewResolving: Sendable {
    func previewURL(for asset: UserAssetRef) async throws -> URL
}

/// Host hook for resolving a staged workspace attachment for native/Web
/// presentation. The returned URL is consumed through a controlled native
/// bridge and is never serialized into conversation history.
public protocol LocalUserAssetPreviewResolving: Sendable {
    func previewURL(
        for asset: LocalUserAssetRef,
        conversationID: String,
        workspaceRoot: URL
    ) async throws -> URL
}

/// Host hook for resolving a local, ephemeral composer thumbnail while an
/// attachment is still preparing or uploading. `resourceURI` may be an opaque
/// picker token, so AgentKit must not assume it is a directly readable file URL.
public protocol UserAssetDraftPreviewResolving: Sendable {
    func previewURL(for attachment: DraftAttachmentReference) async throws -> URL
}

/// Host boundary for importing picker-owned files into a conversation workspace.
///
/// Implementations own security-scoped access, filename sanitization, hashing,
/// deduplication, no-overwrite semantics, and symlink-safe containment checks.
/// The returned reference must already point at a durable file below
/// `workspaceRoot`.
public protocol LocalUserAssetStaging: Sendable {
    func stage(
        attachment: DraftAttachmentReference,
        workspaceRoot: URL
    ) async throws -> LocalUserAssetRef
}

public typealias UserAssetPicking = @MainActor @Sendable () async throws -> [DraftAttachmentReference]
