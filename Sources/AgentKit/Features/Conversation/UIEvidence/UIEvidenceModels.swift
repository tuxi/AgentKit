//
//  UIEvidenceModels.swift
//  AgentKit
//
//  Strict, presentation-facing projection of `ui_evidence.v1`.
//  The document is evidence data, not UI instructions.
//

import ClientToolProtocol
import Foundation

struct UIEvidenceDocument: Equatable, Sendable {
    let raw: JSONValue
    let source: UIEvidenceSource
    let coordinateSpace: String
    let producer: UIEvidenceProducer
    let elements: [UIEvidenceElement]
    let repeatedGroups: [UIEvidenceRepeatedGroup]
    let sourceTree: UIEvidenceSourceTree
    let crops: [UIEvidenceCrop]
    let uncertainties: [UIEvidenceUncertainty]
    let limits: UIEvidenceLimits

    var textElementCount: Int {
        elements.count { $0.kind == .text }
    }

    var containerCount: Int {
        elements.count { $0.kind == .container }
    }

    var observedCount: Int {
        elements.count { $0.evidence == .observed }
    }

    var inferredCount: Int {
        elements.count { $0.evidence == .inferred }
    }

    var uncertainElementCount: Int {
        elements.count { $0.evidence == .uncertain }
    }

    var warningNotes: [String] {
        var notes: [String] = []
        if limits.elementsTruncated {
            notes.append("Element list was truncated.")
        }
        if limits.treeNodesTruncated || sourceTree.truncated {
            notes.append("Source-tree nodes were truncated.")
        }
        return notes
    }

    var sourceTreeNote: String? {
        guard sourceTree.kind == .none else { return nil }
        return "No AX/DOM tree was supplied. This evidence contains pixels, OCR, and geometry only."
    }

    static func parse(_ raw: JSONValue) -> UIEvidenceDocument? {
        guard let root = exactObject(
            raw,
            required: [
                "schema", "source", "coordinate_space", "producer", "elements",
                "repeated_groups", "source_tree", "crops", "uncertainties", "limits",
            ],
            optional: []
        ),
        root["schema"]?.string == "ui_evidence.v1",
        root["coordinate_space"]?.string == "normalized_top_left",
        let source = parseSource(root["source"] ?? .null),
        let producer = parseProducer(root["producer"] ?? .null),
        let rawElements = root["elements"]?.array,
        rawElements.count <= 500,
        let elements = parseArray(rawElements, transform: parseElement),
        let rawGroups = root["repeated_groups"]?.array,
        rawGroups.count <= 100,
        let repeatedGroups = parseArray(rawGroups, transform: parseRepeatedGroup),
        let sourceTree = parseSourceTree(root["source_tree"] ?? .null),
        let rawCrops = root["crops"]?.array,
        rawCrops.count <= 16,
        let crops = parseArray(rawCrops, transform: parseCrop),
        let rawUncertainties = root["uncertainties"]?.array,
        rawUncertainties.count <= 32,
        let uncertainties = parseArray(rawUncertainties, transform: parseUncertainty),
        let limits = parseLimits(root["limits"] ?? .null),
        limits.elementCount == elements.count,
        validateCrossReferences(
            elements: elements,
            repeatedGroups: repeatedGroups,
            sourceTree: sourceTree,
            crops: crops,
            uncertainties: uncertainties,
            source: source
        ) else {
            return nil
        }

        return UIEvidenceDocument(
            raw: raw,
            source: source,
            coordinateSpace: "normalized_top_left",
            producer: producer,
            elements: elements,
            repeatedGroups: repeatedGroups,
            sourceTree: sourceTree,
            crops: crops,
            uncertainties: uncertainties,
            limits: limits
        )
    }

    private static func parseSource(_ value: JSONValue) -> UIEvidenceSource? {
        guard let object = exactObject(
            value,
            required: ["asset_id", "source_kind", "sha256", "mime_type", "width", "height"],
            optional: []
        ),
        let assetID = validAssetID(object["asset_id"]?.string),
        let sourceKind = UIEvidenceSourceKind(rawValue: object["source_kind"]?.string ?? ""),
        let sha256 = object["sha256"]?.string,
        validSHA256(sha256),
        let mimeType = object["mime_type"]?.string,
        ["image/png", "image/jpeg", "image/webp"].contains(mimeType),
        let width = positiveInteger(object["width"]),
        let height = positiveInteger(object["height"]) else {
            return nil
        }
        return UIEvidenceSource(
            assetID: assetID,
            sourceKind: sourceKind,
            sha256: sha256,
            mimeType: mimeType,
            width: width,
            height: height
        )
    }

