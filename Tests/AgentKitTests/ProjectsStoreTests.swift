import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class ProjectsStoreTests: XCTestCase {
    #if os(macOS)
    func testCreateProjectUsesCompactUniqueSuffixAndInitializesGit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("New Project", isDirectory: true),
            withIntermediateDirectories: false
        )

        let store = ProjectsStore(root: root)
        let workspace = try store.createProject(named: "New Project")

        XCTAssertEqual(workspace.url.lastPathComponent, "New Project1")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.url.appendingPathComponent(".git", isDirectory: true).path
            )
        )
        XCTAssertEqual(workspace.branch, "main")
        let config = try String(
            contentsOf: workspace.url.appendingPathComponent(".git/config"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("repositoryformatversion = 0"))
        XCTAssertTrue(config.contains("bare = false"))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--is-inside-work-tree"], in: workspace.url),
            "true"
        )
        XCTAssertTrue(
            try gitOutput(["status", "--porcelain=v1", "--branch"], in: workspace.url)
                .hasPrefix("## No commits yet on main")
        )
    }

    func testCreateProjectKeepsIncrementingUntilNameIsFree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["Project", "Project1", "Project2"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let workspace = try ProjectsStore(root: root).createProject(named: "Project")
        XCTAssertEqual(workspace.url.lastPathComponent, "Project3")
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    #if os(macOS)
    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "ProjectsStoreTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "git failed"]
            )
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    #endif
}
