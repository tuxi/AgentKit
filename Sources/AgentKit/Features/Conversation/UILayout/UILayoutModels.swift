//
//  UILayoutModels.swift
//  AgentKit
//
//  Strict, presentation-facing projection of `ui_layout_result.v1`.
//  The document binds a persisted layout revision to its source image,
//  evidence digest, and the two canonical assets. It is data, not UI.
//

import ClientToolProtocol
import Foundation

struct UILayoutResultDocument: Equatable, Sendable {
    let raw: JSONValue
    let artifactID: String
    let revision: Int
    let revisionSHA256: String
    let sourceAssetID: String
    let sourceAssetSHA256: String
    let evidenceSHA256: String?
    let canvas: UILayoutCanvas
    let nodeCount: Int
    let assumptionCount: Int
    let targets: [String]
    let created: Bool
    let overlayAsset: UILayoutAssetDescriptor
    let layoutJSONAsset: UILayoutAssetDescriptor

    static func parse(_ raw: JSONValue) -> UILayoutResultDocument? {
        guard let root = exactObject(
            raw,
            required: [
                "schema", "layout_artifact_id", "layout_revision",
                "layout_revision_sha256", "source_asset_id", "source_asset_sha256",
                "evidence_sha256", "canvas", "node_count", "assumption_count",
                "targets", "created", "overlay_asset", "layout_json_asset",
            ],
            optional: []
        ),
        root["schema"]?.string == "ui_layout_result.v1",
        let artifactID = validArtifactID(root["layout_artifact_id"]?.string),
        let revision = positiveInteger(root["layout_revision"]),
        let revisionSHA256 = validRevisionSHA256(root["layout_revision_sha256"]?.string),
        let sourceAssetID = validAssetID(root["source_asset_id"]?.string),
        let sourceSHA256 = validSHA256(root["source_asset_sha256"]?.string),
        let evidenceSHA256 = optionalSHA256(root["evidence_sha256"] ?? .null),
        let canvas = parseCanvas(root["canvas"] ?? .null),
        let nodeCount = positiveInteger(root["node_count"]),
        let assumptionCount = boundedInteger(root["assumption_count"], range: 0...Int.max),
        let rawTargets = root["targets"]?.array,
        (1...16).contains(rawTargets.count),
        let targets = validTargets(rawTargets),
        let created = root["created"]?.bool,
        let overlay = parseOverlayAsset(root["overlay_asset"] ?? .null),
        let layoutJSON = parseLayoutJSONAsset(root["layout_json_asset"] ?? .null) else {
            return nil
        }
        guard overlay.assetID != layoutJSON.assetID,
              overlay.relativePath != layoutJSON.relativePath else {
            return nil
        }

        return UILayoutResultDocument(
            raw: raw,
            artifactID: artifactID,
            revision: revision,
            revisionSHA256: revisionSHA256,
            sourceAssetID: sourceAssetID,
            sourceAssetSHA256: sourceSHA256,
            evidenceSHA256: evidenceSHA256,
            canvas: canvas,
            nodeCount: nodeCount,
            assumptionCount: assumptionCount,
            targets: targets,
            created: created,
            overlayAsset: overlay,
            layoutJSONAsset: layoutJSON
        )
    }

    private static func parseCanvas(_ value: JSONValue) -> UILayoutCanvas? {
        guard let object = exactObject(
            value,
            required: ["width", "height"],
            optional: []
        ),
        let width = positiveInteger(object["width"]),
        let height = positiveInteger(object["height"]) else {
            return nil
        }
        return UILayoutCanvas(width: width, height: height)
    }

    private static func parseOverlayAsset(_ value: JSONValue) -> UILayoutAssetDescriptor? {
        guard let object = exactObject(
            value,
            required: [
                "asset_id", "asset_role", "kind", "relative_path", "filename",
                "mime_type", "width", "height", "sha256",
            ],
            optional: []
        ),
        let assetID = validAssetID(object["asset_id"]?.string),
        object["asset_role"]?.string == "layout_overlay",
        object["kind"]?.string == "image",
        let relativePath = validRelativePath(object["relative_path"]?.string),
        let filename = validFilename(object["filename"]?.string),
        object["mime_type"]?.string == "image/png",
        let width = positiveInteger(object["width"]),
        let height = positiveInteger(object["height"]),
        let sha256 = validSHA256(object["sha256"]?.string) else {
            return nil
        }
        return UILayoutAssetDescriptor(
            assetID: assetID,
            role: "layout_overlay",
            kind: "image",
            relativePath: relativePath,
            filename: filename,
            mimeType: "image/png",
            width: width,
            height: height,
            sha256: sha256
        )
    }

    private static func parseLayoutJSONAsset(_ value: JSONValue) -> UILayoutAssetDescriptor? {
        guard let object = exactObject(
            value,
            required: [
                "asset_id", "asset_role", "kind", "relative_path", "filename",
                "mime_type", "sha256",
            ],
            optional: []
        ),
        let assetID = validAssetID(object["asset_id"]?.string),
        object["asset_role"]?.string == "layout_json",
        object["kind"]?.string == "file",
        let relativePath = validRelativePath(object["relative_path"]?.string),
        let filename = validFilename(object["filename"]?.string),
        object["mime_type"]?.string == "application/json",
        let sha256 = validSHA256(object["sha256"]?.string) else {
            return nil
        }
        return UILayoutAssetDescriptor(
            assetID: assetID,
            role: "layout_json",
            kind: "file",
            relativePath: relativePath,
            filename: filename,
            mimeType: "application/json",
            width: nil,
            height: nil,
            sha256: sha256
        )
    }

    private static func validTargets(_ values: [JSONValue]) -> [String]? {
        let targets = values.compactMap { value -> String? in
            guard let target = value.string,
                  target.range(
                      of: "^[a-z][a-z0-9_]{0,63}$",
                      options: .regularExpression
                  ) != nil else {
                return nil
            }
            return target
        }
        guard targets.count == values.count,
              Set(targets).count == targets.count else {
            return nil
        }
        return targets
    }

    private static func exactObject(
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

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        boundedInteger(value, range: 1...Int.max)
    }

    private static func boundedInteger(
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

    private static func validArtifactID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^layout_[A-Za-z0-9._-]{1,180}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func validAssetID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^asset_[A-Za-z0-9._:-]{1,180}$",
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

    private static func validSHA256(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return value
    }

    private static func optionalSHA256(_ value: JSONValue) -> String?? {
        if value == .null { return .some(nil) }
        guard let string = value.string, validSHA256(string) != nil else {
            return nil
        }
        return .some(string)
    }

    private static func validRelativePath(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 4_096,
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

    private static func validFilename(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 512,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }
}

struct UILayoutCanvas: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct UILayoutAssetDescriptor: Equatable, Sendable {
    let assetID: String
    let role: String
    let kind: String
    let relativePath: String
    let filename: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let sha256: String
}
