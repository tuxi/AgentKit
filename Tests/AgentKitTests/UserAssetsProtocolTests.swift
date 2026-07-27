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
        guard case .turnStarted(let turnID, let text, let userAssets, _) = event else {
            return XCTFail("Expected turn_started")
        }
        XCTAssertEqual(turnID, "turn_user_asset_001")
        XCTAssertEqual(text, "解释这张截图里的错误")
        XCTAssertEqual(userAssets.first?.filename, "build-error.jpg")
    }

    func testTurnStartedRetainsIncomingLocalAssetsThroughTimelineProjection() async throws {
        let data = Data(
            """
            {
              "kind": "turn_started",
              "turn_id": "turn_local_asset_001",
              "text": "总结这个 PDF",
              "local_assets": [{
                "id": "31B49FA4-DA76-43D7-8C48-B7F0352D6216",
                "relative_path": "user-assets/31B49FA4-DA76-43D7-8C48-B7F0352D6216/spec.pdf",
                "filename": "spec.pdf",
                "mime_type": "application/pdf",
                "kind": "document",
                "size_bytes": 128,
                "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "transfer_policy": "local_only"
              }]
            }
            """.utf8
        )
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        XCTAssertEqual(wire.localAssets?.first?.filename, "spec.pdf")
        let event = try XCTUnwrap(AgentEvent.from(wire: wire))
        guard case .turnStarted(let turnID, let text, let userAssets, let localAssets) = event else {
            return XCTFail("Expected turn_started")
        }
        XCTAssertEqual(turnID, "turn_local_asset_001")
        XCTAssertEqual(text, "总结这个 PDF")
        XCTAssertTrue(userAssets.isEmpty)
        XCTAssertEqual(localAssets.first?.relativePath, "user-assets/31B49FA4-DA76-43D7-8C48-B7F0352D6216/spec.pdf")

        let engine = RuntimeEngine(sessionID: "session-local-history")
        await engine.ingest(event)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.turns.first?.userPrompt?.localAssets, localAssets)
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

    func testLocalAttachmentEncodesWithoutGatewayAssetsOrImageCapability() throws {
        let local = makeLocalAsset(
            id: "9B0C48E5-E73D-4C72-A79D-744653D69BE1",
            path: "user-assets/9B0C48E5-E73D-4C72-A79D-744653D69BE1/spec.pdf",
            filename: "spec.pdf",
            mimeType: "application/pdf",
            kind: "document"
        )
        let input = AgentInput.text(
            "总结这个文件",
            model: "default",
            localAssets: [local],
            requestID: "req-local-1"
        )

        XCTAssertNoThrow(try input.validateForSubmission(supportsImageInput: false))
        let data = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["assets"])
        let encoded = try XCTUnwrap(object["local_assets"] as? [[String: Any]])
        XCTAssertEqual(encoded.first?["relative_path"] as? String, local.relativePath)
        XCTAssertEqual(encoded.first?["transfer_policy"] as? String, "local_only")
        XCTAssertNil(encoded.first?["resource_uri"])
    }

    func testLocalAttachmentValidationRejectsAbsoluteTraversalAndDuplicatePath() throws {
        let absolute = makeLocalAsset(
            id: "57CC429B-A253-468C-9F31-E15EDAA499C6",
            path: "/tmp/secret.txt",
            filename: "secret.txt"
        )
        XCTAssertThrowsError(try absolute.validate()) { error in
            XCTAssertEqual(error as? LocalUserAssetValidationError, .invalidRelativePath)
        }

        let traversal = makeLocalAsset(
            id: "DA885B48-36E1-4BBF-8AD8-ED7913DBB88E",
            path: "user-assets/../secret.txt",
            filename: "secret.txt"
        )
        XCTAssertThrowsError(try traversal.validate()) { error in
            XCTAssertEqual(error as? LocalUserAssetValidationError, .invalidRelativePath)
        }

        let first = makeLocalAsset(
            id: "F0EB85E0-DB4B-42AD-B201-F3A12DD1D7BB",
            path: "user-assets/shared/file.txt",
            filename: "file.txt"
        )
        let second = makeLocalAsset(
            id: "C9E232DB-E9C2-4C3E-ADE8-E115CA925706",
            path: first.relativePath,
            filename: "file.txt"
        )
        XCTAssertThrowsError(
            try AgentInput.text("read", localAssets: [first, second])
                .validateForSubmission(supportsImageInput: false)
        ) { error in
            XCTAssertEqual(
                error as? LocalUserAssetValidationError,
                .duplicateRelativePath(first.relativePath)
            )
        }
    }

    @MainActor
    func testPickerSelectionDoesNotInvokeGatewayUploader() async throws {
        let stateStore = InMemoryConversationLocalStateStore()
        let stager = RecordingLocalAssetStager()
        let uploader = RecordingUserAssetUploader()
        let selected = DraftAttachmentReference(
            id: "46B722E2-A3C3-420B-9629-1836A79F63CA",
            displayName: "notes.pdf",
            resourceURI: "picker://notes"
        )
        let dependencies = AgentDependencies(
            client: LocalAssetsRuntimeClient(),
            localStateStore: stateStore,
            userAssetPicker: { [selected] in [selected] },
            localUserAssetStager: stager,
            userAssetUploader: uploader
        )
        let store = WorkspaceStore(dependencies: dependencies)
        XCTAssertTrue(store.canSelectUserAssets)
        store.beginDraft()
        let key = ConversationLocalStateKey.draft(try XCTUnwrap(store.draft?.id))

        await store.selectUserAssets(for: key, remainingSlots: 4)

        XCTAssertEqual(try stateStore.state(for: key)?.composerDraft.attachments, [selected])
        let uploadCount = await uploader.uploadCount
        let workspaceRoots = await stager.workspaceRoots
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(workspaceRoots, [])
    }

    func testGatewayUploadFailureKeepsStagedLocalAttachmentSendable() async throws {
        let stateStore = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("upload-failure")
        let local = makeLocalAsset(
            id: "8F53FC79-D3C6-417B-83C5-C779DB607B45",
            path: "user-assets/8F53FC79-D3C6-417B-83C5-C779DB607B45/photo.png",
            filename: "photo.png",
            mimeType: "image/png",
            kind: "image"
        )
        try stateStore.updateState(for: key) { state in
            state.composerDraft.attachments = [DraftAttachmentReference(
                id: local.id,
                displayName: local.filename,
                resourceURI: "picker://photo",
                state: .ready,
                localAsset: local
            )]
        }
        let uploader = RecordingUserAssetUploader(error: TestAssetError.uploadFailed)
        let coordinator = UserAssetDraftCoordinator(store: stateStore, uploader: uploader)

        do {
            try await coordinator.upload(id: local.id, in: key)
            XCTFail("Expected upload failure")
        } catch {}

        let attachment = try XCTUnwrap(stateStore.state(for: key)?.composerDraft.attachments.first)
        XCTAssertEqual(attachment.delivery, .localOnly)
        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.localAsset, local)
        let restoredLocalAssets = try await coordinator.localAssets(for: key)
        XCTAssertEqual(restoredLocalAssets, [local])
    }

    func testGatewayDeliveryIsExclusiveWithLocalAssets() async throws {
        let stateStore = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("gateway-exclusive")
        let local = makeLocalAsset(
            id: "35CEFB02-C573-4A31-B980-EB3254B239CD",
            path: "user-assets/35CEFB02-C573-4A31-B980-EB3254B239CD/photo.jpg",
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            kind: "image"
        )
        try stateStore.updateState(for: key) { state in
            state.composerDraft.attachments = [DraftAttachmentReference(
                id: local.id,
                displayName: local.filename,
                resourceURI: "picker://photo",
                state: .ready,
                localAsset: local
            )]
        }
        let uploader = RecordingUserAssetUploader()
        let stager = RecordingLocalAssetStager()
        let coordinator = UserAssetDraftCoordinator(
            store: stateStore,
            stager: stager,
            uploader: uploader
        )

        try await coordinator.upload(id: local.id, in: key)
        let localAssets = try await coordinator.stageLocalAssets(
            for: key,
            workspaceRoot: URL(fileURLWithPath: "/tmp/final-worktree")
        )
        let gatewayAssets = try await coordinator.readyAssets(for: key)

        XCTAssertTrue(localAssets.isEmpty)
        XCTAssertEqual(gatewayAssets.map(\.assetID), [7001])
        let workspaceRoots = await stager.workspaceRoots
        XCTAssertEqual(workspaceRoots, [])
    }

    func testLocalAttachmentSurvivesPersistenceAndReconnectReplay() async throws {
        let local = makeLocalAsset(
            id: "72051E3B-5967-45DD-82DE-E5FF4AF0D905",
            path: "user-assets/72051E3B-5967-45DD-82DE-E5FF4AF0D905/readme.txt",
            filename: "readme.txt"
        )
        let attachment = DraftAttachmentReference(
            id: local.id,
            displayName: local.filename,
            resourceURI: "picker://readme",
            state: .ready,
            localAsset: local
        )
        let restored = try JSONDecoder().decode(
            DraftAttachmentReference.self,
            from: JSONEncoder().encode(attachment)
        )
        XCTAssertEqual(restored, attachment)

        let input = AgentInput.text(
            "read",
            localAssets: [local],
            requestID: "req-local-replay"
        )
        let coordinator = AgentInputSubmissionCoordinator()
        _ = await coordinator.register(input)
        let replayable = await coordinator.replayableInputs(supportsImageInput: false)
        XCTAssertEqual(replayable.count, 1)
        XCTAssertEqual(replayable.first?.localAssets, [local])
    }

    func testRejectedLocalSubmissionRestoresAttachmentForRetry() throws {
        let stateStore = InMemoryConversationLocalStateStore()
        let key = ConversationLocalStateKey.session("local-retry")
        let local = makeLocalAsset(
            id: "18AD31D9-72DD-40F5-995F-9DAFD54A7373",
            path: "user-assets/18AD31D9-72DD-40F5-995F-9DAFD54A7373/notes.txt",
            filename: "notes.txt"
        )
        try stateStore.updateState(for: key) { state in
            state.composerDraft.attachments = [DraftAttachmentReference(
                id: local.id,
                displayName: local.filename,
                resourceURI: "picker://notes",
                state: .ready,
                localAsset: local
            )]
        }
        let input = AgentInput.text(
            "read",
            localAssets: [local],
            requestID: "req-local-retry"
        )

        let snapshot = try stateStore.markSubmissionPending(key: key, input: input)
        XCTAssertEqual(snapshot.localAssets, [local])
        XCTAssertEqual(
            try stateStore.state(for: key)?.composerDraft.attachments.first?.state,
            .sending
        )

        try stateStore.rejectSubmission(key: key, requestID: input.requestID)
        let restored = try XCTUnwrap(stateStore.state(for: key)?.composerDraft.attachments.first)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.localAsset, local)
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

    private func makeLocalAsset(
        id: String,
        path: String,
        filename: String,
        mimeType: String = "text/plain",
        kind: String = "text"
    ) -> LocalUserAssetRef {
        LocalUserAssetRef(
            id: id,
            relativePath: path,
            filename: filename,
            mimeType: mimeType,
            kind: kind,
            sizeBytes: 42,
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private enum TestAssetError: Error {
    case uploadFailed
}

private actor RecordingLocalAssetStager: LocalUserAssetStaging {
    private(set) var workspaceRoots: [String] = []

    func stage(
        attachment: DraftAttachmentReference,
        workspaceRoot: URL
    ) async throws -> LocalUserAssetRef {
        workspaceRoots.append(workspaceRoot.path)
        let id = UUID(uuidString: attachment.id)?.uuidString ?? UUID().uuidString
        let filename = attachment.displayName
        return LocalUserAssetRef(
            id: id,
            relativePath: "user-assets/\(id)/\(filename)",
            filename: filename,
            mimeType: filename.lowercased().hasSuffix(".pdf") ? "application/pdf" : "image/png",
            kind: filename.lowercased().hasSuffix(".pdf") ? "document" : "image",
            sizeBytes: 42,
            sha256: String(repeating: "b", count: 64)
        )
    }
}

private actor RecordingUserAssetUploader: UserAssetUploading {
    private(set) var uploadCount = 0
    let error: TestAssetError?

    init(error: TestAssetError? = nil) {
        self.error = error
    }

    func upload(
        attachment: DraftAttachmentReference,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UserAssetRef {
        uploadCount += 1
        if let error { throw error }
        progress(1)
        return UserAssetRef(
            assetID: 7001,
            sha256: String(repeating: "c", count: 64),
            mimeType: attachment.displayName.lowercased().hasSuffix(".png")
                ? "image/png"
                : "image/jpeg",
            filename: attachment.displayName
        )
    }

    func revalidate(_ asset: UserAssetRef) async throws -> UserAssetRef {
        asset
    }
}

private final class LocalAssetsRuntimeClient: RuntimeClient, @unchecked Sendable {
    func createConversation(workspacePath: String) async throws -> ConversationRef {
        ConversationRef(id: UUID().uuidString, workspacePath: workspacePath)
    }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef {
        ConversationRef(id: id, workspacePath: "", name: name)
    }
    func deleteConversation(id: String) async throws {}
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> {
        AsyncStream { _ in }
    }
    func send(input: AgentInput) async {}
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func disconnect() async {}
    func getConversationDetail(id: String) async throws -> ConversationDetail {
        throw TestAssetError.uploadFailed
    }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { [] }
}
