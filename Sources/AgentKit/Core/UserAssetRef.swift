//
//  UserAssetRef.swift
//  AgentKit
//
//  Gateway-managed user attachment references from Agent Wire v1.5.
//  This type is intentionally separate from the v1.3 AgentAssetRef tool-output schema.
//

import Foundation

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

/// Host hook for resolving a local, ephemeral composer thumbnail while an
/// attachment is still preparing or uploading. `resourceURI` may be an opaque
/// picker token, so AgentKit must not assume it is a directly readable file URL.
public protocol UserAssetDraftPreviewResolving: Sendable {
    func previewURL(for attachment: DraftAttachmentReference) async throws -> URL
}

public typealias UserAssetPicking = @MainActor @Sendable () async throws -> [DraftAttachmentReference]
