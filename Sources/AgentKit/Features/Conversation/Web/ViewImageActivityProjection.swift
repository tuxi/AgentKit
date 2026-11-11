//
//  ViewImageActivityProjection.swift
//  AgentKit
//
//  Projects the generic `view_image_result.v1` output kind into presentation
//  data. Relationships come only from structured asset IDs and source links;
//  tool names, file paths, and prose are deliberately not inspected.
//

import Foundation
import ClientToolProtocol

enum ViewImageActivityProjection {
    private struct ParsedAsset {
        let assetID: String
        let role: String
        let filename: String
        let mimeType: String
        let width: Int
        let height: Int
        let sourceAssetID: String?
        let sourceRegion: ConversationWebDocument.ImageRegion?
    }

    private struct ParsedResult {
        let sourceAssetID: String
        let cropAssetID: String?
        let assets: [ParsedAsset]
        let detailRequested: String
        let detailEffective: String
        let sourceRegion: ConversationWebDocument.ImageRegion?
    }

    /// Returns the validated asset IDs in result order. The bridge uses this
    /// same validation path before exposing any local file bytes to WebKit.
    static func validatedAssetIDs(in tool: ToolNodePayload) -> [String]? {
        guard let result = parse(tool: tool) else { return nil }
        return result.assets.map(\.assetID)
    }

