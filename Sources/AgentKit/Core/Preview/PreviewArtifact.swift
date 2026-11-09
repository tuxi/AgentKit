//
//  PreviewArtifact.swift
//  AgentKit
//
//  Canonical preview.artifact.v1 model, event correlation, revision merge,
//  client presentation state, producer drafts, and transport-neutral resolvers.
//

import Foundation
import ClientToolProtocol

// MARK: - Artifact vocabulary

public enum PreviewArtifactStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case ready
    case failed
    case unavailable
}

public enum PreviewArtifactKind: String, Codable, Sendable, Hashable, CaseIterable {
    case interactiveHTML = "interactive_html"
    case staticImage = "static_image"
}

public enum PreviewArtifactAssetRole: String, Codable, Sendable, Hashable, CaseIterable {
    case primary
    case fallback
}

public enum PreviewPresentationState: String, Sendable, Hashable, CaseIterable {
    case loading
    case interactiveReady
    case staticFallback
    case unavailable
    case renderFailed
    case expired
}

// MARK: - Artifact error

/// The frozen `{code, message, retryable}` error shape used by runtime failed
/// and unavailable artifacts and by the preview HTTP envelope's `data.error`.
public struct PreviewArtifactError: Codable, Sendable, Equatable, Error, LocalizedError {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? { message }

    static func invalidArtifact(_ message: String) -> PreviewArtifactError {
        PreviewArtifactError(code: "preview_invalid_artifact", message: message)
    }

    static func securityViolation(_ message: String) -> PreviewArtifactError {
        PreviewArtifactError(code: "preview_security_violation", message: message)
    }
}

// MARK: - Artifact payloads

public struct PreviewArtifactPresentation: Codable, Sendable, Equatable {
    public let placement: String?
    public let preferredAspectRatio: Double?
    public let minHeight: Int?
    public let initialState: String?

    enum CodingKeys: String, CodingKey {
        case placement
        case preferredAspectRatio = "preferred_aspect_ratio"
        case minHeight = "min_height"
        case initialState = "initial_state"
    }
}

public struct PreviewArtifactViewer: Codable, Sendable, Equatable {
    public let url: String
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case url, sha256
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }
}

public struct PreviewArtifactAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: String { assetID }

    public let assetID: String
    public let role: PreviewArtifactAssetRole
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String
    public let contentURL: String
    public let width: Int?
    public let height: Int?
    public let alt: String?
    public let workspaceRelativePath: String?

    enum CodingKeys: String, CodingKey {
        case role, width, height, alt, sha256
        case assetID = "asset_id"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case contentURL = "content_url"
        case workspaceRelativePath = "workspace_relative_path"
    }
}

public struct PreviewArtifactFallback: Codable, Sendable, Equatable {
    public let assetID: String
    public let text: String

    enum CodingKeys: String, CodingKey {
        case text
        case assetID = "asset_id"
    }
}

public struct PreviewArtifactSecurity: Codable, Sendable, Equatable {
    public let profile: String
    public let javascript: String
    public let network: String
    public let navigation: String
    public let persistentData: String
    public let actions: String

    enum CodingKeys: String, CodingKey {
        case profile, javascript, network, navigation, actions
        case persistentData = "persistent_data"
    }
}

// MARK: - Canonical artifact

