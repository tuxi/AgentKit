//
//  UIPreviewModels.swift
//  AgentKit
//
//  Strict, presentation-facing projection of `ui_preview_result.v1` and its
//  `ui_preview_lineage.v2` record. The document binds one preview card to the
//  reviewed layout revision, source image, evidence digest, target, and state.
//  It is data, not UI.
//

import ClientToolProtocol
import Foundation

struct UIPreviewResultDocument: Equatable, Sendable {
    static let adaptationMode = "adaptation"
    static let exploreMode = "explore"

    let raw: JSONValue
    let artifactKey: String
    let kind: String
    let title: String
    let mode: String
    let lineage: UIPreviewLineage?
    let fallbackAsset: UIPreviewFallbackAsset

    var isAdaptation: Bool { mode == Self.adaptationMode }

    var modeLabel: String {
        isAdaptation ? "Adaptation Preview" : "Explore Preview"
    }

    static func parse(_ raw: JSONValue) -> UIPreviewResultDocument? {
        guard let root = exactObject(
            raw,
            required: [
                "schema", "artifact_key", "kind", "title", "mode", "lineage",
                "fallback_asset",
            ],
            optional: []
        ),
        root["schema"]?.string == "ui_preview_result.v1",
        let artifactKey = validArtifactKey(root["artifact_key"]?.string),
        let kind = root["kind"]?.string,
        ["interactive_html", "static_image"].contains(kind),
        let title = validTitle(root["title"]?.string),
        let mode = root["mode"]?.string,
        [adaptationMode, exploreMode].contains(mode),
        let lineage = parseLineageField(root["lineage"] ?? .null, mode: mode),
        let fallback = parseFallbackAsset(root["fallback_asset"] ?? .null) else {
            return nil
        }

        return UIPreviewResultDocument(
            raw: raw,
            artifactKey: artifactKey,
            kind: kind,
            title: title,
            mode: mode,
            lineage: lineage,
            fallbackAsset: fallback
        )
    }

    /// Adaptation previews require a v2 lineage; explore previews must not
    /// carry one. A missing or invalid lineage therefore fails the whole
    /// document instead of degrading into a formal adaptation preview.
    private static func parseLineageField(
        _ value: JSONValue,
        mode: String
    ) -> UIPreviewLineage?? {
        switch mode {
        case adaptationMode:
            guard let lineage = UIPreviewLineage.parse(value) else { return nil }
            return .some(lineage)
        case exploreMode:
            guard value == .null else { return nil }
            return .some(nil)
        default:
            return nil
        }
    }

    private static func parseFallbackAsset(_ value: JSONValue) -> UIPreviewFallbackAsset? {
        guard let object = exactObject(
            value,
            required: [
                "asset_id", "relative_path", "mime_type", "width", "height", "sha256",
            ],
            optional: []
        ),
        let assetID = validAssetID(object["asset_id"]?.string),
        let relativePath = validRelativePath(object["relative_path"]?.string),
        let mimeType = object["mime_type"]?.string,
        ["image/png", "image/jpeg", "image/webp"].contains(mimeType),
        let width = boundedInteger(object["width"], range: 0...Int.max),
        let height = boundedInteger(object["height"], range: 0...Int.max),
        let sha256 = validSHA256(object["sha256"]?.string) else {
            return nil
        }
        return UIPreviewFallbackAsset(
            assetID: assetID,
            relativePath: relativePath,
            mimeType: mimeType,
            width: width,
            height: height,
            sha256: sha256
        )
    }

    static func exactObject(
        _ value: JSONValue,
        required: Set<String>,
        optional: Set<String>
    ) -> [String: JSONValue]? {
        guard case .object(let object) = value,
              Set(object.keys).isSuperset(of: required),
              Set(object.keys).isSubset(of: required.union(optional)) else {
            return nil
        }
        return object
    }

    static func boundedInteger(
        _ value: JSONValue?,
        range: ClosedRange<Int>
    ) -> Int? {
        let integer: Int?
        switch value {
        case .integer(let value): integer = value
        case .number(let value) where value.rounded() == value: integer = Int(value)
        default: integer = nil
        }
        guard let integer, range.contains(integer) else { return nil }
        return integer
    }

    static func validSHA256(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    static func validAssetID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^asset_[A-Za-z0-9._:-]{1,180}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    static func validArtifactKey(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    static func validRelativePath(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != ".." && $0 != "."
              }) else {
            return nil
        }
        return value
    }

    private static func validTitle(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 256 else {
            return nil
        }
        return value
    }
}

struct UIPreviewFallbackAsset: Equatable, Sendable {
    let assetID: String
    let relativePath: String
    let mimeType: String
    let width: Int
    let height: Int
    let sha256: String
}

struct UIPreviewLineage: Equatable, Sendable {
    static let schema = "ui_preview_lineage.v2"
    static let targets: Set<String> = [
        "duo_folded", "duo_unfolded", "iphone_portrait", "iphone_landscape",
        "ipad_portrait", "ipad_landscape",
    ]

