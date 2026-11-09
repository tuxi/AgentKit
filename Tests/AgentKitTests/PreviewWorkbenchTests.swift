import XCTest
@testable import AgentKit

@MainActor
final class PreviewWorkbenchTests: XCTestCase {
    func testRuntimeEngineProjectsLatestValidPreviewRevision() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let first = try loadEvent("event-revision-1.json", root: root)
        let duplicate = try loadEvent("event-duplicate.json", root: root)
        let conflict = try loadEvent("event-revision-conflict.json", root: root)
        let second = try loadEvent("event-revision-2.json", root: root)
        let engine = RuntimeEngine(sessionID: "session_fixture")

        await engine.ingest(.previewArtifact(first))
        var snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.previewArtifacts.count, 1)
        XCTAssertEqual(snapshot.previewArtifacts.first?.revision, 1)

        await engine.ingest(.previewArtifact(duplicate))
        await engine.ingest(.previewArtifact(conflict))
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.previewArtifacts.count, 1)
        XCTAssertEqual(snapshot.previewArtifacts.first?.revision, 1)

        await engine.ingest(.previewArtifact(second))
        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.previewArtifacts.count, 1)
        XCTAssertEqual(snapshot.previewArtifacts.first?.revision, 2)
        XCTAssertEqual(snapshot.previewArtifacts.first?.status, .failed)
    }

    func testHistoryReplayMergesPreviewArtifacts() async throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let event = try loadEvent("event-revision-1.json", root: root)
        let engine = RuntimeEngine(sessionID: "session_fixture")
        await engine.importHistory([
            .turnStarted(turnID: "turn_fixture", text: "preview"),
            .previewArtifact(event),
            .turnFinished(turnID: "turn_fixture", text: "done", textAnnotations: []),
        ])
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.previewArtifacts.map(\.artifactID), ["preview_fixture_interactive"])
    }

    func testBuilderProjectsPreviewIntoOwningTurn() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let artifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let turn = ConversationTurn(
            id: "turn_turn_fixture_user",
            userPrompt: MessageNodePayload(role: .user, text: "preview"),
            blocks: [],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [artifact],
                generation: 1
            ),
            conversationID: "session_fixture",
            revision: 1
        )
        let preview = try XCTUnwrap(document.turns.first?.previews?.first)
        XCTAssertEqual(preview.id, artifact.artifactID)
        XCTAssertEqual(preview.artifactID, artifact.artifactID)
        XCTAssertEqual(preview.revision, 1)
        XCTAssertEqual(preview.kind, "interactive_html")
        XCTAssertEqual(preview.presentationState, "interactiveReady")
        XCTAssertEqual(preview.statusLabel, "预览就绪")
        XCTAssertEqual(preview.fallbackAssetID, "asset_fixture_fallback")
        XCTAssertEqual(preview.fallbackAlt, "DreamLog Duo preview fallback")
        XCTAssertEqual(preview.initialState, "collapsed")

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(document), encoding: .utf8))
        XCTAssertTrue(encoded.contains("\"previews\""))
        XCTAssertFalse(encoded.contains("viewer_html"))
        XCTAssertFalse(encoded.contains("<div>Preview</div>"))
    }

    func testBuilderProjectsExpiredPreviewWithFallbackReason() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let artifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("expired-replay.json"))
        )
        let turn = ConversationTurn(
            id: "turn_turn_fixture_user",
            userPrompt: nil,
            blocks: [],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [artifact],
                generation: 1
            ),
            conversationID: "session_fixture",
            revision: 1
        )
        let preview = try XCTUnwrap(document.turns.first?.previews?.first)
        XCTAssertEqual(preview.presentationState, "expired")
        XCTAssertEqual(preview.statusLabel, "已过期")
        XCTAssertEqual(preview.fallbackText, artifact.fallback?.text)
        XCTAssertEqual(preview.degradedReason, "预览已过期，正在显示静态证据。")
        XCTAssertNotNil(preview.expiresAtMilliseconds)
    }

    func testBuilderDoesNotAttachPreviewToUnrelatedTurn() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let artifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let turn = ConversationTurn(
            id: "turn_other_user",
            userPrompt: nil,
            blocks: [],
            footer: nil,
            isLive: false
        )
        let document = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [artifact],
                generation: 1
            ),
            conversationID: "session_fixture",
            revision: 1
        )
        XCTAssertNil(document.turns.first?.previews)
    }

    func testDifferUpdatesTurnWhenPreviewRevisionChanges() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let firstArtifact = try PreviewArtifact.decode(
            data: Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        )
        let secondEvent = try loadEvent("event-revision-2.json", root: root)
        let secondArtifact = try XCTUnwrap(secondEvent.artifact)
        let turn = ConversationTurn(
            id: "turn_turn_fixture_user",
            userPrompt: MessageNodePayload(role: .user, text: "preview"),
            blocks: [.text(
                id: "answer",
                MessageNodePayload(role: .assistant, text: "done")
            )],
            footer: nil,
            isLive: false
        )
        let first = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [firstArtifact],
                generation: 1
            ),
            conversationID: "session_fixture",
            revision: 1
        )
        let second = ConversationWebDocumentBuilder.build(
            snapshot: RuntimeSnapshot(
                timeline: [],
                turns: [turn],
                previewArtifacts: [secondArtifact],
                generation: 2
            ),
            conversationID: "session_fixture",
            revision: 2
        )
        let update = try XCTUnwrap(ConversationWebDocumentDiffer.update(from: first, to: second))
        XCTAssertEqual(update.kind, .patch)
        XCTAssertEqual(update.patch?.operations.map(\.kind), [.updateTurn])
        let updatedPreview = try XCTUnwrap(update.patch?.operations.first?.turn?.previews?.first)
        XCTAssertEqual(updatedPreview.id, firstArtifact.artifactID)
        XCTAssertEqual(updatedPreview.revision, 2)
        XCTAssertEqual(updatedPreview.presentationState, "staticFallback")
    }

    private func loadEvent(_ file: String, root: URL) throws -> PreviewArtifactEvent {
        let data = try Data(contentsOf: root.appendingPathComponent(file))
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        guard case .previewArtifact(let event) = AgentEvent.from(wire: wire) else {
            throw NSError(domain: "PreviewWorkbenchTests", code: 1)
        }
        return event
    }
}
