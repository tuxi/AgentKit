import XCTest
@testable import AgentKit

final class PreviewArtifactTests: XCTestCase {
    func testFixtureManifestRunnerPassesAllScenarios() throws {
        let report = try PreviewFixtureManifestRunner.run()
        XCTAssertEqual(report.scenarioCount, 16)
        XCTAssertEqual(report.passedScenarios.count, report.scenarioCount)
        XCTAssertGreaterThan(report.fileCount, 0)
    }

    func testRFC8785CanonicalVectorAndNumberFormatting() throws {
        let value = JSONValue.object([
            "numbers": .array([
                .number(333333333.33333329),
                .number(1e30),
                .number(4.50),
                .number(2e-3),
                .number(1e-27),
                .number(1e20),
                .number(1e-6),
            ]),
            "null": .null,
            "bool": .bool(true),
            "text": .string("line\n\"quoted\"\\"),
        ])

        let canonical = try PreviewRFC8785.canonicalize(value)
        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            "{\"bool\":true,\"null\":null,\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27,100000000000000000000,0.000001],\"text\":\"line\\n\\\"quoted\\\"\\\\\"}"
        )
    }

    func testRFC8785SortsObjectKeysByUTF16CodeUnits() throws {
        let value = JSONValue.object([
            "€": .string("Euro Sign"),
            "\r": .string("Carriage Return"),
            "\u{FB33}": .string("Hebrew Letter Dalet With Dagesh"),
            "1": .string("One"),
            "😀": .string("Emoji"),
            "\u{80}": .string("Control"),
        ])
        let canonical = try PreviewRFC8785.canonicalize(value)
        XCTAssertEqual(
            String(decoding: canonical, as: UTF8.self),
            "{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\u{80}\":\"Control\",\"€\":\"Euro Sign\",\"😀\":\"Emoji\",\"\u{FB33}\":\"Hebrew Letter Dalet With Dagesh\"}"
        )
    }

    func testUnknownArtifactVersionDegradesAsPreviewEvent() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(var artifact) = raw else { return XCTFail("fixture artifact is not an object") }
        artifact["schema_version"] = .string("preview.artifact.v2")
        artifact.removeValue(forKey: "revision_sha256")
        artifact["revision_sha256"] = .string(try PreviewRFC8785.sha256(.object(artifact)))
        let event = JSONValue.object([
            "kind": .string("preview_artifact"),
            "seq": .integer(1),
            "session_id": .string("session_fixture"),
            "turn_id": .string("turn_fixture"),
            "artifact": .object(artifact),
        ])
        let eventData = try JSONEncoder().encode(event)
        let wire = try JSONDecoder().decode(WireFrame.self, from: eventData)
        guard case .previewArtifact(let decoded) = AgentEvent.from(wire: wire) else {
            return XCTFail("unknown version event was dropped")
        }
        XCTAssertNil(decoded.artifact)
        XCTAssertEqual(decoded.error?.code, "preview_invalid_artifact")
    }

    func testWireFrameDecodesPreviewDraftsWithoutFailingContainingResult() throws {
        let data = Data("""
        {
          "type": "agent_input",
          "kind": "tool_result",
          "tool_result": {
            "tool_use_id": "call_1",
            "content": "done",
            "previews": [
              {
                "artifact_key": "key",
                "kind": "interactive_html",
                "title": "Preview",
                "viewer_html": "<div/>",
                "assets": [{"asset_id":"asset_1","role":"fallback","mime_type":"image/png","alt":"fallback"}],
                "fallback": {"asset_id":"asset_1","text":"fallback"}
              },
              {"artifact_key": "bad"}
            ]
          }
        }
        """.utf8)
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        let previews = try XCTUnwrap(wire.toolResult?.previews)
        XCTAssertEqual(previews.count, 2)
        XCTAssertNoThrow(try PreviewArtifactDraft.decode(previews[0]))
        XCTAssertThrowsError(try PreviewArtifactDraft.decode(previews[1]))
    }

    func testArtifactDecodeValidatesJCSRevisionDigest() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        let artifact = try PreviewArtifact.decode(data: data)
        XCTAssertEqual(artifact.artifactID, "preview_fixture_interactive")
        XCTAssertEqual(artifact.revision, 1)
        XCTAssertEqual(artifact.status, .ready)
        XCTAssertEqual(artifact.kind, .interactiveHTML)
        XCTAssertEqual(artifact.fallbackAsset?.assetID, "asset_fixture_fallback")
        XCTAssertTrue(artifact.revisionSHA256.hasPrefix("sha256:"))
    }

    func testArtifactDecodeRejectsDigestMutation() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("ready-interactive.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var changed = object
        changed["title"] = "Tampered"
        let changedData = try JSONSerialization.data(withJSONObject: changed)
        XCTAssertThrowsError(try PreviewArtifact.decode(data: changedData)) { error in
            XCTAssertEqual((error as? PreviewArtifactError)?.code, "preview_invalid_artifact")
        }
    }

    func testPreviewArtifactTypeIsNotAcceptedAsRawWireKind() throws {
        let data = Data("""
        {"type":"preview_artifact","seq":1,"session_id":"session","turn_id":"turn","artifact":{}}
        """.utf8)
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        XCTAssertNil(AgentEvent.from(wire: wire))
    }

    func testPreviewEventDecodeAndStoreRevisionSemantics() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let first = try loadEvent("event-revision-1.json", root: root)
        let duplicate = try loadEvent("event-duplicate.json", root: root)
        let conflict = try loadEvent("event-revision-conflict.json", root: root)
        let second = try loadEvent("event-revision-2.json", root: root)

        XCTAssertTrue(first.isValid)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.artifact?.artifactID, "preview_fixture_interactive")

        var store = PreviewArtifactStore()
        guard case .inserted = store.merge(first) else { return XCTFail("first revision was not inserted") }
        guard case .duplicate = store.merge(duplicate) else { return XCTFail("duplicate was not idempotent") }
        guard case .conflict = store.merge(conflict) else { return XCTFail("conflict was not detected") }
        XCTAssertEqual(store.artifacts.first?.revision, 1)
        guard case .replaced = store.merge(second) else { return XCTFail("higher revision did not replace") }
        XCTAssertEqual(store.artifacts.first?.revision, 2)
        XCTAssertEqual(store.revisionHistory(sessionID: "session_fixture", artifactID: "preview_fixture_interactive").count, 2)
        guard case .stale = store.merge(first) else { return XCTFail("stale revision was accepted") }
    }

    func testPresentationPrecedenceAndCapabilityMatrix() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let all = PreviewCapabilityNegotiation(
            hello: PreviewCapability.allCases.map(\.rawValue),
            runtime: PreviewCapability.allCases.map(\.rawValue),
            client: .previewClient
        )
        let interactive = try loadArtifact("ready-interactive.json", root: root)
        XCTAssertEqual(interactive.presentationState(at: Date(timeIntervalSince1970: 0), capabilities: all), .interactiveReady)

        let staticOnly = PreviewCapabilityNegotiation(
            hello: ["preview_contract_v1", "preview_static_asset_v1"],
            runtime: ["preview_contract_v1", "preview_static_asset_v1"],
            client: .previewClient
        )
        XCTAssertEqual(interactive.presentationState(at: Date(timeIntervalSince1970: 0), capabilities: staticOnly), .staticFallback)

        let expired = try loadArtifact("expired-replay.json", root: root)
        let evaluation = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z"))
        XCTAssertEqual(expired.presentationState(at: evaluation, capabilities: all), .expired)

        let failedWithFallback = try loadArtifact("failed-with-fallback.json", root: root)
        XCTAssertEqual(failedWithFallback.presentationState(at: evaluation, capabilities: all), .staticFallback)
        let failedWithoutFallback = try loadArtifact("failed-without-fallback.json", root: root)
        XCTAssertEqual(failedWithoutFallback.presentationState(at: evaluation, capabilities: all), .unavailable)
        let unavailableWithFallback = try loadArtifact("unavailable-with-fallback.json", root: root)
        XCTAssertEqual(unavailableWithFallback.presentationState(at: evaluation, capabilities: all), .staticFallback)
    }

    func testCapabilityMatrixFixture() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("capability-matrix.json"))
        let matrix = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(matrix["cases"].array?.count, 8)
        let invalid = PreviewCapabilityNegotiation(
            hello: ["preview_contract_v1", "preview_interactive_html_v1"],
            runtime: ["preview_contract_v1", "preview_interactive_html_v1"],
            client: ["preview_contract_v1", "preview_static_asset_v1"]
        )
        XCTAssertTrue(invalid.runtimeAdvertisementInvalid)
        XCTAssertTrue(invalid.staticAvailable)
        XCTAssertFalse(invalid.interactiveAvailable)
    }

    func testPreviewCapabilityFlagsMapHelloAndRuntimeSnapshot() {
        let names = PreviewCapability.allCases.map(\.rawValue)
        let hello = CodeAgentSessionChannel.flags(from: names)
        XCTAssertTrue(hello.contains(.previewContractV1))
        XCTAssertTrue(hello.contains(.previewInteractiveHTMLV1))
        XCTAssertTrue(hello.contains(.previewStaticAssetV1))
        XCTAssertTrue(hello.contains(.previewReplayV1))

        let snapshot = RuntimeCapabilitySnapshot(capabilities: Dictionary(uniqueKeysWithValues: names.map { ($0, true) }))
        XCTAssertTrue(snapshot.flags.contains(.previewContractV1))
        XCTAssertTrue(snapshot.flags.contains(.previewInteractiveHTMLV1))
        XCTAssertEqual(snapshot.enabledCapabilities, Set(names))

        let mismatch = PreviewCapabilityNegotiation(
            hello: names,
            runtime: ["preview_contract_v1", "preview_static_asset_v1"],
            client: .previewClient
        )
        XCTAssertTrue(mismatch.helloRuntimeMismatch.contains(.interactiveHTML))
        XCTAssertTrue(mismatch.staticAvailable)
        XCTAssertFalse(mismatch.interactiveAvailable)
    }

    func testToolResultPreviewEncodingAndDraftValidation() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("producer-wire.json"))
        let producer = try JSONDecoder().decode(JSONValue.self, from: data)
        let previewValue = try XCTUnwrap(producer["server_tool"]["previews"].array?.first)
        let draft = try PreviewArtifactDraft.decode(previewValue)

        let input = AgentInput.toolResult(ToolResultContent(
            toolUseID: "call_fixture",
            content: "Preview generated",
            previews: [draft]
        ))
        try input.validateForSubmission(supportsImageInput: false)
        let encoded = try JSONEncoder().encode(OutgoingAgentInput.from(input: input))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let toolResult = try XCTUnwrap(object["tool_result"] as? [String: Any])
        let previews = try XCTUnwrap(toolResult["previews"] as? [[String: Any]])
        let encodedDraft = try XCTUnwrap(previews.first)
        XCTAssertEqual(encodedDraft["artifact_key"] as? String, "ui-adaptation:dreamlog-duo-home")
        XCTAssertEqual(encodedDraft["viewer_html"] as? String, "<div>Preview</div>")
        let fallback = try XCTUnwrap(encodedDraft["fallback"] as? [String: Any])
        XCTAssertEqual(fallback["asset_id"] as? String, "asset_fixture_fallback")
    }

    func testDraftRejectsForgedProducerIdentityAndUnknownFields() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("negative/forged-producer-identity.json"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertThrowsError(try PreviewArtifactDraft.decode(fixture["preview"])) { error in
            XCTAssertEqual((error as? PreviewArtifactError)?.code, "preview_invalid_artifact")
        }
    }

    func testRegisterToolsEncodesVisibilityAndExecutor() throws {
        let registrations = [
            ClientToolRegistration(
                name: "ios_preview_capture",
                description: "Capture a native preview.",
                inputSchema: .object(["type": .string("object")]),
                modelVisibility: .hidden,
                executor: .client
            ),
            ClientToolRegistration(
                name: "ui_preview",
                description: "Produce a preview artifact.",
                inputSchema: .object(["type": .string("object")]),
                modelVisibility: .direct,
                executor: .flex
            ),
        ]
        let encoded = try JSONEncoder().encode(OutgoingRegisterTools(tools: registrations))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["model_visibility"] as? String, "hidden")
        XCTAssertEqual(tools[0]["executor"] as? String, "client")
        XCTAssertEqual(tools[1]["model_visibility"] as? String, "direct")
        XCTAssertEqual(tools[1]["executor"] as? String, "flex")

        let fixtureRoot = try PreviewFixtureManifestRunner.fixtureRoot()
        let fixtureData = try Data(contentsOf: fixtureRoot.appendingPathComponent("tool-bindings.json"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: fixtureData)
        let encodedValue = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(encodedValue, fixture["register_tools"])
    }

    func testFlexExecutorIsNeverResolvedAsClient() {
        let call = ToolCall(callID: "call_1", toolName: "ui_preview", toolArgs: nil, executor: .flex)
        XCTAssertNil(call.resolvedExecutor)
        XCTAssertFalse(call.isClientExecutable)
        let client = ToolCall(callID: "call_2", toolName: "ios_preview_capture", toolArgs: nil, executor: .client)
        XCTAssertEqual(client.resolvedExecutor, .client)
        XCTAssertTrue(client.isClientExecutable)
    }

    func testPreviewHTTPErrorEnvelopeParsing() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("negative/viewer-error-response.json"))
        let error = try XCTUnwrap(PreviewHTTPError.decode(data: data, httpStatus: 422))
        XCTAssertEqual(error.traceID, "trace_fixture")
        XCTAssertEqual(error.httpStatus, 422)
        XCTAssertEqual(error.code, 42200)
        XCTAssertEqual(error.error.code, "preview_digest_mismatch")
        XCTAssertEqual(error.error.message, "Viewer digest did not match.")
        XCTAssertFalse(error.error.retryable)
    }

    func testResolverResourcesValidateBytesAndDigest() throws {
        let root = try PreviewFixtureManifestRunner.fixtureRoot()
        let viewerData = try Data(contentsOf: root.appendingPathComponent("viewer.html"))
        let assetData = try Data(contentsOf: root.appendingPathComponent("assets/fallback.png"))
        let artifact = try loadArtifact("ready-interactive.json", root: root)
        let viewer = PreviewViewerResource(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            data: viewerData,
            statusCode: 200,
            mimeType: "text/html; charset=utf-8",
            sizeBytes: viewerData.count,
            sha256: PreviewRFC8785.sha256(data: viewerData)
        )
        try viewer.validate(against: artifact)

        let asset = PreviewAssetResource(
            sessionID: artifact.sessionID,
            artifactID: artifact.artifactID,
            revision: artifact.revision,
            assetID: "asset_fixture_fallback",
            data: assetData,
            statusCode: 200,
            mimeType: "image/png",
            sizeBytes: assetData.count,
            sha256: PreviewRFC8785.sha256(data: assetData)
        )
        try asset.validate(against: artifact)

        let badViewer = PreviewViewerResource(
            sessionID: viewer.sessionID,
            artifactID: viewer.artifactID,
            revision: viewer.revision,
            data: viewerData,
            statusCode: 200,
            mimeType: viewer.mimeType,
            sizeBytes: viewer.sizeBytes,
            sha256: "sha256:" + String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try badViewer.validate(against: artifact)) { error in
            XCTAssertEqual((error as? PreviewResourceError)?.code, "preview_digest_mismatch")
        }
    }

    private func loadArtifact(_ file: String, root: URL) throws -> PreviewArtifact {
        try PreviewArtifact.decode(data: Data(contentsOf: root.appendingPathComponent(file)))
    }

    private func loadEvent(_ file: String, root: URL) throws -> PreviewArtifactEvent {
        let data = try Data(contentsOf: root.appendingPathComponent(file))
        let wire = try JSONDecoder().decode(WireFrame.self, from: data)
        guard case .previewArtifact(let event) = AgentEvent.from(wire: wire) else {
            throw NSError(domain: "PreviewArtifactTests", code: 1)
        }
        return event
    }
}