public struct PreviewArtifact: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = "preview.artifact.v1"
    public static let maximumViewerBytes = 2 * 1024 * 1024

    public var id: String { artifactID }

    public let schemaVersion: String
    public let artifactID: String
    public let revision: Int
    public let revisionSHA256: String
    public let status: PreviewArtifactStatus
    public let kind: PreviewArtifactKind
    public let title: String
    public let summary: String?
    public let capability: String
    public let producerID: String
    public let sessionID: String
    public let turnID: String
    public let callID: String?
    public let createdAt: String
    public let updatedAt: String
    public let expiresAt: String?
    public let presentation: PreviewArtifactPresentation?
    public let viewer: PreviewArtifactViewer?
    public let assets: [PreviewArtifactAsset]
    public let fallback: PreviewArtifactFallback?
    public let security: PreviewArtifactSecurity?
    public let error: PreviewArtifactError?
    public let metadata: JSONValue

    enum CodingKeys: String, CodingKey {
        case revision, status, kind, title, summary, capability, viewer, assets
        case fallback, security, error, metadata, presentation
        case schemaVersion = "schema_version"
        case artifactID = "artifact_id"
        case revisionSHA256 = "revision_sha256"
        case producerID = "producer_id"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case callID = "call_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        artifactID = try container.decode(String.self, forKey: .artifactID)
        revision = try container.decode(Int.self, forKey: .revision)
        revisionSHA256 = try container.decode(String.self, forKey: .revisionSHA256)
        status = try container.decode(PreviewArtifactStatus.self, forKey: .status)
        kind = try container.decode(PreviewArtifactKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        capability = try container.decode(String.self, forKey: .capability)
        producerID = try container.decode(String.self, forKey: .producerID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        turnID = try container.decode(String.self, forKey: .turnID)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        presentation = try container.decodeIfPresent(PreviewArtifactPresentation.self, forKey: .presentation)
        viewer = try container.decodeIfPresent(PreviewArtifactViewer.self, forKey: .viewer)
        assets = try container.decodeIfPresent([PreviewArtifactAsset].self, forKey: .assets) ?? []
        fallback = try container.decodeIfPresent(PreviewArtifactFallback.self, forKey: .fallback)
        security = try container.decodeIfPresent(PreviewArtifactSecurity.self, forKey: .security)
        error = try container.decodeIfPresent(PreviewArtifactError.self, forKey: .error)
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
    }

    /// Canonical entry point. The raw JSON value is retained for hashing so
    /// unknown forward-compatible fields participate in revision identity even
    /// though they do not affect typed presentation.
    public static func decode(_ value: JSONValue) throws -> PreviewArtifact {
        guard case .object(var canonicalObject) = value else {
            throw PreviewArtifactError.invalidArtifact("Preview artifact must be a JSON object.")
        }
        guard let declaredHashValue = canonicalObject["revision_sha256"],
              case .string(let declaredHash) = declaredHashValue,
              isSHA256Token(declaredHash) else {
            throw PreviewArtifactError.invalidArtifact("revision_sha256 is missing or malformed.")
        }

        canonicalObject.removeValue(forKey: "revision_sha256")
        let calculatedHash = try PreviewRFC8785.sha256(.object(canonicalObject))
        guard constantTimeEqual(declaredHash.lowercased(), calculatedHash.lowercased()) else {
            throw PreviewArtifactError.invalidArtifact("revision_sha256 does not match the canonical artifact.")
        }

        let artifact: PreviewArtifact
        do {
            let data = try JSONEncoder().encode(value)
            artifact = try JSONDecoder().decode(PreviewArtifact.self, from: data)
        } catch {
            throw PreviewArtifactError.invalidArtifact("Preview artifact fields are malformed.")
        }
        try artifact.validate()
        return artifact
    }

    public static func decode(data: Data) throws -> PreviewArtifact {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw PreviewArtifactError.invalidArtifact("Preview artifact is not valid UTF-8 JSON.")
        }
        return try decode(value)
    }

    public var fallbackAsset: PreviewArtifactAsset? {
        guard let fallback else { return nil }
        return assets.first { $0.assetID == fallback.assetID && $0.role == .fallback }
    }

    public var hasFallback: Bool { fallbackAsset != nil }

    public var expiresAtDate: Date? {
        expiresAt.flatMap(Self.parseISO8601)
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAtDate else { return false }
        return date >= expiresAtDate
    }

    /// Runtime status and client presentation are deliberately separate. This
    /// derivation applies the frozen precedence table without mutating the
    /// artifact or creating a client-side revision.
    public func presentationState(
        at date: Date = Date(),
        capabilities: PreviewCapabilityNegotiation,
        isHistorical: Bool = false
    ) -> PreviewPresentationState {
        guard capabilities.contractAvailable else { return .unavailable }

        switch status {
        case .pending:
            return .loading
        case .failed:
            return hasFallback ? .staticFallback : .unavailable
        case .unavailable:
            return hasFallback ? .staticFallback : .unavailable
        case .ready:
            switch kind {
            case .staticImage:
                return capabilities.staticAvailable ? .staticFallback : .unavailable
            case .interactiveHTML:
                guard hasFallback else { return .unavailable }
                if isExpired(at: date) { return .expired }
                if isHistorical && !capabilities.replayAvailable {
                    return .staticFallback
                }
                if capabilities.interactiveAvailable {
                    return .interactiveReady
                }
                return .staticFallback
            }
        }
    }

    private func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw PreviewArtifactError.invalidArtifact("Unsupported preview artifact schema_version.")
        }
        guard !artifactID.trimmed.isEmpty,
              previewPathComponentIsSafe(artifactID),
              previewPathComponentIsSafe(sessionID),
              revision > 0,
              !title.trimmed.isEmpty,
              !capability.trimmed.isEmpty,
              !producerID.trimmed.isEmpty,
              !sessionID.trimmed.isEmpty,
              !turnID.trimmed.isEmpty else {
            throw PreviewArtifactError.invalidArtifact("Preview artifact identity is incomplete.")
        }
        guard Self.parseISO8601(createdAt) != nil,
              Self.parseISO8601(updatedAt) != nil,
              expiresAt.map({ Self.parseISO8601($0) != nil }) ?? true else {
            throw PreviewArtifactError.invalidArtifact("Preview artifact timestamps are malformed.")
        }
        guard isSHA256Token(revisionSHA256) else {
            throw PreviewArtifactError.invalidArtifact("revision_sha256 is malformed.")
        }

        if let presentation {
            if let placement = presentation.placement, placement != "conversation_inline" {
                throw PreviewArtifactError.invalidArtifact("Unsupported preview placement.")
            }
            if let ratio = presentation.preferredAspectRatio, !ratio.isFinite || ratio <= 0 {
                throw PreviewArtifactError.invalidArtifact("preferred_aspect_ratio must be positive.")
            }
            if let height = presentation.minHeight, height <= 0 {
                throw PreviewArtifactError.invalidArtifact("min_height must be positive.")
            }
            if let state = presentation.initialState, !["collapsed", "expanded"].contains(state) {
                throw PreviewArtifactError.invalidArtifact("Unsupported initial preview state.")
            }
        }

        if let viewer {
            try validateViewer(viewer)
        }
        try validateAssets()

        if let security {
            guard security.profile == "preview.security.v1",
                  security.javascript == "isolated_only",
                  security.network == "deny",
                  security.navigation == "deny",
                  security.persistentData == "deny",
                  security.actions == "none" else {
                throw PreviewArtifactError.securityViolation("Preview security profile is not supported.")
            }
        }

        switch (status, kind) {
        case (.pending, _):
            break
        case (.ready, .interactiveHTML):
            guard viewer != nil, security != nil, fallback != nil, fallbackAsset != nil else {
                throw PreviewArtifactError.invalidArtifact("Ready interactive preview is missing viewer, security, or fallback.")
            }
        case (.ready, .staticImage):
            guard assets.contains(where: { $0.role == .primary }) else {
                throw PreviewArtifactError.invalidArtifact("Ready static preview is missing a primary image.")
            }
        case (.failed, _), (.unavailable, _):
            guard let error else {
                throw PreviewArtifactError.invalidArtifact("Failed or unavailable preview is missing error.")
            }
            guard !error.code.trimmed.isEmpty,
                  !error.message.trimmed.isEmpty,
                  error.message.utf8.count <= 1024 else {
                throw PreviewArtifactError.invalidArtifact("Preview error is malformed.")
            }
        }
    }

    private func validateViewer(_ viewer: PreviewArtifactViewer) throws {
        let expectedRoute = "/v1/conversations/\(sessionID)/previews/\(artifactID)/revisions/\(revision)/viewer"
        guard viewer.url == expectedRoute, Self.isRuntimeRelativeRoute(viewer.url) else {
            throw PreviewArtifactError.securityViolation("Viewer URL is not the canonical artifact revision route.")
        }
        guard viewer.mimeType.lowercased() == "text/html; charset=utf-8" else {
            throw PreviewArtifactError.invalidArtifact("Viewer MIME type is not trusted HTML.")
        }
        guard viewer.sizeBytes > 0, viewer.sizeBytes <= Self.maximumViewerBytes else {
            throw PreviewArtifactError.invalidArtifact("Viewer size is outside the v1 boundary.")
        }
        guard isSHA256Token(viewer.sha256) else {
            throw PreviewArtifactError.invalidArtifact("Viewer sha256 is malformed.")
        }
    }

    private func validateAssets() throws {
        var seen = Set<String>()
        for asset in assets {
            guard !asset.assetID.trimmed.isEmpty,
                  previewPathComponentIsSafe(asset.assetID),
                  seen.insert(asset.assetID).inserted else {
                throw PreviewArtifactError.invalidArtifact("Preview asset IDs must be non-empty and unique.")
            }
            guard ["image/png", "image/jpeg", "image/webp"].contains(asset.mimeType.lowercased()) else {
                throw PreviewArtifactError.securityViolation("Preview asset MIME type is not allowlisted.")
            }
            guard asset.sizeBytes > 0, isSHA256Token(asset.sha256) else {
                throw PreviewArtifactError.invalidArtifact("Preview asset metadata is malformed.")
            }
            let expectedRoute = "/v1/conversations/\(sessionID)/previews/\(artifactID)/revisions/\(revision)/assets/\(asset.assetID)/content"
            guard asset.contentURL == expectedRoute, Self.isRuntimeRelativeRoute(asset.contentURL) else {
                throw PreviewArtifactError.securityViolation("Preview asset content URL is not the canonical revision route.")
            }
            guard asset.alt?.trimmed.isEmpty == false else {
                throw PreviewArtifactError.invalidArtifact("Preview image assets require alt text.")
            }
            if let width = asset.width, width <= 0 {
                throw PreviewArtifactError.invalidArtifact("Preview asset width must be positive.")
            }
            if let height = asset.height, height <= 0 {
                throw PreviewArtifactError.invalidArtifact("Preview asset height must be positive.")
            }
        }

        if let fallback {
            guard !fallback.assetID.trimmed.isEmpty,
                  !fallback.text.trimmed.isEmpty,
                  fallbackAsset != nil else {
                throw PreviewArtifactError.invalidArtifact("Preview fallback does not reference a fallback asset.")
            }
        }
    }

    private static func isRuntimeRelativeRoute(_ value: String) -> Bool {
        value.hasPrefix("/v1/conversations/")
            && !value.contains("://")
            && !value.hasPrefix("//")
            && !value.contains("\\")
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - Wire event

/// One complete self-contained preview snapshot plus its event correlation.
/// Invalid snapshots remain events so the preview block can fail closed without
/// dropping or failing the containing turn.
public struct PreviewArtifactEvent: Sendable, Equatable {
    public let eventID: String?
    public let sequence: Int?
    public let sessionID: String?
    public let turnID: String?
    public let callID: String?
    public let artifact: PreviewArtifact?
    public let error: PreviewArtifactError?

    public init(
        eventID: String? = nil,
        sequence: Int? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        callID: String? = nil,
        artifact: PreviewArtifact? = nil,
        error: PreviewArtifactError? = nil
    ) {
        self.eventID = eventID
        self.sequence = sequence
        self.sessionID = sessionID
        self.turnID = turnID
        self.callID = callID
        self.artifact = artifact
        self.error = error
    }

    public var isValid: Bool { artifact != nil && error == nil }

    static func from(wire: WireFrame) -> PreviewArtifactEvent {
        let envelope = PreviewArtifactEvent(
            eventID: wire.eventId,
            sequence: wire.seq,
            sessionID: wire.sessionId,
            turnID: wire.turnId,
            callID: wire.callId
        )

        guard let sequence = wire.seq else {
            return envelope.with(error: .invalidArtifact("Preview event requires seq."))
        }
        guard let sessionID = wire.sessionId, !sessionID.trimmed.isEmpty,
              let turnID = wire.turnId, !turnID.trimmed.isEmpty else {
            return envelope.with(error: .invalidArtifact("Preview event requires session_id and turn_id."))
        }
        guard let rawArtifact = wire.artifact else {
            return envelope.with(error: .invalidArtifact("Preview event is missing artifact."))
        }

        let artifact: PreviewArtifact
        do {
            artifact = try PreviewArtifact.decode(rawArtifact)
        } catch let error as PreviewArtifactError {
            return envelope.with(error: error)
        } catch {
            return envelope.with(error: .invalidArtifact("Preview artifact could not be decoded."))
        }

        guard artifact.sessionID == sessionID, artifact.turnID == turnID else {
            return envelope.with(error: .invalidArtifact("Preview envelope and artifact correlation IDs differ."))
        }
        if let envelopeCallID = wire.callId,
           let artifactCallID = artifact.callID,
           envelopeCallID != artifactCallID {
            return envelope.with(error: .invalidArtifact("Preview envelope and artifact call_id differ."))
        }

        return PreviewArtifactEvent(
            eventID: wire.eventId,
            sequence: sequence,
            sessionID: sessionID,
            turnID: turnID,
            callID: wire.callId,
            artifact: artifact,
            error: nil
        )
    }

    private func with(error: PreviewArtifactError) -> PreviewArtifactEvent {
        PreviewArtifactEvent(
            eventID: eventID,
            sequence: sequence,
            sessionID: sessionID,
            turnID: turnID,
            callID: callID,
            artifact: nil,
            error: error
        )
    }
}

// MARK: - Revision store

public struct PreviewArtifactIdentity: Sendable, Hashable, Equatable {
    public let sessionID: String
    public let artifactID: String

    public init(sessionID: String, artifactID: String) {
        self.sessionID = sessionID
        self.artifactID = artifactID
    }
}

public enum PreviewArtifactMergeResult: Sendable, Equatable {
    case inserted(PreviewArtifactIdentity, revision: Int)
    case replaced(PreviewArtifactIdentity, previousRevision: Int, revision: Int)
    case duplicate(PreviewArtifactIdentity, revision: Int)
    case stale(PreviewArtifactIdentity, currentRevision: Int, incomingRevision: Int)
    case conflict(PreviewArtifactIdentity, revision: Int, error: PreviewArtifactError)
    case rejected(PreviewArtifactError)

    public var errorCode: String? {
        switch self {
        case .conflict(_, _, let error), .rejected(let error): return error.code
        case .inserted, .replaced, .duplicate, .stale: return nil
        }
    }
}

/// Latest-valid-view store with immutable revision history. It never infers
/// previews from tool names or arbitrary tool output.
public struct PreviewArtifactStore: Sendable, Equatable {
    private var latest: [PreviewArtifactIdentity: PreviewArtifact] = [:]
    private var revisions: [PreviewArtifactIdentity: [Int: PreviewArtifact]] = [:]
    private var insertionOrder: [PreviewArtifactIdentity] = []

    public init() {}

    public mutating func merge(_ event: PreviewArtifactEvent) -> PreviewArtifactMergeResult {
        guard let artifact = event.artifact else {
            return .rejected(event.error ?? .invalidArtifact("Preview event is invalid."))
        }
        return merge(artifact)
    }

    public mutating func merge(_ artifact: PreviewArtifact) -> PreviewArtifactMergeResult {
        let identity = PreviewArtifactIdentity(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID
        )

        if let current = latest[identity] {
            if artifact.revision < current.revision {
                return .stale(
                    identity,
                    currentRevision: current.revision,
                    incomingRevision: artifact.revision
                )
            }
            if artifact.revision == current.revision {
                if artifact.revisionSHA256.lowercased() == current.revisionSHA256.lowercased() {
                    return .duplicate(identity, revision: artifact.revision)
                }
                return .conflict(
                    identity,
                    revision: artifact.revision,
                    error: PreviewArtifactError(
                        code: "preview_revision_conflict",
                        message: "Same preview revision has a different revision_sha256.",
                        retryable: false
                    )
                )
            }

            let previousRevision = current.revision
            latest[identity] = artifact
            revisions[identity, default: [:]][artifact.revision] = artifact
            return .replaced(
                identity,
                previousRevision: previousRevision,
                revision: artifact.revision
            )
        }

        latest[identity] = artifact
        revisions[identity, default: [:]][artifact.revision] = artifact
        insertionOrder.append(identity)
        return .inserted(identity, revision: artifact.revision)
    }

    public func artifact(sessionID: String, artifactID: String) -> PreviewArtifact? {
        latest[PreviewArtifactIdentity(sessionID: sessionID, artifactID: artifactID)]
    }

    public func revisionHistory(sessionID: String, artifactID: String) -> [PreviewArtifact] {
        let identity = PreviewArtifactIdentity(sessionID: sessionID, artifactID: artifactID)
        return (revisions[identity] ?? [:]).values.sorted { $0.revision < $1.revision }
    }

    public var artifacts: [PreviewArtifact] {
        insertionOrder.compactMap { latest[$0] }
    }

    public func artifacts(sessionID: String) -> [PreviewArtifact] {
        artifacts.filter { $0.sessionID == sessionID }
    }
}

// MARK: - Producer drafts

public struct PreviewAssetDraft: Codable, Sendable, Equatable {
    public let assetID: String
    public let role: PreviewArtifactAssetRole
    public let mimeType: String
    public let alt: String?
    public let width: Int?
    public let height: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case role, alt, width, height
        case assetID = "asset_id"
        case mimeType = "mime_type"
    }

    public init(
        assetID: String,
        role: PreviewArtifactAssetRole,
        mimeType: String,
        alt: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.assetID = assetID
        self.role = role
        self.mimeType = mimeType
        self.alt = alt
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownKeys(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        role = try container.decode(PreviewArtifactAssetRole.self, forKey: .role)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        alt = try container.decodeIfPresent(String.self, forKey: .alt)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
    }

    private static func rejectUnknownKeys(in decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DraftKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown preview asset fields: \(unknown.sorted().joined(separator: ","))"
            ))
        }
    }
}

