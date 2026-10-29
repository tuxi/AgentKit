import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class CodingTaskReplayLiveTests: XCTestCase {
    func testActualReadOnlyReplayHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTKIT_REPLAY_CONNECTION"] else {
            throw XCTSkip("Explicit local replay connection required")
        }
        struct Connection: Decodable {
            let endpoint: URL
            let access_token: String
            let fixture_only: Bool
        }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard connection.fixture_only, connection.endpoint.host == "127.0.0.1" else {
            throw XCTSkip("Only a local offline replay host is allowed")
        }
        let credentials = MemoryCredentialStore()
        try await credentials.set(.init(kind: .bearer, secret: connection.access_token), for: .runtimeAccess("offline-live-test"))
        let client = DefaultAgentClient(environment: try RuntimeEnvironment(origin: connection.endpoint), credentialStore: credentials, credentialTarget: .runtimeAccess("offline-live-test"))
        let store = CodingTaskStore(reader: client)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.tasks.count, 1)
        let id = try XCTUnwrap(store.tasks.first?.task_id)
        store.select(id)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.task_acceptance, "accepted")
        XCTAssertEqual(store.snapshot?.executionRounds, 2)
        XCTAssertEqual(store.history.events.count, 22)
        let artifacts = try XCTUnwrap(store.snapshot).artifact_refs.filter { $0.kind == "review_bundle" }
        XCTAssertEqual(artifacts.count, 2)
        for artifact in artifacts { _ = try await store.bundle(for: artifact) }
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.history.events.count, 22)
    }
}
