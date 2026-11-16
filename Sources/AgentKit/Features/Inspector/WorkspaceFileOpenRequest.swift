import Foundation
import ClientToolProtocol

/// A host-handled live workspace destination. Immutable resources keep their own viewer.
public struct WorkspaceFileOpenRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let line: Int?
    public let isDirectory: Bool
    public let workspaceID: String?
    public let contextID: String?
    public init(path: String, line: Int? = nil, isDirectory: Bool = false, workspaceID: String? = nil, contextID: String? = nil) {
        id = UUID(); self.path = path; self.line = line; self.isDirectory = isDirectory; self.workspaceID = workspaceID; self.contextID = contextID
    }
    public static func liveAsset(_ asset: AgentAssetRef) -> WorkspaceFileOpenRequest? {
        guard ["file", "file_location", "symbol", "search_result", "directory", "image", "video", "audio", "pdf"].contains(asset.kind) else { return nil }
        // A resource URI denotes a resource version even when a display path is present.
        if let raw = asset.uri, let url = URL(string: raw), let scheme = url.scheme {
            guard scheme.lowercased() == "file", url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        }
        let path = asset.workspaceRelativePath ?? asset.absolutePath ?? asset.uri.flatMap { URL(string: $0)?.isFileURL == true ? URL(string: $0)?.path : nil }
        guard let path, !path.isEmpty else { return nil }
        return Self(path: path, line: asset.range?.startLine, isDirectory: asset.kind == "directory", workspaceID: asset.workspaceID)
    }
}

@MainActor extension WorkspaceStore {
    /// Returns false when the host has not installed Files navigation (e.g. legacy iOS).
    @discardableResult public func openWorkspaceFile(_ request: WorkspaceFileOpenRequest) -> Bool {
        guard workspaceFileNavigationEnabled else { return false }
        if let expected = request.workspaceID {
            let actual = activeConversationViewModel?.workspaceAnchor?.id ?? selectedConversation?.workspace?.id
            guard expected == actual else { return false }
        }
        dismissInspector()
        inspectorWorkspaceState.fileOpenRequest = WorkspaceFileOpenRequest(path: request.path, line: request.line, isDirectory: request.isDirectory, workspaceID: request.workspaceID, contextID: workspaceFileNavigationContext)
        inspectorWorkspaceState.open(.files)
        isInspectorPresented = true
        return true
    }
    @discardableResult public func openWorkspaceFile(path: String, line: Int? = nil, isDirectory: Bool = false) -> Bool {
        openWorkspaceFile(WorkspaceFileOpenRequest(path: path, line: line, isDirectory: isDirectory))
    }
    func routeWorkspaceSelection(_ selection: InspectorSelection) -> Bool {
        switch selection {
        case .file(let file): return openWorkspaceFile(path: file.filePath)
        case .directory(let directory): return openWorkspaceFile(path: directory.path, isDirectory: true)
        case .asset(let payload):
            guard let request = WorkspaceFileOpenRequest.liveAsset(payload.asset) else { return false }
            if let expected = payload.conversationID, expected != selectedConversation?.id { return false }
            if let workspace = payload.workspace?.id {
                let actual = activeConversationViewModel?.workspaceAnchor?.id ?? selectedConversation?.workspace?.id
                guard workspace == actual else { return false }
            }
            return openWorkspaceFile(request)
        default: return false
        }
    }
}

public extension SessionRailOutput {
    var workspaceFileRequest: WorkspaceFileOpenRequest? {
        guard contentMode == "live_workspace", state != "deleted" else { return nil }
        if let path = relativePath, !path.isEmpty {
            return WorkspaceFileOpenRequest(path: path, line: latest.asset?.range?.startLine, isDirectory: kind == "directory", workspaceID: latest.asset?.workspaceID)
        }
        return latest.asset.flatMap(WorkspaceFileOpenRequest.liveAsset)
    }
}