    static func make(
        tool: ToolNodePayload,
        turnID: String,
        assetIndex: AssetIndex,
        registerAction: ((ConversationWebAction) -> String)?
    ) -> ConversationWebDocument.ImageView? {
        guard let parsed = parse(tool: tool) else { return nil }
        let assetsByID = Dictionary(
            tool.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard parsed.assets.allSatisfy({ assetsByID[$0.assetID] != nil }),
              let sourceAsset = assetsByID[parsed.sourceAssetID] else {
            return nil
        }

        let projectedAssets = parsed.assets.map { asset -> ConversationWebDocument.ImageViewAsset in
            let structuredAsset = assetsByID[asset.assetID]!
            let reference = assetIndex.reference(forStructuredAsset: structuredAsset)
            let actionID = registerAction.map {
                $0(.transcript(
                    turnID: turnID,
                    action: .openAsset(reference)
                ))
            }
            return ConversationWebDocument.ImageViewAsset(
                assetID: asset.assetID,
                role: asset.role,
                displayName: asset.filename,
                width: asset.width,
                height: asset.height,
                sourceAssetID: asset.sourceAssetID,
                sourceRegion: asset.sourceRegion,
                viewActionID: actionID
            )
        }

        let sourceFilename = projectedAssets.first(where: {
            $0.assetID == parsed.sourceAssetID
        })?.displayName ?? sourceAsset.displayName ?? parsed.sourceAssetID
        return ConversationWebDocument.ImageView(
            title: "Viewed image \(sourceFilename)",
            displayName: sourceFilename,
            sourceAssetID: parsed.sourceAssetID,
            cropAssetID: parsed.cropAssetID,
            detailRequested: parsed.detailRequested,
            detailEffective: parsed.detailEffective,
            sourceRegion: parsed.sourceRegion,
            assets: projectedAssets
        )
    }

    private static func parse(tool: ToolNodePayload) -> ParsedResult? {
        guard let output = tool.structuredOutput?.object,
              output["kind"]?.string == "image_view",
              output["schema"]?.string == "view_image_result.v1",
              let sourceAssetID = validAssetID(output["source_asset_id"]?.string),
              let rawAssets = output["assets"]?.array,
              (1...2).contains(rawAssets.count),
              let detailRequested = detailValue(output["detail_requested"] ?? .null),
              let detailEffective = detailValue(output["detail_effective"] ?? .null) else {
            return nil
        }

        let assets = rawAssets.compactMap(parseAsset)
        guard assets.count == rawAssets.count,
              assets[0].role == "source",
              assets[0].assetID == sourceAssetID,
              Set(assets.map(\.assetID)).count == assets.count else {
            return nil
        }

        let cropAssetID: String?
        if assets.count == 2 {
            guard assets[1].role == "crop" else { return nil }
            cropAssetID = assets[1].assetID
            guard output["crop_asset_id"]?.string == cropAssetID,
                  assets[1].sourceAssetID == sourceAssetID,
                  let cropRegion = assets[1].sourceRegion,
                  let sourceRegion = parseRegion(output["source_region"] ?? .null),
                  sourceRegion == cropRegion else {
                return nil
            }
        } else {
            cropAssetID = nil
            guard output["crop_asset_id"] == .null,
                  output["source_region"] == .null else {
                return nil
            }
        }

        let structuredAssetsByID = Dictionary(
            tool.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard assets.allSatisfy({ asset in
            guard let structured = structuredAssetsByID[asset.assetID] else { return false }
            if let mimeType = structured.mimeType,
               mimeType.lowercased() != asset.mimeType {
                return false
            }
            return structured.kind == "image"
                || structured.mimeType?.lowercased() == asset.mimeType
        }) else {
            return nil
        }

        return ParsedResult(
            sourceAssetID: sourceAssetID,
            cropAssetID: cropAssetID,
            assets: assets,
            detailRequested: detailRequested,
            detailEffective: detailEffective,
            sourceRegion: assets.count == 2 ? assets[1].sourceRegion : nil
        )
    }

    private static func parseAsset(_ value: JSONValue) -> ParsedAsset? {
        guard let object = value.object,
              let assetID = validAssetID(object["asset_id"]?.string),
              let role = object["role"]?.string,
              object["asset_role"]?.string == role,
              let filename = object["filename"]?.string,
              !filename.isEmpty,
              filename.utf8.count <= 512,
              let mimeType = object["mime_type"]?.string,
              ["image/png", "image/jpeg", "image/webp"].contains(mimeType),
              let width = positiveInteger(object["width"] ?? .null),
              let height = positiveInteger(object["height"] ?? .null),
              object["relative_path"]?.string?.isEmpty == false,
              let sha256 = object["sha256"]?.string,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            return nil
        }

        switch role {
        case "source":
            guard object["source_asset_id"] == nil,
                  object["source_bbox"] == nil else { return nil }
            return ParsedAsset(
                assetID: assetID,
                role: role,
                filename: filename,
                mimeType: mimeType,
                width: width,
                height: height,
                sourceAssetID: nil,
                sourceRegion: nil
            )
        case "crop":
            guard let parentAssetID = validAssetID(object["source_asset_id"]?.string),
                  let region = parseRegion(object["source_bbox"] ?? .null),
                  let purpose = object["purpose"]?.string,
                  ["navigation", "content", "controls", "repeated_group", "detail", "unknown"]
                    .contains(purpose) else {
                return nil
            }
            return ParsedAsset(
                assetID: assetID,
                role: role,
                filename: filename,
                mimeType: mimeType,
                width: width,
                height: height,
                sourceAssetID: parentAssetID,
                sourceRegion: region
            )
        default:
            return nil
        }
    }

    private static func parseRegion(_ value: JSONValue) -> ConversationWebDocument.ImageRegion? {
        guard let object = value.object,
              let x = finiteNumber(object["x"] ?? .null),
              let y = finiteNumber(object["y"] ?? .null),
              let width = finiteNumber(object["width"] ?? .null),
              let height = finiteNumber(object["height"] ?? .null),
              (0...1).contains(x),
              (0...1).contains(y),
              (0...1).contains(width),
              (0...1).contains(height) else {
            return nil
        }
        return ConversationWebDocument.ImageRegion(x: x, y: y, width: width, height: height)
    }

    private static func validAssetID(_ value: String?) -> String? {
        guard let value,
              value.hasPrefix("asset_"),
              value.utf8.count <= 187,
              value.dropFirst("asset_".count).allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0))
              }) else {
            return nil
        }
        return value
    }

    private static func positiveInteger(_ value: JSONValue) -> Int? {
        let result: Int?
        switch value {
        case .integer(let integer): result = integer
        case .number(let number) where number.rounded() == number: result = Int(number)
        case .string(let string): result = Int(string)
        default: result = nil
        }
        guard let result, result > 0 else { return nil }
        return result
    }

    private static func finiteNumber(_ value: JSONValue) -> Double? {
        let result: Double?
        switch value {
        case .integer(let integer): result = Double(integer)
        case .number(let number): result = number
        case .string(let string): result = Double(string)
        default: result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private static func detailValue(_ value: JSONValue) -> String? {
        guard let detail = value.string,
              ["high", "original"].contains(detail) else { return nil }
        return detail
    }
}