public struct PreviewFallbackDraft: Codable, Sendable, Equatable {
    public let assetID: String
    public let text: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text
        case assetID = "asset_id"
    }

    public init(assetID: String, text: String) {
        self.assetID = assetID
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DraftKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        let unknown = Set(dynamic.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown preview fallback fields: \(unknown.sorted().joined(separator: ","))"
            ))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        text = try container.decode(String.self, forKey: .text)
    }
}

public struct PreviewArtifactDraft: Codable, Sendable, Equatable {
    public let artifactKey: String
    public let kind: PreviewArtifactKind
    public let title: String
    public let summary: String?
    public let viewerHTML: String?
    public let assets: [PreviewAssetDraft]
    public let fallback: PreviewFallbackDraft?
    public let presentation: PreviewArtifactPresentation?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, title, summary, assets, fallback, presentation
        case artifactKey = "artifact_key"
        case viewerHTML = "viewer_html"
    }

    public init(
        artifactKey: String,
        kind: PreviewArtifactKind,
        title: String,
        summary: String? = nil,
        viewerHTML: String? = nil,
        assets: [PreviewAssetDraft] = [],
        fallback: PreviewFallbackDraft? = nil,
        presentation: PreviewArtifactPresentation? = nil
    ) {
        self.artifactKey = artifactKey
        self.kind = kind
        self.title = title
        self.summary = summary
        self.viewerHTML = viewerHTML
        self.assets = assets
        self.fallback = fallback
        self.presentation = presentation
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DraftKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        let unknown = Set(dynamic.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown preview draft fields: \(unknown.sorted().joined(separator: ","))"
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifactKey = try container.decode(String.self, forKey: .artifactKey)
        kind = try container.decode(PreviewArtifactKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        viewerHTML = try container.decodeIfPresent(String.self, forKey: .viewerHTML)
        assets = try container.decodeIfPresent([PreviewAssetDraft].self, forKey: .assets) ?? []
        fallback = try container.decodeIfPresent(PreviewFallbackDraft.self, forKey: .fallback)
        presentation = try container.decodeIfPresent(PreviewArtifactPresentation.self, forKey: .presentation)
    }

    public static func decode(_ value: JSONValue) throws -> PreviewArtifactDraft {
        do {
            let data = try JSONEncoder().encode(value)
            let draft = try JSONDecoder().decode(PreviewArtifactDraft.self, from: data)
            try draft.validate()
            return draft
        } catch let error as PreviewArtifactError {
            throw error
        } catch {
            throw PreviewArtifactError.invalidArtifact("Preview draft is malformed.")
        }
    }

    public func validate() throws {
        guard !artifactKey.trimmed.isEmpty, !title.trimmed.isEmpty else {
            throw PreviewArtifactError.invalidArtifact("Preview draft identity is incomplete.")
        }
        var seen = Set<String>()
        for asset in assets {
            guard !asset.assetID.trimmed.isEmpty, seen.insert(asset.assetID).inserted else {
                throw PreviewArtifactError.invalidArtifact("Preview draft asset IDs must be unique.")
            }
            guard ["image/png", "image/jpeg", "image/webp"].contains(asset.mimeType.lowercased()) else {
                throw PreviewArtifactError.securityViolation("Preview draft asset MIME type is not allowlisted.")
            }
            guard asset.alt?.trimmed.isEmpty == false else {
                throw PreviewArtifactError.invalidArtifact("Preview draft image assets require alt text.")
            }
            if let width = asset.width, width <= 0 {
                throw PreviewArtifactError.invalidArtifact("Preview draft asset width must be positive.")
            }
            if let height = asset.height, height <= 0 {
                throw PreviewArtifactError.invalidArtifact("Preview draft asset height must be positive.")
            }
        }

        switch kind {
        case .interactiveHTML:
            guard viewerHTML?.trimmed.isEmpty == false else {
                throw PreviewArtifactError.invalidArtifact("Interactive preview draft requires viewer_html.")
            }
            guard let fallback,
                  !fallback.text.trimmed.isEmpty,
                  assets.contains(where: { $0.assetID == fallback.assetID && $0.role == .fallback }) else {
                throw PreviewArtifactError.invalidArtifact("Interactive preview draft requires a fallback asset.")
            }
        case .staticImage:
            guard assets.contains(where: { $0.role == .primary }) else {
                throw PreviewArtifactError.invalidArtifact("Static preview draft requires a primary image.")
            }
        }
    }
}

// MARK: - Transport-neutral resolvers

public struct PreviewViewerRequest: Sendable, Equatable {
    public let sessionID: String
    public let artifactID: String
    public let revision: Int

    public init(sessionID: String, artifactID: String, revision: Int) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.revision = revision
    }
}