    private static func parseProducer(_ value: JSONValue) -> UIEvidenceProducer? {
        guard let object = exactObject(value, required: ["name", "version"], optional: []),
              let name = object["name"]?.string,
              (1...128).contains(name.count),
              let version = object["version"]?.string,
              (1...64).contains(version.count) else {
            return nil
        }
        return UIEvidenceProducer(name: name, version: version)
    }

    private static func parseElement(_ value: JSONValue) -> UIEvidenceElement? {
        guard let object = exactObject(
            value,
            required: ["id", "kind", "bbox", "confidence", "evidence"],
            optional: ["role", "text", "parent_id", "interactive"]
        ),
        let id = validID(object["id"]?.string),
        let kind = UIEvidenceElementKind(rawValue: object["kind"]?.string ?? ""),
        let bbox = parseBBox(object["bbox"]),
        let confidence = unitNumber(object["confidence"]),
        let evidence = UIEvidenceEvidence(rawValue: object["evidence"]?.string ?? "") else {
            return nil
        }

        let role: String?
        if object.keys.contains("role") {
            guard let value = object["role"]?.string, (1...64).contains(value.count) else { return nil }
            role = value
        } else {
            role = nil
        }

        let text: String?
        if object.keys.contains("text") {
            guard let value = object["text"]?.string, value.count <= 8_192 else { return nil }
            text = value
        } else {
            text = nil
        }

        let parentID: String?
        if object.keys.contains("parent_id") {
            if object["parent_id"] == .null {
                parentID = nil
            } else {
                guard let value = validID(object["parent_id"]?.string) else { return nil }
                parentID = value
            }
        } else {
            parentID = nil
        }

        let interactive: Bool?
        if object.keys.contains("interactive") {
            guard let value = object["interactive"]?.bool else { return nil }
            interactive = value
        } else {
            interactive = nil
        }

        return UIEvidenceElement(
            id: id,
            kind: kind,
            role: role,
            bbox: bbox,
            text: text,
            confidence: confidence,
            evidence: evidence,
            parentID: parentID,
            interactive: interactive
        )
    }

    private static func parseRepeatedGroup(_ value: JSONValue) -> UIEvidenceRepeatedGroup? {
        guard let object = exactObject(
            value,
            required: ["id", "axis", "member_ids", "bbox", "confidence", "evidence"],
            optional: []
        ),
        let id = validID(object["id"]?.string),
        let axis = UIEvidenceAxis(rawValue: object["axis"]?.string ?? ""),
        let rawMemberIDs = object["member_ids"]?.array,
        (1...100).contains(rawMemberIDs.count),
        let memberIDs = validIDs(rawMemberIDs),
        Set(memberIDs).count == memberIDs.count,
        let bbox = parseBBox(object["bbox"]),
        let confidence = unitNumber(object["confidence"]),
        let evidence = UIEvidenceEvidence(rawValue: object["evidence"]?.string ?? "") else {
            return nil
        }
        return UIEvidenceRepeatedGroup(
            id: id,
            axis: axis,
            memberIDs: memberIDs,
            bbox: bbox,
            confidence: confidence,
            evidence: evidence
        )
    }

    private static func parseSourceTree(_ value: JSONValue) -> UIEvidenceSourceTree? {
        guard let object = exactObject(
            value,
            required: ["kind", "nodes", "truncated"],
            optional: []
        ),
        let kind = UIEvidenceSourceTreeKind(rawValue: object["kind"]?.string ?? ""),
        let rawNodes = object["nodes"]?.array,
        rawNodes.count <= 1_000,
        let nodes = parseArray(rawNodes, transform: parseSourceNode),
        let truncated = object["truncated"]?.bool else {
            return nil
        }
        if kind == .none {
            guard nodes.isEmpty else { return nil }
        } else {
            guard !nodes.isEmpty else { return nil }
        }
        return UIEvidenceSourceTree(kind: kind, nodes: nodes, truncated: truncated)
    }

