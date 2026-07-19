import XCTest
@testable import AgentKit

final class UserAssetsProtocolTests: XCTestCase {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/protocols/fixtures/user-assets", isDirectory: true)
    }

    func testCanonicalTextImageFixtureMatchesOutgoingWireShape() throws {
        let fixture = try fixtureData("agent_input_text_with_image.json")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let asset = UserAssetRef(
            assetID: 10001,
            sha256: String(repeating: "a", count: 64),
            mimeType: "image/jpeg",
            filename: "build-error.jpg"
        )
        let input = AgentInput.text(
            "解释这张截图里的错误",
            model: "default",
            assets: [asset],
            requestID: "req_user_asset_001"
        )
        let encoded = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)

        XCTAssertEqual(actual, expected)
    }

    func testCanonicalImageOnlyFixtureMatchesOutgoingWireShape() throws {
        let fixture = try fixtureData("agent_input_image_only.json")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let input = AgentInput.text(
            "",
            assets: [UserAssetRef(
                assetID: 10002,
                sha256: String(repeating: "b", count: 64),
                mimeType: "image/png",
                filename: "diagram.png"
            )],
            requestID: "req_user_asset_002"
        )
        let encoded = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)

        XCTAssertEqual(actual, expected)
    }

    func testCanonicalTwoImageFixturePreservesSelectionOrder() throws {
        let fixture = try fixtureData("agent_input_two_images.json")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let input = AgentInput.text(
            "比较这两张图片",
            assets: [
                UserAssetRef(
                    assetID: 10004,
                    sha256: String(repeating: "c", count: 64),
                    mimeType: "image/jpeg",
                    filename: "before.jpg"
                ),
                UserAssetRef(
                    assetID: 10005,
                    sha256: String(repeating: "d", count: 64),
                    mimeType: "image/png",
                    filename: "after.png"
                ),
            ],
            requestID: "req_user_asset_004"
        )
        let encoded = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(input.assets.map(\.assetID), [10004, 10005])
    }

    func testTurnStartedFixtureKeepsUserAssetsSeparateFromToolAssets() throws {
        let wire = try JSONDecoder().decode(
            WireFrame.self,
            from: fixtureData("turn_started_with_image.json")
        )
        XCTAssertNil(wire.assets)
        XCTAssertEqual(wire.userAssets?.map(\.assetID), [10001])

        let event = try XCTUnwrap(AgentEvent.from(wire: wire))
        guard case .turnStarted(let turnID, let text, let userAssets) = event else {
            return XCTFail("Expected turn_started")
        }
        XCTAssertEqual(turnID, "turn_user_asset_001")
        XCTAssertEqual(text, "解释这张截图里的错误")
        XCTAssertEqual(userAssets.first?.filename, "build-error.jpg")
    }

    func testCanonicalRejectionFixturesDecodeOpenErrorCodes() throws {
        for (name, expectedCode) in [
            ("agent_input_rejected_invalid_assets.json", "invalid_assets"),
            ("agent_input_rejected_request_conflict.json", "request_conflict"),
        ] {
            let wire = try JSONDecoder().decode(WireFrame.self, from: fixtureData(name))
            XCTAssertEqual(wire.type, "agent_input_rejected")
            XCTAssertEqual(wire.error?.code, expectedCode)
            XCTAssertFalse(wire.error?.message?.isEmpty ?? true)
        }
    }

    func testAssetUnavailableFixtureMapsToStructuredTurnFailure() throws {
        let wire = try JSONDecoder().decode(
            WireFrame.self,
            from: fixtureData("turn_failed_asset_unavailable.json")
        )
        let event = try XCTUnwrap(AgentEvent.from(wire: wire))
        guard case .turnFailed(let turnID, _, let message, let errorCode) = event else {
            return XCTFail("Expected turn_failed")
        }
        XCTAssertEqual(turnID, "turn_user_asset_001")
        XCTAssertEqual(errorCode, "asset_unavailable")
        XCTAssertEqual(message, "One or more image assets are unavailable")
    }

    func testHelloImageInputMapsToCapabilityFlag() throws {
        let wire = try JSONDecoder().decode(
            WireFrame.self,
            from: fixtureData("hello_image_input.json")
        )
        let flags = CodeAgentSessionChannel.flags(from: wire.capabilities ?? [])
        XCTAssertTrue(flags.contains(.imageInput))
    }

    func testClientValidationRejectsDuplicateAndUnsupportedAssets() throws {
        let asset = UserAssetRef(
            assetID: 7,
            sha256: String(repeating: "a", count: 64),
            mimeType: "image/jpeg",
            filename: "safe.jpg"
        )
        XCTAssertThrowsError(try AgentInput.text("x", assets: [asset, asset])
            .validateForSubmission(supportsImageInput: true)) { error in
            XCTAssertEqual(error as? UserAssetValidationError, .duplicateAssetID(7))
        }
        XCTAssertThrowsError(try AgentInput.text("x", assets: [asset])
            .validateForSubmission(supportsImageInput: false)) { error in
            XCTAssertEqual((error as? AgentInputRejection)?.code, "image_input_unsupported")
        }
    }

    func testPendingCoordinatorSurvivesSubscriberCancellation() async throws {
        let coordinator = AgentInputSubmissionCoordinator()
        let input = AgentInput.text("hello", requestID: "req-stable")
        var first: AgentInputSubmissionTicket? = await coordinator.register(input)
        XCTAssertEqual(first?.requestID, "req-stable")
        first = nil
        try await Task.sleep(for: .milliseconds(10))

        let second = await coordinator.register(input)
        await coordinator.accept(requestID: "req-stable", turnID: "turn-1")
        var states: [AgentInputSubmissionState] = []
        for await state in second.states { states.append(state) }

        XCTAssertEqual(states.first, .pending)
        XCTAssertEqual(states.last, .accepted(turnID: "turn-1"))
    }

    func testAcceptedSubmissionClearsOnlySnapshotContent() throws {
        let store = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("session-assets")
        let oldAsset = DraftAttachmentReference(
            id: "old",
            displayName: "old.jpg",
            resourceURI: "host://old",
            state: .ready,
            readyAsset: UserAssetRef(assetID: 1, mimeType: "image/jpeg", filename: "old.jpg")
        )
        try store.updateState(for: key) { state in
            state.composerDraft.text = "sent text"
            state.composerDraft.attachments = [oldAsset]
            state.composerDraft.revision = 3
        }
        _ = try store.markSubmissionPending(
            key: key,
            input: .text(
                "sent text",
                assets: [try XCTUnwrap(oldAsset.readyAsset)],
                requestID: "req-1"
            )
        )
        try store.updateState(for: key) { state in
            state.composerDraft.text += "\nnew draft"
            state.composerDraft.attachments.append(DraftAttachmentReference(
                id: "new",
                displayName: "new.png",
                resourceURI: "host://new"
            ))
            state.composerDraft.revision += 1
        }

        try store.acceptSubmission(key: key, requestID: "req-1")
        let draft = try XCTUnwrap(store.state(for: key)?.composerDraft)
        XCTAssertEqual(draft.text, "new draft")
        XCTAssertEqual(draft.attachments.map(\.id), ["new"])
        XCTAssertNil(draft.pendingSubmission)
    }

    func testTransientAttachmentStateNormalizesAfterDecode() throws {
        let attachment = DraftAttachmentReference(
            id: "local-1",
            displayName: "image.jpg",
            resourceURI: "host://bookmark",
            state: .uploading,
            progress: 0.5
        )
        let data = try JSONEncoder().encode(attachment)
        let restored = try JSONDecoder().decode(DraftAttachmentReference.self, from: data)

        XCTAssertEqual(restored.state, .failed)
        XCTAssertTrue(restored.failure?.retryable == true)
        XCTAssertNil(restored.progress)
    }

    func testRejectedRestoredSubmissionMakesReferencedAttachmentReadyAgain() throws {
        let store = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("session-rejected")
        let asset = UserAssetRef(
            assetID: 10001,
            sha256: String(repeating: "a", count: 64),
            mimeType: "image/jpeg",
            filename: "build-error.jpg"
        )
        try store.updateState(for: key) { state in
            state.composerDraft.attachments = [DraftAttachmentReference(
                id: "attachment-1",
                displayName: "build-error.jpg",
                resourceURI: "picker://attachment-1",
                state: .failed,
                readyAsset: asset,
                failure: DraftAttachmentFailure(message: "上次操作已中断，请重试", retryable: true)
            )]
            state.composerDraft.pendingSubmission = ComposerSubmissionSnapshot(
                requestID: "request-1",
                revision: 3,
                text: "解释错误",
                attachmentIDs: ["attachment-1"],
                assets: [asset]
            )
        }

        try store.rejectSubmission(key: key, requestID: "request-1")

        let draft = try XCTUnwrap(store.state(for: key)?.composerDraft)
        let restored = try XCTUnwrap(draft.attachments.first)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertNil(restored.failure)
        XCTAssertEqual(restored.readyAsset, asset)
        XCTAssertNil(draft.pendingSubmission)
    }

    func testPureImageTurnProjectsVisibleHistoricalPrompt() async {
        let engine = RuntimeEngine(sessionID: "session-image")
        await engine.ingest(.turnStarted(
            turnID: "turn-image",
            text: "",
            userAssets: [UserAssetRef(
                assetID: 10,
                mimeType: "image/png",
                filename: "diagram.png"
            )]
        ))
        let snapshot = await engine.currentSnapshot()

        XCTAssertEqual(snapshot.turns.first?.userPrompt?.userAssets.first?.assetID, 10)
        XCTAssertEqual(snapshot.turns.first?.userPrompt?.displayTextWithUserAssets, "[图片] diagram.png")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
    }
}
