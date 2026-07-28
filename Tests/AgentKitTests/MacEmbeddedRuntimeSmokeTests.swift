#if os(macOS) && canImport(CodeAgentRuntime)
import Foundation
import XCTest
@testable import AgentKit

final class MacEmbeddedRuntimeSmokeTests: XCTestCase {
    func testFullDesktopRuntimeStartsOnEphemeralLoopbackPort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-mac-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = AgentRuntime.shared
        runtime.stop()
        try runtime.configure(
            EmbeddedRuntimeConfiguration(
                workspaceDirectory: root.appendingPathComponent("workspace", isDirectory: true),
                dataDirectory: root.appendingPathComponent("data", isDirectory: true),
                profile: .fullDesktop
            )
        )
        defer { runtime.stop() }

        let port = try runtime.ensureStarted()
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(runtime.currentConfiguration.profile, .fullDesktop)

        let healthURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/healthz"))
        let (_, response) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
#endif