public struct PreviewAssetRequest: Sendable, Equatable {
    public let sessionID: String
    public let artifactID: String
    public let revision: Int
    public let assetID: String

    public init(sessionID: String, artifactID: String, revision: Int, assetID: String) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.revision = revision
        self.assetID = assetID
    }
}

public struct PreviewViewerResource: Sendable, Equatable {
    public let sessionID: String
    public let artifactID: String
    public let revision: Int
    public let data: Data
    public let statusCode: Int
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String
    public let expiresAt: Date?

    public init(
        sessionID: String,
        artifactID: String,
        revision: Int,
        data: Data,
        statusCode: Int,
        mimeType: String,
        sizeBytes: Int,
        sha256: String,
        expiresAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.revision = revision
        self.data = data
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.expiresAt = expiresAt
    }

    public func validate(against artifact: PreviewArtifact) throws {
        guard artifact.kind == .interactiveHTML,
              let viewer = artifact.viewer,
              sessionID == artifact.sessionID,
              artifactID == artifact.artifactID,
              revision == artifact.revision else {
            throw PreviewResourceError(
                code: "preview_invalid_artifact",
                message: "Viewer resource binding does not match the artifact."
            )
        }
        guard mimeType.lowercased() == viewer.mimeType.lowercased() else {
            throw PreviewResourceError(
                code: "preview_viewer_mime_mismatch",
                message: "Viewer MIME type did not match the artifact."
            )
        }
        guard sizeBytes == data.count,
              sizeBytes == viewer.sizeBytes,
              sizeBytes <= PreviewArtifact.maximumViewerBytes else {
            throw PreviewResourceError(
                code: "preview_invalid_artifact",
                message: "Viewer size did not match the artifact."
            )
        }
        let actualDigest = PreviewRFC8785.sha256(data: data)
        guard sha256.lowercased() == actualDigest.lowercased(),
              actualDigest.lowercased() == viewer.sha256.lowercased() else {
            throw PreviewResourceError(
                code: "preview_digest_mismatch",
                message: "Viewer digest did not match the artifact."
            )
        }
    }
}