    let layoutArtifactID: String
    let layoutRevision: Int
    let layoutRevisionSHA256: String
    let sourceAssetID: String
    let sourceAssetSHA256: String
    let evidenceSHA256: String?
    let approval: UIPreviewApproval
    let target: String
    let state: String
    let targetMatrix: UIPreviewTargetMatrix

    static func parse(_ value: JSONValue) -> UIPreviewLineage? {
        guard let root = UIPreviewResultDocument.exactObject(
            value,
            required: [
                "schema", "layout_artifact_id", "layout_revision",
                "layout_revision_sha256", "source_asset_id", "source_asset_sha256",
                "evidence_sha256", "approval", "target", "state", "target_matrix",
            ],
            optional: []
        ),
        root["schema"]?.string == schema,
        let layoutArtifactID = validLayoutArtifactID(root["layout_artifact_id"]?.string),
        let layoutRevision = UIPreviewResultDocument.boundedInteger(
            root["layout_revision"], range: 1...Int.max
        ),
        let layoutRevisionSHA256 = validRevisionSHA256(root["layout_revision_sha256"]?.string),
        let sourceAssetID = UIPreviewResultDocument.validAssetID(root["source_asset_id"]?.string),
        let sourceAssetSHA256 = UIPreviewResultDocument.validSHA256(
            root["source_asset_sha256"]?.string
        ),
        let evidenceSHA256 = optionalSHA256(root["evidence_sha256"] ?? .null),
        let approval = UIPreviewApproval.parse(root["approval"] ?? .null),
        let target = root["target"]?.string,
        targets.contains(target),
        let state = validState(root["state"]?.string),
        let targetMatrix = UIPreviewTargetMatrix.parse(
            root["target_matrix"] ?? .null
        ),
        targetMatrix.targets.contains(target) else {
            return nil
        }

        return UIPreviewLineage(
            layoutArtifactID: layoutArtifactID,
            layoutRevision: layoutRevision,
            layoutRevisionSHA256: layoutRevisionSHA256,
            sourceAssetID: sourceAssetID,
            sourceAssetSHA256: sourceAssetSHA256,
            evidenceSHA256: evidenceSHA256,
            approval: approval,
            target: target,
            state: state,
            targetMatrix: targetMatrix
        )
    }

    private static func optionalSHA256(_ value: JSONValue) -> String?? {
        if value == .null { return .some(nil) }
        guard let string = value.string,
              UIPreviewResultDocument.validSHA256(string) != nil else {
            return nil
        }
        return .some(string)
    }

    private static func validLayoutArtifactID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^layout_[A-Za-z0-9._:-]{1,180}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func validRevisionSHA256(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^sha256:[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func validState(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 64 else {
            return nil
        }
        return value
    }
}

struct UIPreviewApproval: Equatable, Sendable {
    enum State: String, Sendable {
        case userConfirmed = "user_confirmed"
        case notRequired = "not_required"
        case unconfirmed = "unconfirmed"
    }

    let state: State
    let evidenceRef: String?

    static func parse(_ value: JSONValue) -> UIPreviewApproval? {
        guard let object = UIPreviewResultDocument.exactObject(
            value,
            required: ["state"],
            optional: ["evidence_ref"]
        ),
        let rawState = object["state"]?.string,
        let state = State(rawValue: rawState),
        let evidenceRef = optionalEvidenceRef(object["evidence_ref"]),
        state != .userConfirmed || evidenceRef != nil else {
            return nil
        }
        return UIPreviewApproval(state: state, evidenceRef: evidenceRef)
    }

    private static func optionalEvidenceRef(_ value: JSONValue?) -> String?? {
        guard let value else { return .some(nil) }
        guard let string = value.string,
              !string.isEmpty,
              string.count <= 256 else {
            return nil
        }
        return .some(string)
    }
}

struct UIPreviewTargetMatrix: Equatable, Sendable {
    let id: String
    let targets: [String]

    static func parse(_ value: JSONValue) -> UIPreviewTargetMatrix? {
        guard let object = UIPreviewResultDocument.exactObject(
            value,
            required: ["id", "targets"],
            optional: []
        ),
        let id = validMatrixID(object["id"]?.string),
        let rawTargets = object["targets"]?.array,
        (1...16).contains(rawTargets.count),
        let targets = validTargets(rawTargets),
        Set(targets).count == targets.count else {
            return nil
        }
        return UIPreviewTargetMatrix(id: id, targets: targets)
    }

    private static func validMatrixID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^matrix_[A-Za-z0-9._:-]{1,180}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func validTargets(_ values: [JSONValue]) -> [String]? {
        let targets = values.compactMap { value -> String? in
            guard let target = value.string,
                  UIPreviewLineage.targets.contains(target) else {
                return nil
            }
            return target
        }
        guard targets.count == values.count else { return nil }
        return targets
    }
}
