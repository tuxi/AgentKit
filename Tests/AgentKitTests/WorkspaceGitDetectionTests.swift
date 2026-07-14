import Foundation
import XCTest
@testable import AgentKit

final class WorkspaceGitDetectionTests: XCTestCase {
    func testResolvesBranchFromOrdinaryGitDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(Workspace(url: root).branch, "main")
    }

    func testResolvesBranchWhenDotGitIsAWorktreePointerFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = root.appendingPathComponent("repository/worktrees/task", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "ref: refs/heads/codeagent/task\n".write(
            to: metadata.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: repository/worktrees/task\n".write(
            to: root.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(Workspace(url: root).branch, "codeagent/task")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-workspace-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
