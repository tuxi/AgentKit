import Foundation
import XCTest
@testable import AgentKit

final class BuiltInPreviewResourcesTests: XCTestCase {
    private let previewID = "dreamlog-duo-creation-home"

    func testBundledPreviewLoadsAndMatchesManifest() throws {
        let resource = try BuiltInPreviewCatalog.load(id: previewID)
        XCTAssertEqual(resource.manifest.id, previewID)
        XCTAssertEqual(resource.manifest.status, "accepted")
        XCTAssertEqual(resource.manifest.current, "current.html")
        XCTAssertEqual(resource.htmlURL.lastPathComponent, "current.html")
        XCTAssertEqual(resource.html.count, resource.manifest.html.bytes)
        XCTAssertLessThan(resource.html.count, PreviewArtifact.maximumViewerBytes)
        let digest = PreviewRFC8785.sha256(data: resource.html).lowercased()
        let normalizedDigest = digest.hasPrefix("sha256:")
            ? String(digest.dropFirst("sha256:".count))
            : digest
        XCTAssertEqual(normalizedDigest, resource.manifest.html.sha256.lowercased())
        XCTAssertFalse(resource.html.isEmpty)
    }

    func testBundledPreviewDoesNotContainEvidenceRevisionsOrScreenshots() throws {
        let root = try BuiltInPreviewCatalog.rootURL()
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var relativePaths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            relativePaths.append(relative)
        }

        XCTAssertFalse(relativePaths.isEmpty)
        XCTAssertFalse(relativePaths.contains { path in
            path.split(separator: "/").contains("evidence")
                || path.split(separator: "/").contains("revisions")
        })
        XCTAssertFalse(relativePaths.contains {
            $0.lowercased().hasSuffix(".png")
                || $0.lowercased().hasSuffix(".jpg")
                || $0.lowercased().hasSuffix(".jpeg")
        })
    }

    func testRejectsPathTraversalOutsidePreviewRoot() throws {
        let root = try BuiltInPreviewCatalog.rootURL()
        for path in ["../index.json", "%2e%2e/index.json", "/index.json"] {
            XCTAssertThrowsError(try BuiltInPreviewCatalog.safeURL(for: path, under: root)) {
                XCTAssertEqual($0 as? BuiltInPreviewError, .unsafePath(path))
            }
        }
    }

    func testRejectsRemoteResourceReferences() throws {
        XCTAssertThrowsError(
            try BuiltInPreviewCatalog.validateNoRemoteResources(
                #"<img src="https://example.com/pixel.png">"#
            )
        )
        XCTAssertThrowsError(
            try BuiltInPreviewCatalog.validateNoRemoteResources(
                #"<style>.hero{background:url(https://example.com/a.png)}</style>"#
            )
        )
        XCTAssertNoThrow(
            try BuiltInPreviewCatalog.validateNoRemoteResources(
                ##"<img src="data:image/png;base64,AAAA"><a href="#details">details</a>"##
            )
        )
    }
}