    private static func parseSourceNode(_ value: JSONValue) -> UIEvidenceSourceNode? {
        guard let object = exactObject(
            value,
            required: ["id", "parent_id", "role", "interactive", "visible", "enabled"],
            optional: ["label", "bbox"]
        ),
        let id = validID(object["id"]?.string),
        let parentID: String? = {
            if object["parent_id"] == .null { return nil }
            return validID(object["parent_id"]?.string)
        }(),
        object["parent_id"] == .null || parentID != nil,
        let role = object["role"]?.string,
        (1...64).contains(role.count),
        let interactive = object["interactive"]?.bool,
        let visible = object["visible"]?.bool,
        let enabled = object["enabled"]?.bool else {
            return nil
        }

        let label: String?
        if object.keys.contains("label") {
            guard let value = object["label"]?.string, value.count <= 4_096 else { return nil }
            label = value
        } else {
            label = nil
        }

        let bbox: UIEvidenceBBox?
        if object.keys.contains("bbox") {
            guard let value = parseBBox(object["bbox"]) else { return nil }
            bbox = value
        } else {
            bbox = nil
        }

        return UIEvidenceSourceNode(
            id: id,
            parentID: parentID,
            role: role,
            label: label,
            bbox: bbox,
            interactive: interactive,
            visible: visible,
            enabled: enabled
        )
    }

    private static func parseCrop(_ value: JSONValue) -> UIEvidenceCrop? {
        guard let object = exactObject(
            value,
            required: ["asset_id", "source_bbox", "purpose"],
            optional: []
        ),
        let assetID = validAssetID(object["asset_id"]?.string),
        let sourceBBox = parseBBox(object["source_bbox"]),
        let purpose = UIEvidenceCropPurpose(rawValue: object["purpose"]?.string ?? "") else {
            return nil
        }
        return UIEvidenceCrop(assetID: assetID, sourceBBox: sourceBBox, purpose: purpose)
    }

    private static func parseUncertainty(_ value: JSONValue) -> UIEvidenceUncertainty? {
        guard let object = exactObject(
            value,
            required: ["description", "related_element_ids"],
            optional: ["reason"]
        ),
        let description = object["description"]?.string,
        (1...1_024).contains(description.count),
        let rawIDs = object["related_element_ids"]?.array,
        rawIDs.count <= 64,
        let relatedIDs = validIDs(rawIDs) else {
            return nil
        }

        let reason: String?
        if object.keys.contains("reason") {
            guard let value = object["reason"]?.string, value.count <= 1_024 else { return nil }
            reason = value
        } else {
            reason = nil
        }
        return UIEvidenceUncertainty(
            description: description,
            relatedElementIDs: relatedIDs,
            reason: reason
        )
    }

    private static func parseLimits(_ value: JSONValue) -> UIEvidenceLimits? {
        guard let object = exactObject(
            value,
            required: ["element_count", "elements_truncated", "tree_nodes_truncated"],
            optional: []
        ),
        let elementCount = boundedInteger(object["element_count"], range: 0...500),
        let elementsTruncated = object["elements_truncated"]?.bool,
        let treeNodesTruncated = object["tree_nodes_truncated"]?.bool else {
            return nil
        }
        return UIEvidenceLimits(
            elementCount: elementCount,
            elementsTruncated: elementsTruncated,
            treeNodesTruncated: treeNodesTruncated
        )
    }

    private static func validateCrossReferences(
        elements: [UIEvidenceElement],
        repeatedGroups: [UIEvidenceRepeatedGroup],
        sourceTree: UIEvidenceSourceTree,
        crops: [UIEvidenceCrop],
        uncertainties: [UIEvidenceUncertainty],
        source: UIEvidenceSource
    ) -> Bool {
        let elementIDs = Set(elements.map(\.id))
        guard elementIDs.count == elements.count,
              elements.allSatisfy({ $0.parentID == nil || elementIDs.contains($0.parentID!) }) else {
            return false
        }

        let groupIDs = Set(repeatedGroups.map(\.id))
        guard groupIDs.count == repeatedGroups.count,
              repeatedGroups.allSatisfy({
                  $0.memberIDs.allSatisfy(elementIDs.contains)
              }) else {
            return false
        }

        let treeIDs = Set(sourceTree.nodes.map(\.id))
        guard treeIDs.count == sourceTree.nodes.count,
              sourceTree.nodes.allSatisfy({ $0.parentID == nil || treeIDs.contains($0.parentID!) }) else {
            return false
        }

        let cropAssetIDs = Set(crops.map(\.assetID))
        guard cropAssetIDs.count == crops.count,
              !cropAssetIDs.contains(source.assetID),
              uncertainties.allSatisfy({
                  $0.relatedElementIDs.allSatisfy(elementIDs.contains)
              }) else {
            return false
        }
        return true
    }

