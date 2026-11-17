import Foundation
import XCTest
#if os(macOS)
import SwiftUI
import AppKit
#endif
@testable import AgentKit

private final class RailHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor RailEndpoint {
    var url = URL(string: "https://runtime.example")!
    func get() -> URL { url }
    func set(_ value: String) { url = URL(string: value)! }
}

private struct FixtureEnvelope: Decodable { let data: SessionRailSnapshot }
final class SessionRailTests: XCTestCase {
    override func tearDown() { RailHTTPProtocol.handler = nil; super.tearDown() }
    private func client(environment: RuntimeEnvironment = .init(host: "localhost", port: 1234), credentials: MemoryCredentialStore = .init()) -> RuntimeHTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RailHTTPProtocol.self]
        return .init(environment: environment, session: URLSession(configuration: config), credentialStore: credentials, credentialTarget: .runtimeAccess("rail-fixture"))
    }
    static func root(conversation: String = "session", badOutputs: Bool = false) -> Data {
        let outputs = badOutputs ? #"{"state":"ready","data":{"total_count":"wrong"}}"# : #"{"state":"empty","data":{"scope":"conversation_recorded_outputs","coverage":"recorded_evidence","revision":"outputs-1","total_count":0,"items":[]}}"#
        return Data("""
        {"code":0,"msg":"ok","data":{"schema":"session-rail/v1","server_id":"server","runtime_instance_id":"instance","conversation_id":"\(conversation)","workspace_id":"workspace","snapshot_id":"root-1","generated_at":"2026-11-15T12:00:00Z","sections":{
        "environment":{"state":"ready","data":{"runtime":{"server_id":"server","display_name":"Local","runtime_version":"1.0","runtime_profile":"desktop"},"workspace":null,"execution_policy":"workspace","needs_rebind":false}},
        "context":{"state":"unavailable","code":"not_measured","data":null},
        "connectors":{"state":"ready","data":{"state":"ready","diagnostics":[],"client_capabilities_state":"unavailable","items":[{"connector_id":"mcp:server/a","kind":"mcp","display_name":"MCP A","source":"workspace","status":"unknown","health":"not_probed","available_tool_count":null,"registered_tool_count":0,"tools":[]}]}},
        "outputs":\(outputs),
        "changes":{"state":"ready","data":{"snapshot_id":"changes-1","observed_at":"2026-11-15T12:00:00Z","baseline":"HEAD","head":{"kind":"unknown"},"is_git_repository":false,"file_count":0,"added_lines":0,"removed_lines":0,"uncounted_files":0,"files":[]}},
        "background_tasks":{"state":"ready","data":{"scope":"conversation_recorded_and_live_jobs","total_count":0,"active_count":null,"stopping_count":null,"terminal_count":0,"unknown_count":0,"items":[]}}
        }}}
        """.utf8)
    }
    private func decode(_ data: Data) throws -> SessionRailSnapshot {
        try JSONDecoder().decode(FixtureEnvelope.self, from: data).data
    }
    func testActualGoRouteResponseDecodesWithoutLosingContext() throws {
        let value = try decode(Data(#"{"trace_id":"78b0611f-da69-468d-ac3c-717e8bfa4841","code":0,"msg":"success","data":{"schema":"session-rail/v1","server_id":"fixture","runtime_instance_id":"de9e899c-e18d-4df5-96d2-4dd99e4688a8","conversation_id":"sess_1","workspace_id":"9cdaa1d9655ed30b957e11c2a374a424","snapshot_id":"b4ad55919c7ab99eddf130119c57c6d6","generated_at":"2026-11-15T13:30:20.640966Z","sections":{"background_tasks":{"state":"ready","revision":"3c00f6c7fcb6be3b5932314f1a039532","observed_at":"2026-11-15T13:30:20.640966Z","data":{"scope":"conversation_recorded_and_live_jobs","total_count":0,"active_count":null,"stopping_count":null,"terminal_count":0,"unknown_count":0,"items":[]}},"changes":{"state":"empty","revision":"43f039adcee6b6ede1e86c48fe197981","observed_at":"2026-11-15T13:30:20.661266Z","data":{"observed_at":"2026-11-15T13:30:20.661266Z","snapshot_id":"43f039adcee6b6ede1e86c48fe197981","baseline":"HEAD","head":{"kind":"not_git","name":null},"is_git_repository":false,"file_count":0,"added_lines":0,"removed_lines":0,"uncounted_files":0,"files":[]}},"connectors":{"state":"unavailable","code":"connector_inventory_unavailable","data":null},"context":{"state":"ready","revision":"49dc740ac8c50d06975e2ac9c6f3a6eb","observed_at":"2026-11-15T13:30:20.640966Z","data":{"snapshot":{"model":{"output_token_budget":16000,"input_token_budget":105600,"name":"","reasoning_effort":"","context_window":128000,"compact_threshold":96000,"compact_ratio":0.75},"current":{"prompt_tokens":0,"usage_pct":0,"threshold_pct":75},"compaction":{"total_count":0,"total_saved_tokens":0},"structure":{"message_count":0,"estimated_tokens":0,"has_summary":false}},"measurement_state":"unavailable","prompt_tokens":null,"measured_at":null,"breakdown_state":"unavailable","window_source":"fallback"}},"environment":{"state":"ready","revision":"079d91127684b4b7610a0bff58c94d19","observed_at":"2026-11-15T13:30:20.661266Z","data":{"head":{"kind":"not_git","name":null},"runtime":{"schema":"","server_id":"fixture","display_name":"Local runtime","product":"","runtime_version":"development","agent_wire_protocol":{"major":0,"revision":""},"runtime_profile":"desktop"},"workspace":{"id":"001-local","name":"001","root_path":"/tmp/session-rail-fixture","runtime_cwd":"/var/folders/p2/h8cppqy94j5f2q9xq6v8z7300000gp/T/TestDumpSessionRailClientFixture3969394580/001","display_path":"001","kind":"local"},"execution_policy":"shared_workspace","needs_rebind":false}},"outputs":{"state":"unavailable","code":"output_manifest_pending","data":null}}}}"#.utf8))
        XCTAssertTrue(value.sections.context.isUsable)
        XCTAssertEqual(value.sections.context.data?.snapshot.model.contextWindow, 128000)
        XCTAssertTrue(value.sections.environment.isUsable)
        XCTAssertTrue(value.sections.changes.isUsable)
        XCTAssertTrue(value.sections.backgroundTasks.isUsable)
    }
    func testSixGroupsPreserveUnknownCountsAndMissingMeasurements() throws {
        let root = try decode(Self.root())
        XCTAssertTrue(root.sections.environment.isUsable)
        XCTAssertNil(root.sections.context.data)
        XCTAssertEqual(root.sections.context.state, "unavailable")
        let connector = try XCTUnwrap(root.sections.connectors.data?.items.first)
        XCTAssertNil(connector.availableToolCount)
        XCTAssertEqual(connector.registeredToolCount, 0)
        XCTAssertTrue(root.sections.outputs.isUsable)
        XCTAssertEqual(root.sections.outputs.data?.totalCount, 0)
        XCTAssertEqual(root.sections.changes.data?.isGitRepository, false)
        XCTAssertNil(root.sections.backgroundTasks.data?.activeCount)
    }
    func testMalformedSectionDoesNotDiscardOtherGroups() throws {
        let root = try decode(Self.root(badOutputs: true))
        XCTAssertEqual(root.sections.outputs.state, "error")
        XCTAssertEqual(root.sections.outputs.code, "invalid_section_payload")
        XCTAssertFalse(root.sections.outputs.isUsable)
        XCTAssertTrue(root.sections.environment.isUsable)
        XCTAssertTrue(root.sections.backgroundTasks.isUsable)
        let unknown = try JSONDecoder().decode(SessionRailSection<SessionRailJobs>.self, from: Data(#"{"state":"future_state","data":{"scope":"jobs","total_count":0,"active_count":null,"stopping_count":null,"terminal_count":0,"unknown_count":0,"items":[]}}"#.utf8))
        XCTAssertFalse(unknown.isUsable)
    }
    func testRootUsesExistingAuthAndConversationScope() async throws {
        let credentials = MemoryCredentialStore()
        try await credentials.set(.init(kind: .bearer, secret: "fixture-token"), for: .runtimeAccess("rail-fixture"))
        RailHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/conversations/session/session-rail")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Self.root())
        }
        let http = client(credentials: credentials)
        let value = try await http.sessionRail(scope: .init(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity()))
        XCTAssertEqual(value.workspaceID, "workspace")
        RailHTTPProtocol.handler = { _ in (200, Self.root(conversation: "other")) }
        do { _ = try await http.sessionRail(scope: .init(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity())); XCTFail("wrong conversation accepted") } catch {}
    }
    func testDynamicIdentifierAndSnapshotQueryStaySeparate() async throws {
        RailHTTPProtocol.handler = { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/v1/conversations/session/context/sources/source%2Fa%3F%23/content")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "snapshot_id", value: "snap&another=1")])
            return (410, Data(#"{"code":1,"msg":"evicted"}"#.utf8))
        }
        let http = client()
        do { _ = try await http.sessionRailSource(scope: .init(conversationID: "session", runtimeIdentity: http.backgroundJobRuntimeIdentity()), snapshotID: "snap&another=1", sourceID: "source/a?#"); XCTFail("expired snapshot accepted") }
        catch RuntimeHTTPError.unexpectedStatus(let status, _) { XCTAssertEqual(status, 410) }
    }
    func testRuntimeSwitchRejectsOldScopeBeforeDispatchAndAfterResponse() async throws {
        let endpoint = RailEndpoint(); let http = client(environment: .init(originProvider: { await endpoint.get() }))
        let scope = SessionRailScope(conversationID: "session", runtimeIdentity: try await http.backgroundJobRuntimeIdentity())
        await endpoint.set("https://new-runtime.example")
        RailHTTPProtocol.handler = { _ in XCTFail("old scope dispatched to new runtime"); return (200, Self.root()) }
        do { _ = try await http.sessionRail(scope: scope); XCTFail("switched scope accepted") } catch {}
        await endpoint.set("https://runtime.example")
        // A switch after dispatch must be caught before decoding or presenting data.
        RailHTTPProtocol.handler = { _ in
            let changed = DispatchSemaphore(value: 0)
            Task { await endpoint.set("https://new-runtime.example"); changed.signal() }
            changed.wait()
            return (200, Self.root())
        }
        do { _ = try await http.sessionRail(scope: scope); XCTFail("late response accepted") } catch {}
    }
    @MainActor func testSharedPresentationKeepsFoldStateAndAvoidsDuplicateRoutes() {
        let preferences = UserDefaults(suiteName: "SessionRailTests.\(UUID())")!
        let client = DefaultAgentClient(transport: CodeAgentTransport(environment: .init(host: "localhost", port: 1234)))
        let model = SessionRailModel(client: client, preferences: preferences)
        XCTAssertFalse(model.isExpanded("connectors")); XCTAssertTrue(model.isExpanded("context"))
        model.setExpanded(false, for: "context")
        XCTAssertFalse(SessionRailModel(client: client, preferences: preferences).isExpanded("context"))
        model.navigate(.context); model.navigate(.context)
        XCTAssertEqual(model.path, [.context])
        model.navigate(.outputs); model.back(); XCTAssertEqual(model.route, .context)
        XCTAssertFalse(model.hasTaskSurface(for: "session"))
    }
}

private actor RailReplyGate {
    var compactionCalls = 0
    func compact() throws -> ConversationCompactionResult {
        compactionCalls += 1
        throw RuntimeHTTPError.unexpectedStatus(409, body: "busy")
    }
    func compactCount() -> Int { compactionCalls }

    var pending: [String: CheckedContinuation<SessionRailSnapshot, Error>] = [:]
    func read(_ id: String) async throws -> SessionRailSnapshot { try await withCheckedThrowingContinuation { pending[id] = $0 } }
    func has(_ id: String) -> Bool { pending[id] != nil }
    func reply(_ id: String, _ value: SessionRailSnapshot) { pending.removeValue(forKey: id)?.resume(returning: value) }
    func fail(_ id: String, _ error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private var origin = "fixture"
    func identity() -> String { origin }
    func setIdentity(_ value: String) { origin = value }
}
private class RailModelClient: RuntimeClient, @unchecked Sendable {
    let gate = RailReplyGate()
    func backgroundJobRuntimeIdentity() async throws -> String { await gate.identity() }
    func sessionRail(scope: SessionRailScope) async throws -> SessionRailSnapshot { try await gate.read(scope.conversationID) }
    func compactSessionRailContext(scope: SessionRailScope) async throws -> ConversationCompactionResult { try await gate.compact() }
    func createConversation(workspacePath: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func listConversations() async throws -> [ConversationRef] { [] }
    func renameConversation(id: String, name: String) async throws -> ConversationRef { throw RuntimeHTTPError.unsupported }
    func deleteConversation(id: String) async throws {}
    func connect(conversationID: String, since: Int) async throws -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func send(input: AgentInput) async {}
    func registerTools(_ tools: [ClientToolInfo]) async {}
    func sendApproval(id: String, approved: Bool) async {}
    func sendApproval(id: String, decision: String, scope: String?) async {}
    func sendPlanApproval(id: String, approved: Bool) async {}
    func sendAskUserResponse(id: String, selected: [String], notes: String?) async {}
    func cancelTurn() async {}
    func disconnect() async {}
    func getConversationDetail(id: String) async throws -> ConversationDetail { throw RuntimeHTTPError.unsupported }
    func getMessages(conversationID: String) async throws -> [Message] { [] }
    func getEvents(conversationID: String) async throws -> [AgentEvent] { [] }
}

extension SessionRailTests {
    @MainActor func testLateOldConversationCannotReplaceNewSnapshot() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client, preferences: UserDefaults(suiteName: "RailRace.\(UUID())")!)
        let first = Task { await model.run(conversationID: "A", isBusy: { false }) }
        for _ in 0..<1000 { if await client.gate.has("A") { break }; try await Task.sleep(for: .milliseconds(1)) }
        let waitingA = await client.gate.has("A"); XCTAssertTrue(waitingA)
        first.cancel()
        let second = Task { await model.run(conversationID: "B", isBusy: { false }) }
        for _ in 0..<1000 { if await client.gate.has("B") { break }; try await Task.sleep(for: .milliseconds(1)) }
        let waitingB = await client.gate.has("B"); XCTAssertTrue(waitingB)
        await client.gate.reply("B", try decode(Self.root(conversation: "B")))
        for _ in 0..<1000 { if model.snapshot != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        await client.gate.reply("A", try decode(Self.root(conversation: "A")))
        await first.value
        XCTAssertEqual(model.conversationID, "B"); XCTAssertEqual(model.snapshot?.conversationID, "B")
        XCTAssertTrue(model.hasTaskSurface(for: "B")); XCTAssertFalse(model.hasTaskSurface(for: "A"))
        second.cancel(); await second.value
    }
}

extension SessionRailTests {
    func testContextCompactionUsesPinnedPostAndPreservesBusyConflict() async throws {
        let endpoint = RailEndpoint()
        let http = client(environment: .init(originProvider: { await endpoint.get() }))
        let scope = SessionRailScope(conversationID: "session", runtimeIdentity: try await http.backgroundJobRuntimeIdentity())
        RailHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/conversations/session/compact")
            XCTAssertEqual(request.timeoutInterval, 300)
            return (409, Data(#"{"code":1,"msg":"busy"}"#.utf8))
        }
        do { _ = try await http.compactSessionRailContext(scope: scope); XCTFail("busy was accepted") }
        catch RuntimeHTTPError.unexpectedStatus(let code, _) { XCTAssertEqual(code, 409) }
        await endpoint.set("https://other-runtime.example")
        RailHTTPProtocol.handler = { _ in XCTFail("compaction crossed runtime origins"); return (200, Self.root()) }
        do { _ = try await http.compactSessionRailContext(scope: scope); XCTFail("stale origin was accepted") } catch {}
    }
    @MainActor func testCompactionLockIsPerConversationAndIdempotent() {
        let model = SessionRailModel(client: RailModelClient(), preferences: UserDefaults(suiteName: "RailLock.\(UUID())")!)
        XCTAssertTrue(model.beginCompaction("A"))
        XCTAssertFalse(model.beginCompaction("A"))
        XCTAssertTrue(model.isCompacting("A")); XCTAssertFalse(model.isCompacting("B"))
        model.endCompaction("A"); XCTAssertTrue(model.beginCompaction("A"))
        model.endCompaction("A"); XCTAssertFalse(model.isCompacting("A"))
    }
    func testJobDurationStopsAtTerminalAndDoesNotInventUnknownDuration() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SessionRailJobPresentation.elapsed(status: .running, recorded: 4000, startedAt: "1970-01-01T00:15:00Z", now: now), 100)
        XCTAssertEqual(SessionRailJobPresentation.elapsed(status: .exited, recorded: 4200, startedAt: "1970-01-01T00:15:00Z", now: now), 4.2)
        XCTAssertEqual(SessionRailJobPresentation.elapsed(status: .running, recorded: 4000, startedAt: "1970-01-01T00:20:00Z", now: now), 4)
        XCTAssertNil(SessionRailJobPresentation.elapsed(status: .unknown, recorded: nil, startedAt: nil, now: now))
        XCTAssertEqual(SessionRailJobPresentation.format(3661), "1:01:01")
    }
    @MainActor func testRetiredTrajectoryDoesNotSerializeDuplicateInvocationBodies() throws {
        let turn = ConversationTurn(id: "turn", userPrompt: nil, blocks: [], footer: nil, isLive: false,
                                    invocations: [ModelInvocation(id: "inv", index: 1, thinkingText: "legacy-only-thinking")])
        let document = ConversationWebDocumentBuilder.build(snapshot: RuntimeSnapshot(timeline: [], turns: [turn], generation: 1), conversationID: "session", revision: 1)
        let encoded = try JSONEncoder().encode(document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(json["turns"] as? [[String: Any]])
        XCTAssertNil(rows.first?["invocations"]); XCTAssertNil(rows.first?["trajectoryActionID"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("legacy-only-thinking"))
    }
}

private actor RailSkillsFixture {
    var calls = 0
    var wrongOwner = false
    func count() -> Int { calls }
    func setWrongOwner() { wrongOwner = true }
    func read(_ id: String?) -> RuntimeSkillInventory {
        calls += 1
        return .init(scope: .init(sessionID: wrongOwner ? "another-session" : id,
                                  workspaceID: "ws_inventory_namespace", resolved: true))
    }
}
private final class RailSkillClient: RailModelClient, SkillPluginManaging, @unchecked Sendable {
    let skills = RailSkillsFixture()
    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot { .init(capabilities: [:]) }
    func skillInventory(sessionID: String?) async throws -> RuntimeSkillInventory { await skills.read(sessionID) }
    func pluginInventory() async throws -> RuntimePluginInventory { throw RuntimeHTTPError.unsupported }
    func installLocalPlugin(source: String, confirmed: Bool) async throws -> RuntimePluginMutation { throw RuntimeHTTPError.unsupported }
    func setPluginEnabled(name: String, enabled: Bool) async throws -> RuntimePluginMutation { throw RuntimeHTTPError.unsupported }
    func uninstallPlugin(name: String) async throws -> RuntimePluginMutation { throw RuntimeHTTPError.unsupported }
}
extension SessionRailTests {
    @MainActor private func selectedRail(_ client: RailModelClient) async throws -> (SessionRailModel, Task<Void, Never>) {
        let model = SessionRailModel(client: client, preferences: UserDefaults(suiteName: "RailActions.\(UUID())")!)
        let running = Task { await model.run(conversationID: "session", isBusy: { false }) }
        for _ in 0..<1000 { if await client.gate.has("session") { break }; try await Task.sleep(for: .milliseconds(1)) }
        await client.gate.reply("session", try decode(Self.root()))
        for _ in 0..<1000 { if model.snapshot != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(model.snapshot)
        return (model, running)
    }
    @MainActor func testAvailableSkillsLoadExplicitlyWithIndependentWorkspaceIDNamespace() async throws {
        let client = RailSkillClient()
        let (model, running) = try await selectedRail(client)
        let before = await client.skills.count(); XCTAssertEqual(before, 0)
        model.navigate(.composition(snapshotID: "request", category: "skills"))
        await model.loadSkillInventory()
        XCTAssertEqual(model.skillInventory?.scope.sessionID, "session")
        XCTAssertNil(model.skillInventoryError)
        await client.skills.setWrongOwner(); await model.loadSkillInventory()
        XCTAssertNotNil(model.skillInventoryError)
        XCTAssertEqual(model.skillInventory?.scope.sessionID, "session", "Wrong-owner data must not replace the valid inventory")
        running.cancel(); await running.value
    }
    @MainActor func testCompactionNeverDispatchesWhileBusyOrAlreadyCompacting() async throws {
        let client = RailModelClient()
        let (model, running) = try await selectedRail(client)
        await model.compactContext(isBusy: { true })
        XCTAssertTrue(model.beginCompaction("session"))
        await model.compactContext(isBusy: { false })
        var count = await client.gate.compactCount(); XCTAssertEqual(count, 0)
        model.endCompaction("session")
        await model.compactContext(isBusy: { false })
        count = await client.gate.compactCount(); XCTAssertEqual(count, 1)
        XCTAssertFalse(model.isCompacting("session"))
        XCTAssertEqual(model.compactionMessage, "会话正在运行，空闲后才能压缩。")
        running.cancel(); await running.value
    }
}

extension SessionRailTests {
    func testAuthoritativeTerminalSnapshotCannotBeReplacedByOlderRegistryState() {
        XCTAssertEqual(SessionRailJobPresentation.status(snapshot: .canceled, registry: .running), .canceled)
        XCTAssertEqual(SessionRailJobPresentation.status(snapshot: .running, registry: .exited), .exited)
        XCTAssertEqual(SessionRailJobPresentation.status(snapshot: .unknown, registry: nil), .unknown)
    }
}


extension SessionRailTests {
    @MainActor private func waitForRailRequest(_ id: String, client: RailModelClient) async throws {
        for _ in 0..<1000 {
            if await client.gate.has(id) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Session rail did not request \(id)")
        throw URLError(.timedOut)
    }

    @MainActor private func loadRail(_ id: String, model: SessionRailModel, client: RailModelClient,
                                    instance: String = "instance") async throws {
        let task = Task { await model.run(conversationID: id, isBusy: { false }) }
        try await waitForRailRequest(id, client: client)
        let data = String(decoding: Self.root(conversation: id), as: UTF8.self)
            .replacingOccurrences(of: "\"runtime_instance_id\":\"instance\"", with: "\"runtime_instance_id\":\"\(instance)\"")
        await client.gate.reply(id, try decode(Data(data.utf8)))
        for _ in 0..<1000 {
            if !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.snapshot?.conversationID, id)
        XCTAssertFalse(model.isRefreshing)
        task.cancel(); await task.value
    }

    @MainActor func testReturningToConversationShowsCachedRootWhileRefreshing() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        try await loadRail("A", model: model, client: client)
        model.navigate(.context)
        try await loadRail("B", model: model, client: client)
        let task = Task { await model.run(conversationID: "A", isBusy: { false }) }
        try await waitForRailRequest("A", client: client)
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        XCTAssertTrue(model.isRefreshing)
        XCTAssertNil(model.route)
        await client.gate.fail("A", URLError(.notConnectedToInternet))
        for _ in 0..<1000 {
            if model.error != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        task.cancel(); await task.value
    }

    @MainActor func testReopeningSameConversationRetainsRootAndDetailRoute() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        try await loadRail("A", model: model, client: client)
        model.navigate(.context)
        let task = Task { await model.run(conversationID: "A", isBusy: { false }) }
        try await waitForRailRequest("A", client: client)
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        XCTAssertEqual(model.route, .context)
        task.cancel()
        await client.gate.fail("A", URLError(.cancelled))
        await task.value
        XCTAssertNil(model.error)
    }

    @MainActor func testRuntimeChangeNeverRestoresPreviousAuthorityCache() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        try await loadRail("A", model: model, client: client)
        try await loadRail("B", model: model, client: client)
        await client.gate.setIdentity("other-runtime")
        let task = Task { await model.run(conversationID: "A", isBusy: { false }) }
        try await waitForRailRequest("A", client: client)
        XCTAssertNil(model.snapshot)
        task.cancel(); await client.gate.fail("A", URLError(.cancelled)); await task.value
    }

    @MainActor func testServerRestartEvictsOtherConversationSnapshots() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        try await loadRail("A", model: model, client: client)
        try await loadRail("B", model: model, client: client, instance: "restarted")
        let task = Task { await model.run(conversationID: "A", isBusy: { false }) }
        try await waitForRailRequest("A", client: client)
        XCTAssertNil(model.snapshot)
        task.cancel(); await client.gate.fail("A", URLError(.cancelled)); await task.value
    }

    @MainActor func testSnapshotCacheEvictsLeastRecentlyVisitedConversation() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        for index in 0..<9 { try await loadRail(String(index), model: model, client: client) }
        let task = Task { await model.run(conversationID: "0", isBusy: { false }) }
        try await waitForRailRequest("0", client: client)
        XCTAssertNil(model.snapshot)
        task.cancel(); await client.gate.fail("0", URLError(.cancelled)); await task.value
    }

    @MainActor func testCancelledPresentationCannotSelectAnotherConversation() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        try await loadRail("A", model: model, client: client)
        let obsolete = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.run(conversationID: "B", isBusy: { false })
        }
        await obsolete.value
        XCTAssertEqual(model.conversationID, "A")
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        let dispatched = await client.gate.has("B")
        XCTAssertFalse(dispatched)
    }

    @MainActor func testTransportCancellationWhileStillVisibleShowsRetryInsteadOfEndlessLoading() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        let task = Task { await model.run(conversationID: "A", isBusy: { false }) }
        try await waitForRailRequest("A", client: client)
        await client.gate.fail("A", URLError(.cancelled))
        for _ in 0..<1000 {
            if !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isRefreshing)
        task.cancel(); await task.value
    }
}


extension SessionRailTests {
    @MainActor func testViewTaskCancellationDoesNotCancelVisiblePresentationLoad() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        let pane = UUID()
        let viewTask = Task { model.setPresentationActive(pane, conversationID: "A") }
        await viewTask.value
        try await waitForRailRequest("A", client: client)
        viewTask.cancel()
        await client.gate.reply("A", try decode(Self.root(conversation: "A")))
        for _ in 0..<1000 {
            if model.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        model.setPresentationActive(pane, conversationID: nil)
    }

    @MainActor func testDisappearingDockedPaneCannotCancelFloatingReplacement() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        let docked = UUID(), floating = UUID()
        model.setPresentationActive(docked, conversationID: "A")
        try await waitForRailRequest("A", client: client)
        model.setPresentationActive(floating, conversationID: "A")
        model.setPresentationActive(docked, conversationID: nil)
        await client.gate.reply("A", try decode(Self.root(conversation: "A")))
        for _ in 0..<1000 {
            if model.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.snapshot?.conversationID, "A")
        model.setPresentationActive(floating, conversationID: nil)
    }

    @MainActor func testVisiblePresentationSwitchRejectsLatePreviousConversation() async throws {
        let client = RailModelClient()
        let model = SessionRailModel(client: client)
        let pane = UUID()
        model.setPresentationActive(pane, conversationID: "A")
        try await waitForRailRequest("A", client: client)
        model.setPresentationActive(pane, conversationID: "B")
        try await waitForRailRequest("B", client: client)
        await client.gate.reply("B", try decode(Self.root(conversation: "B")))
        await client.gate.reply("A", try decode(Self.root(conversation: "A")))
        for _ in 0..<1000 {
            if model.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.snapshot?.conversationID, "B")
        model.setPresentationActive(pane, conversationID: nil)
    }
}