public struct PreviewAssetResource: Sendable, Equatable {
    public let sessionID: String
    public let artifactID: String
    public let revision: Int
    public let assetID: String
    public let data: Data
    public let statusCode: Int
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String
    public let expiresAt: Date?

    public init(
        sessionID: String,
        artifactID: String,
        revision: Int,
        assetID: String,
        data: Data,
        statusCode: Int,
        mimeType: String,
        sizeBytes: Int,
        sha256: String,
        expiresAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.revision = revision
        self.assetID = assetID
        self.data = data
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.expiresAt = expiresAt
    }

    public func validate(against artifact: PreviewArtifact) throws {
        guard let expected = artifact.assets.first(where: { $0.assetID == assetID }),
              sessionID == artifact.sessionID,
              artifactID == artifact.artifactID,
              revision == artifact.revision else {
            throw PreviewResourceError(
                code: "preview_asset_unavailable",
                message: "Asset resource binding does not match the artifact."
            )
        }
        guard mimeType.lowercased() == expected.mimeType.lowercased() else {
            throw PreviewResourceError(
                code: "preview_security_violation",
                message: "Asset MIME type did not match the artifact."
            )
        }
        guard sizeBytes == data.count, sizeBytes == expected.sizeBytes else {
            throw PreviewResourceError(
                code: "preview_asset_unavailable",
                message: "Asset size did not match the artifact."
            )
        }
        let actualDigest = PreviewRFC8785.sha256(data: data)
        guard sha256.lowercased() == actualDigest.lowercased(),
              actualDigest.lowercased() == expected.sha256.lowercased() else {
            throw PreviewResourceError(
                code: "preview_asset_unavailable",
                message: "Asset digest did not match the artifact."
            )
        }
    }
}