    private static func parseBBox(_ value: JSONValue?) -> UIEvidenceBBox? {
        guard let value,
              let object = exactObject(value, required: ["x", "y", "width", "height"], optional: []),
              let x = unitNumber(object["x"]),
              let y = unitNumber(object["y"]),
              let width = unitNumber(object["width"]),
              let height = unitNumber(object["height"]),
              x + width <= 1.000_000_001,
              y + height <= 1.000_000_001,
              width != 0 || height != 0 else {
            return nil
        }
        return UIEvidenceBBox(x: x, y: y, width: width, height: height)
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

    private static func parseArray<T>(
        _ values: [JSONValue],
        transform: (JSONValue) -> T?
    ) -> [T]? {
        let parsed = values.compactMap(transform)
        return parsed.count == values.count ? parsed : nil
    }

    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        let number: Double?
        switch value {
        case .integer(let integer): number = Double(integer)
        case .number(let value): number = value
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func unitNumber(_ value: JSONValue?) -> Double? {
        guard let number = finiteNumber(value), (0...1).contains(number) else { return nil }
        return number
    }

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard let integer = boundedInteger(value, range: 1...Int.max) else { return nil }
        return integer
    }

    private static func boundedInteger(_ value: JSONValue?, range: ClosedRange<Int>) -> Int? {
        let integer: Int?
        switch value {
        case .integer(let value): integer = value
        case .number(let value) where value.rounded() == value: integer = Int(value)
        default: integer = nil
        }
        guard let integer, range.contains(integer) else { return nil }
        return integer
    }

    private static func validIDs(_ values: [JSONValue]) -> [String]? {
        let ids = values.compactMap { validID($0.string) }
        return ids.count == values.count ? ids : nil
    }

    private static func validID(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: "^[A-Za-z][A-Za-z0-9._:-]{0,127}$",
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

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

struct UIEvidenceSource: Equatable, Sendable {
    let assetID: String
    let sourceKind: UIEvidenceSourceKind
    let sha256: String
    let mimeType: String
    let width: Int
    let height: Int
}

enum UIEvidenceSourceKind: String, Equatable, Sendable {
    case staticImage = "static_image"
    case appScreenshot = "app_screenshot"
    case webScreenshot = "web_screenshot"
}

struct UIEvidenceProducer: Equatable, Sendable {
    let name: String
    let version: String
}

struct UIEvidenceElement: Equatable, Sendable {
    let id: String
    let kind: UIEvidenceElementKind
    let role: String?
    let bbox: UIEvidenceBBox
    let text: String?
    let confidence: Double
    let evidence: UIEvidenceEvidence
    let parentID: String?
    let interactive: Bool?
}

enum UIEvidenceElementKind: String, Equatable, Sendable {
    case text
    case image
    case icon
    case control
    case container
    case separator
    case unknown
}

enum UIEvidenceEvidence: String, Equatable, Sendable {
    case observed
    case inferred
    case uncertain
}

struct UIEvidenceRepeatedGroup: Equatable, Sendable {
    let id: String
    let axis: UIEvidenceAxis
    let memberIDs: [String]
    let bbox: UIEvidenceBBox
    let confidence: Double
    let evidence: UIEvidenceEvidence
}

enum UIEvidenceAxis: String, Equatable, Sendable {
    case vertical
    case horizontal
    case grid
    case unknown
}

struct UIEvidenceSourceTree: Equatable, Sendable {
    let kind: UIEvidenceSourceTreeKind
    let nodes: [UIEvidenceSourceNode]
    let truncated: Bool
}

enum UIEvidenceSourceTreeKind: String, Equatable, Sendable {
    case accessibility
    case dom
    case none
}

struct UIEvidenceSourceNode: Equatable, Sendable {
    let id: String
    let parentID: String?
    let role: String
    let label: String?
    let bbox: UIEvidenceBBox?
    let interactive: Bool
    let visible: Bool
    let enabled: Bool
}

struct UIEvidenceCrop: Equatable, Sendable {
    let assetID: String
    let sourceBBox: UIEvidenceBBox
    let purpose: UIEvidenceCropPurpose
}

enum UIEvidenceCropPurpose: String, Equatable, Sendable {
    case navigation
    case content
    case controls
    case repeatedGroup = "repeated_group"
    case detail
    case unknown
}

struct UIEvidenceUncertainty: Equatable, Sendable {
    let description: String
    let relatedElementIDs: [String]
    let reason: String?
}

struct UIEvidenceLimits: Equatable, Sendable {
    let elementCount: Int
    let elementsTruncated: Bool
    let treeNodesTruncated: Bool
}

struct UIEvidenceBBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