#if os(macOS)
private struct RailLifecycleFixture: View {
    @Environment(WorkspaceStore.self) private var store
    let visible: Bool
    var body: some View {
        SessionRailView()
            .environment(\.sessionRailIsVisible, visible)
            .environment(\.scenePhase, .active)
            .environment(\.conversationUsesSessionRail,
                         store.sessionRail.hasTaskSurface(for: store.selectedConversation?.id))
    }
}

extension SessionRailTests {
    @MainActor func testHostedRailUpdatesAfterResponsesAndVisibilityTransactions() async throws {
        _ = NSApplication.shared
        let client = RailModelClient()
        let store = WorkspaceStore(client: client, usesEmbeddedRuntime: false)
        let host = NSHostingView(rootView: RailLifecycleFixture(visible: true).environment(store))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 600)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        for id in ["host-A", "host-B", "host-A", "host-C"] {
            store.selectedConversation = ConversationRef(id: id, workspacePath: "/tmp")
            // Several presentation changes in a single transaction must settle
            // on visible, even while selection and response publication redraw.
            host.rootView = RailLifecycleFixture(visible: false).environment(store)
            host.layoutSubtreeIfNeeded()
            host.rootView = RailLifecycleFixture(visible: true).environment(store)
            host.layoutSubtreeIfNeeded()
            try await waitForRailRequest(id, client: client)
            await client.gate.reply(id, try decode(Self.root(conversation: id)))
            for _ in 0..<1000 {
                if store.sessionRail.snapshot?.conversationID == id && !store.sessionRail.isRefreshing { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(store.sessionRail.conversationID, id)
            XCTAssertEqual(store.sessionRail.snapshot?.conversationID, id)
            XCTAssertFalse(store.sessionRail.isRefreshing)
        }
    }
}
#endif