public struct PreviewResourceError: Error, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public protocol PreviewViewerResolver: Sendable {
    func resolve(_ request: PreviewViewerRequest) async throws -> PreviewViewerResource
}

public protocol PreviewAssetResolver: Sendable {
    func resolveContent(_ request: PreviewAssetRequest) async throws -> PreviewAssetResource
}

// MARK: - HTTP error envelope

/// Parsed preview failure from the existing `{trace_id, code, msg, data}` HTTP
/// envelope. The HTTP status remains the primary transport outcome; the string
/// preview code lives in `error.code` and is repeated in top-level `msg`.
public struct PreviewHTTPError: Error, Sendable, Equatable, LocalizedError {
    public let traceID: String?
    public let httpStatus: Int
    public let code: Int
    public let error: PreviewArtifactError

    public init(traceID: String?, httpStatus: Int, code: Int, error: PreviewArtifactError) {
        self.traceID = traceID
        self.httpStatus = httpStatus
        self.code = code
        self.error = error
    }

    public var errorDescription: String? { error.message }

    public static func decode(data: Data, httpStatus: Int) -> PreviewHTTPError? {
        guard let envelope = try? JSONDecoder().decode(PreviewHTTPEnvelope.self, from: data) else {
            return nil
        }
        let payload = envelope.data?.error
        let fallbackCode = payload?.code ?? envelope.msg
        guard envelope.code != 0, let fallbackCode, !fallbackCode.isEmpty else { return nil }
        let message = payload?.message ?? envelope.msg ?? fallbackCode
        return PreviewHTTPError(
            traceID: envelope.traceID,
            httpStatus: httpStatus,
            code: envelope.code,
            error: PreviewArtifactError(
                code: fallbackCode,
                message: message,
                retryable: payload?.retryable ?? false
            )
        )
    }
}

