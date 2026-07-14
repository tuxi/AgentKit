import Foundation
import XCTest
@testable import AgentKit

/// Opt-in production-boundary test against the real Code-Agent daemon.
///
/// Normal `swift test` skips this suite. Run it with:
///
/// ```text
/// CODEAGENT_RUNTIME_BIN=/absolute/path/to/codeagent \
/// AGENTKIT_RUN_W3_E2E=1 \
/// swift test --filter ManagedWorktreeRuntimeE2ETests
/// ```
///
/// The test owns a temporary Git repository, Runtime process and SQLite store.
/// It never reads or mutates the user's normal Code-Agent sessions.
final class ManagedWorktreeRuntimeE2ETests: XCTestCase {
    func testRealRuntimeManagedWorktreeProductionMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTKIT_RUN_W3_E2E"] == "1" else {
            throw XCTSkip("Set AGENTKIT_RUN_W3_E2E=1 to run the real Runtime matrix")
        }
        let binaryPath = try XCTUnwrap(environment["CODEAGENT_RUNTIME_BIN"])
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw XCTSkip("CODEAGENT_RUNTIME_BIN is not executable: \(binaryPath)")
        }
        guard environment["DEEPSEEK_API_KEY"]?.isEmpty == false else {
            throw XCTSkip("DEEPSEEK_API_KEY is required for scheduling turns")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-w3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let port = Int(environment["AGENTKIT_W3_RUNTIME_PORT"] ?? "18897") ?? 18897
        let runtime = RealRuntimeProcess(binaryPath: binaryPath, root: root, port: port)
        defer {
            runtime.stop()
            try? FileManager.default.removeItem(at: root)
        }

        try prepareGitRepository(at: root)
        try writeRuntimeConfig(at: root)
        try runtime.start()
        try await runtime.waitUntilHealthy()

        let client = DefaultAgentClient(environment: RuntimeEnvironment(host: "127.0.0.1", port: port))
        let capabilities = try await client.runtimeCapabilities()
        XCTAssertTrue(capabilities.supportsManagedWorktree)
        XCTAssertTrue(capabilities.allowsMultiSessionExecution)
        XCTAssertEqual(capabilities.limits?.maxConcurrentTurns, 2)
        print("[W3] capabilities verified")

        // Dirty source warning: uncommitted/untracked source changes are never
        // copied silently into the managed checkout.
        let dirtySource = root.appendingPathComponent("source-untracked.txt")
        try "source change".write(to: dirtySource, atomically: true, encoding: .utf8)
        let warningConversation = try await createManagedConversation(
            client: client,
            root: root,
            name: "dirty-warning"
        )
        XCTAssertTrue(warningConversation.warnings?.contains {
            $0.code == "source_workspace_dirty"
        } == true)
        try FileManager.default.removeItem(at: dirtySource)
        print("[W3] dirty source warning verified")

        let managedA = try await createManagedConversation(client: client, root: root, name: "parallel-a")
        let managedB = try await createManagedConversation(client: client, root: root, name: "parallel-b")
        XCTAssertNotEqual(managedA.workspacePath, managedB.workspacePath)

        let managedTraces = try await runPair(client: client, first: managedA, second: managedB)
        assertOverlapped(managedTraces.0, managedTraces.1)
        print("[W3] managed worktree overlap verified")

        let sharedA = try await createSharedConversation(client: client, root: root)
        let sharedB = try await createSharedConversation(client: client, root: root)
        let sharedTraces = try await runPair(client: client, first: sharedA, second: sharedB)
        XCTAssertGreaterThan(sharedTraces.0.queuedCount + sharedTraces.1.queuedCount, 0)
        XCTAssertTrue(
            (sharedTraces.0.queuedReasons + sharedTraces.1.queuedReasons)
                .contains(RuntimeQueueReason.workspaceLease.rawValue)
        )
        assertSerialized(sharedTraces.0, sharedTraces.1)
        print("[W3] shared workspace lease verified")

        // Restart must preserve the same session/checkout identities.
        runtime.stop()
        try runtime.start()
        try await runtime.waitUntilHealthy()
        let restored = try await client.listConversations()
        let restoredA = try XCTUnwrap(restored.first { $0.id == managedA.id })
        let restoredB = try XCTUnwrap(restored.first { $0.id == managedB.id })
        XCTAssertEqual(restoredA.workspacePath, managedA.workspacePath)
        XCTAssertEqual(restoredB.workspacePath, managedB.workspacePath)
        XCTAssertEqual(restoredA.worktree?.state, "ready")
        XCTAssertEqual(restoredB.worktree?.state, "ready")
        print("[W3] restart recovery verified")

        // A missing checkout is reconciled on restart and surfaced to both detail
        // and activity instead of being recreated behind the user's back.
        runtime.stop()
        try FileManager.default.removeItem(atPath: managedA.workspacePath)
        try runtime.start()
        try await runtime.waitUntilHealthy()
        let missingDetail = try await client.getConversationDetail(id: managedA.id)
        XCTAssertEqual(missingDetail.worktree?.state, "missing")
        XCTAssertTrue(missingDetail.worktree?.needsRebind == true)
        let missingActivity = try await client.activitySnapshot()
        let missingSession = try XCTUnwrap(missingActivity.sessions.first { $0.sessionID == managedA.id })
        XCTAssertEqual(missingSession.state, "workspace_missing")
        XCTAssertTrue(missingSession.worktree?.needsRebind == true)
        print("[W3] missing/rebind attention verified")

        // Dirty-safe removal: first request returns a structured summary; only a
        // distinct explicit force request removes the checkout. Conversation state
        // is then deleted separately.
        let untracked = URL(fileURLWithPath: managedB.workspacePath)
            .appendingPathComponent("untracked-result.txt")
        try "important".write(to: untracked, atomically: true, encoding: .utf8)
        do {
            _ = try await client.removeManagedWorktree(
                conversationID: managedB.id,
                request: ManagedWorktreeRemoveRequest(requestID: "remove-safe-\(UUID().uuidString)")
            )
            XCTFail("expected worktree_dirty")
        } catch let error as ManagedWorktreeRemovalError {
            XCTAssertTrue(error.isDirtyConflict)
            XCTAssertEqual(error.summary?.untrackedFiles, 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedB.workspacePath))

        let removed = try await client.removeManagedWorktree(
            conversationID: managedB.id,
            request: ManagedWorktreeRemoveRequest(
                requestID: "remove-force-\(UUID().uuidString)",
                force: true
            )
        )
        XCTAssertEqual(removed.worktree.state, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedB.workspacePath))
        try await client.deleteConversation(id: managedB.id)
        let afterDelete = try await client.listConversations()
        XCTAssertFalse(afterDelete.contains { $0.id == managedB.id })
        print("[W3] dirty-safe remove and explicit delete verified")
    }

    private func createManagedConversation(
        client: DefaultAgentClient,
        root: URL,
        name: String
    ) async throws -> ConversationRef {
        try await client.createConversation(request: CreateConversationRequest(
            clientRequestID: "create-\(name)-\(UUID().uuidString)",
            workspacePath: root.path,
            executionPolicy: .isolatedWorktree,
            workspaceID: root.path,
            baseWorkspaceID: root.path,
            worktree: ManagedWorktreeCreateRequest(suggestedName: name, baseRef: .head)
        ))
    }

    private func createSharedConversation(
        client: DefaultAgentClient,
        root: URL
    ) async throws -> ConversationRef {
        try await client.createConversation(request: CreateConversationRequest(
            workspacePath: root.path,
            executionPolicy: .sharedWorkspace,
            workspaceID: root.path,
            baseWorkspaceID: root.path
        ))
    }

    private func runPair(
        client: DefaultAgentClient,
        first: ConversationRef,
        second: ConversationRef
    ) async throws -> (TurnTrace, TurnTrace) {
        let firstChannel = client.makeSessionChannel(conversationID: first.id)
        let secondChannel = client.makeSessionChannel(conversationID: second.id)
        let firstStream = try await firstChannel.connect(since: 0)
        let secondStream = try await secondChannel.connect(since: 0)

        async let firstTrace = Self.traceTerminal(stream: firstStream)
        async let secondTrace = Self.traceTerminal(stream: secondStream)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await firstChannel.send(input: .text("Reply exactly OK.", model: "deepseek"))
            }
            group.addTask {
                await secondChannel.send(input: .text("Reply exactly OK.", model: "deepseek"))
            }
        }
        let result = try await (firstTrace, secondTrace)
        await firstChannel.disconnect()
        await secondChannel.disconnect()
        return result
    }

    private static func traceTerminal(stream: AsyncStream<AgentEvent>) async throws -> TurnTrace {
        var trace = TurnTrace()
        for await event in stream {
            let now = ContinuousClock.now
            switch event {
            case .turnQueued(_, let reason, _):
                trace.queuedCount += 1
                if let reason { trace.queuedReasons.append(reason) }
            case .turnStarted:
                trace.startedAt = trace.startedAt ?? now
            case .turnFinished, .turnFailed, .turnCancelled:
                trace.terminalAt = now
                return trace
            default:
                break
            }
        }
        throw RuntimeE2EError.streamEndedBeforeTerminal
    }

    private func assertOverlapped(
        _ first: TurnTrace,
        _ second: TurnTrace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstStart = first.startedAt,
              let secondStart = second.startedAt,
              let firstTerminal = first.terminalAt,
              let secondTerminal = second.terminalAt else {
            return XCTFail("missing lifecycle timestamps", file: file, line: line)
        }
        XCTAssertLessThan(max(firstStart, secondStart), min(firstTerminal, secondTerminal), file: file, line: line)
    }

    private func assertSerialized(
        _ first: TurnTrace,
        _ second: TurnTrace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ordered = [first, second].sorted {
            ($0.startedAt ?? .now) < ($1.startedAt ?? .now)
        }
        guard let firstTerminal = ordered[0].terminalAt,
              let secondStart = ordered[1].startedAt else {
            return XCTFail("missing lifecycle timestamps", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(secondStart, firstTerminal, file: file, line: line)
    }

    private func prepareGitRepository(at root: URL) throws {
        try run("/usr/bin/git", ["init", "-b", "main"], at: root)
        try run("/usr/bin/git", ["config", "user.email", "w3@codeagent.local"], at: root)
        try run("/usr/bin/git", ["config", "user.name", "CodeAgent W3"], at: root)
        try "# W3\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "config.yaml\n.codeagent/\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try run("/usr/bin/git", ["add", "README.md", ".gitignore"], at: root)
        try run("/usr/bin/git", ["commit", "-m", "W3 fixture"], at: root)
    }

    private func writeRuntimeConfig(at root: URL) throws {
        let config = """
        default_model: deepseek
        credentials:
          llm:
            deepseek:
              source: env
              env: DEEPSEEK_API_KEY
        models:
          deepseek:
            provider: openai
            base_url: "https://api.deepseek.com"
            model: "deepseek-v4-flash"
            credential:
              namespace: llm
              name: deepseek
            context_window: 128000
        agent:
          max_steps: 4
        provider:
          request_timeout_seconds: 90
          max_retries: 0
        runtime:
          max_concurrent_turns: 2
        """
        try config.write(
            to: root.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func run(_ executable: String, _ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeE2EError.commandFailed(executable, arguments)
        }
    }
}

private struct TurnTrace {
    var startedAt: ContinuousClock.Instant?
    var terminalAt: ContinuousClock.Instant?
    var queuedCount = 0
    var queuedReasons: [String] = []
}

private enum RuntimeE2EError: Error {
    case streamEndedBeforeTerminal
    case commandFailed(String, [String])
    case runtimeExited(Int32)
    case healthTimeout
}

private final class RealRuntimeProcess: @unchecked Sendable {
    private let binaryPath: String
    private let root: URL
    private let port: Int
    private var process: Process?

    init(binaryPath: String, root: URL, port: Int) {
        self.binaryPath = binaryPath
        self.root = root
        self.port = port
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve", "127.0.0.1:\(port)"]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }

    func waitUntilHealthy() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/healthz")!
        for _ in 0..<100 {
            if let process, !process.isRunning {
                throw RuntimeE2EError.runtimeExited(process.terminationStatus)
            }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeE2EError.healthTimeout
    }
}
