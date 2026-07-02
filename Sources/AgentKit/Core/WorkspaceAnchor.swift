//
//  WorkspaceAnchor.swift
//  AgentKit
//
//  Structured workspace identity from agent-wire conversation refs/details.
//

import Foundation

public struct WorkspaceAnchor: Sendable, Hashable, Codable {
    public let id: String
    public let name: String?
    public let rootPath: String?
    public let runtimeCWD: String?
    public let displayPath: String?
    public let kind: String?

    public init(
        id: String,
        name: String? = nil,
        rootPath: String? = nil,
        runtimeCWD: String? = nil,
        displayPath: String? = nil,
        kind: String? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.runtimeCWD = runtimeCWD
        self.displayPath = displayPath
        self.kind = kind
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let displayPath, !displayPath.isEmpty { return displayPath }
        if let rootPath, !rootPath.isEmpty {
            return URL(fileURLWithPath: rootPath).lastPathComponent
        }
        if let runtimeCWD, !runtimeCWD.isEmpty {
            return URL(fileURLWithPath: runtimeCWD).lastPathComponent
        }
        return id
    }

    public var localRootPath: String? {
        if let rootPath, !rootPath.isEmpty { return rootPath }
        if let runtimeCWD, !runtimeCWD.isEmpty { return runtimeCWD }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case rootPath = "root_path"
        case runtimeCWD = "runtime_cwd"
        case displayPath = "display_path"
    }
}