private struct PreviewHTTPEnvelope: Decodable {
    let traceID: String?
    let code: Int
    let msg: String?
    let data: PreviewHTTPErrorData?

    enum CodingKeys: String, CodingKey {
        case code, msg, data
        case traceID = "trace_id"
    }
}

private struct PreviewHTTPErrorData: Decodable {
    let httpStatus: Int?
    let error: PreviewArtifactError?

    enum CodingKeys: String, CodingKey {
        case error
        case httpStatus = "http_status"
    }
}

// MARK: - Helpers

private struct DraftKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func previewPathComponentIsSafe(_ value: String) -> Bool {
    !value.isEmpty
        && value != "."
        && value != ".."
        && !value.contains("/")
        && !value.contains("\\")
        && !value.contains("?")
        && !value.contains("#")
        && !value.contains("%")
}

private func isSHA256Token(_ value: String) -> Bool {
    guard value.hasPrefix("sha256:"), value.count == 71 else { return false }
    let hex = value.dropFirst("sha256:".count)
    return hex.unicodeScalars.allSatisfy {
        (0x30...0x39).contains($0.value)
            || (0x61...0x66).contains($0.value)
            || (0x41...0x46).contains($0.value)
    }
}

private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
        difference |= left[index] ^ right[index]
    }
    return difference == 0
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
