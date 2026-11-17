import Foundation
import CryptoKit

/// Presentation data belongs to the accepted turn, never inferred by stripping
/// a suffix from arbitrary user text. The digest verifies the replayed payload.
public struct ComposerMessagePresentation: Codable, Sendable, Equatable {
    public var text: String
    public var fileReferences: [ComposerFileReference]
    public var payloadDigest: String

    public init(text: String, fileReferences: [ComposerFileReference], modelText: String) {
        self.text = text
        self.fileReferences = fileReferences
        self.payloadDigest = Self.digest(modelText)
    }

    public func matches(_ modelText: String) -> Bool { payloadDigest == Self.digest(modelText) }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ComposerMessageContent {
    static func referenceFiles(files: [ComposerFileReference], attachments: [DraftAttachmentReference], imagesAsPaths: Bool) -> [ComposerFileReference] {
        guard imagesAsPaths else { return files }
        return files + attachments.compactMap { attachment in
            let path: String
            if let source = URL(string: attachment.resourceURI), source.isFileURL {
                path = source.path
            } else if let asset = attachment.localAsset {
                path = asset.relativePath
            } else { return nil }
            var reference = ComposerFileReference(path: path, workspacePath: nil, isDirectory: false)
            if let id = UUID(uuidString: attachment.id) { reference.id = id }
            return reference
        }
    }

    static func modelText(text: String, files: [ComposerFileReference], tokens: [ComposerToken]) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !files.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let paths = files.map { file in
                let path = file.relativePath ?? file.path
                let quoted = (try? encoder.encode(path)).flatMap { String(data: $0, encoding: .utf8) } ?? path
                return "- " + (file.isDirectory ? "目录：" : "文件：") + quoted
            }.joined(separator: "\n")
            if !result.isEmpty { result += "\n\n" }
            result += "引用的本地路径（按需读取）：\n" + paths
        }
        let contexts = tokens.compactMap(\.item.contextText)
        if !contexts.isEmpty {
            if !result.isEmpty { result += "\n\n" }
            result += "引用对话快照（参考资料）：\n" + contexts.joined(separator: "\n\n")
        }
        return result
    }
}

extension ConversationTurn {
    func withComposerPresentation(_ presentation: ComposerMessagePresentation?) -> ConversationTurn {
        guard let prompt = userPrompt, let presentation, presentation.matches(prompt.text) else { return self }
        let labels = presentation.fileReferences.map { ($0.isDirectory ? "[目录] " : "[文件] ") + $0.displayPath }
        let display = ([presentation.text] + labels).filter { !$0.isEmpty }.joined(separator: "\n")
        return ConversationTurn(id: id, userPrompt: MessageNodePayload(role: prompt.role, text: display,
            isStreaming: prompt.isStreaming, textAnnotations: prompt.textAnnotations, userAssets: prompt.userAssets, localAssets: prompt.localAssets),
            blocks: blocks, plans: plans, todos: todos, footer: footer, isLive: isLive, invocations: invocations,
            contentVersion: contentVersion, startedAt: startedAt, finishedAt: finishedAt, changes: changes)
    }
}

/// A selected path grants read access only to that file, or descendants of an
/// explicitly selected directory. Canonicalize both sides to prevent symlink escapes.
public enum ComposerReferencedFileAccess {
    public static func allowsRead(_ url: URL, workspaceRoot: URL, references: [ComposerFileReference]) -> Bool {
        guard url.isFileURL else { return false }
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return references.contains { reference in
            let path = reference.relativePath ?? reference.path
            let target = (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : workspaceRoot.appendingPathComponent(path)
            let allowed = target.standardizedFileURL.resolvingSymlinksInPath().path
            if candidate == allowed { return true }
            let prefix = allowed.hasSuffix("/") ? allowed : allowed + "/"
            return reference.isDirectory && candidate.hasPrefix(prefix)
        }
    }
}
