#if os(macOS)
import AppKit
import XCTest
@testable import AgentKit

@MainActor
final class MacComposerSendTests: XCTestCase {
    func testImageThumbnailLoadsFromDroppedFileWithoutHostResolver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { image.setColor(.red, atX: x, y: y) } }
        let url = root.appendingPathComponent("截图.png")
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        let attachment = DraftAttachmentReference(id: UUID().uuidString, displayName: url.lastPathComponent, resourceURI: url.absoluteString)
        let resolved = await MacComposerImagePreview.url(for: attachment, resolver: nil)
        XCTAssertEqual(resolved, url)
        let thumbnail = await MacComposerImagePreview.thumbnail(at: url)
        XCTAssertNotNil(thumbnail)
        XCTAssertLessThanOrEqual(thumbnail?.size.width ?? 0, 288)
    }

    func testTwoImagesAndThreePathsPrepareAsLocalMultimodalAssets() async throws {
        let states = InMemoryConversationLocalStateStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "composer-send-" + UUID().uuidString))
        let store = WorkspaceStore(usesEmbeddedRuntime: false, localStateStore: states, localUserAssetStager: ComposerSendStager(), recentWorkspaces: RecentWorkspacesStore(defaults: defaults), projects: ProjectsStore(root: nil))
        let key = ConversationLocalStateKey.session("s")
        let images = [URL(fileURLWithPath: "/fixtures/screenshot-1.png"), URL(fileURLWithPath: "/fixtures/screenshot-2.png")]
        let files = [ComposerFileReference(path: "/outside/ai", workspacePath: "/project", isDirectory: true), ComposerFileReference(path: "/outside/app.dmg", workspacePath: "/project", isDirectory: false), ComposerFileReference(path: "/outside/movie.m4v", workspacePath: "/project", isDirectory: false)]
        try states.updateState(for: key) { state in
            state.composerDraft.text = "检查更新"
            state.composerDraft.fileReferences = files
        }
        await store.addDroppedFiles(images, for: key, maxFilesCount: 4)
        let payload = try await store.prepareUserAssets(for: key, workspaceRoot: URL(fileURLWithPath: "/project"))
        XCTAssertTrue(payload.assets.isEmpty, "assets is the retired Gateway/OSS path")
        XCTAssertEqual(payload.localAssets.count, 2)
        XCTAssertTrue(payload.localAssets.allSatisfy { $0.kind == "image" && $0.transferPolicy == .localOnly })
        let draft = try XCTUnwrap(states.state(for: key)?.composerDraft)
        let text = ComposerMessageContent.modelText(text: draft.text, files: draft.fileReferences, tokens: [])
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 3)
        XCTAssertFalse(text.contains("screenshot-1.png"), "image pixels use local_assets, not a path-only reference")
        let encoded = try JSONEncoder().encode(OutgoingAgentInput.from(input: .text(text, localAssets: payload.localAssets)))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((wire["local_assets"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(wire["assets"])
    }

    func testPathValidationErrorsExplainFailureInsteadOfGenericSendError() {
        let denied = WorkspaceStore.composerPathRejection(RuntimeHTTPError.unexpectedStatus(403, body: "{\"msg\":\"external paths are unavailable in this runtime\"}"))
        XCTAssertEqual(denied.code, "reference_access_denied")
        XCTAssertTrue(denied.message.contains("工作区外"))
        let missing = WorkspaceStore.composerPathRejection(RuntimeHTTPError.unexpectedStatus(409, body: "missing"))
        XCTAssertTrue(missing.message.contains("执行环境"))
        let unsupported = WorkspaceStore.composerPathRejection(RuntimeHTTPError.unexpectedStatus(404, body: "not found"))
        XCTAssertTrue(unsupported.message.contains("更新 Runtime"))
    }
}

private actor ComposerSendStager: LocalUserAssetStaging {
    func stage(attachment: DraftAttachmentReference, workspaceRoot: URL) async throws -> LocalUserAssetRef {
        LocalUserAssetRef(id: attachment.id, relativePath: "user-assets/\(attachment.id)/\(attachment.displayName)", filename: attachment.displayName, mimeType: "image/png", kind: "image", sizeBytes: 42, sha256: String(repeating: "a", count: 64))
    }
}
#endif
