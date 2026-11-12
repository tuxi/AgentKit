import Foundation
import XCTest
@testable import AgentKit

final class BundledSkillsInstallerTests: XCTestCase {
    private func bundledSystemSkills() throws -> URL {
        guard let skills = Bundle.agentKitResourceBundle.url(forResource: "skills", withExtension: nil) else {
            throw BundledSkillsInstallerError.missingFile("skills test resource")
        }
        return skills.appendingPathComponent(".system", isDirectory: true)
    }

    private func installedSkill(_ dataDirectory: URL) -> URL {
        dataDirectory
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(".system", isDirectory: true)
            .appendingPathComponent("ui-adaptation", isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private func copyLegacyFixture(into dataDirectory: URL) throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legacy-system-skills", isDirectory: true)
        let skills = dataDirectory.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        for name in ["review-change", "verify-change", "skill-creator"] {
            try FileManager.default.copyItem(
                at: fixture.appendingPathComponent(name, isDirectory: true),
                to: skills.appendingPathComponent(name, isDirectory: true)
            )
        }
    }

    func testUpgradeFromLegacyFlattenedBundle() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try copyLegacyFixture(into: dataDirectory)

        let migrations = try BundledSkillsInstaller.install(
            bundleRoot: try bundledSystemSkills(),
            dataDirectory: dataDirectory,
            source: "test"
        )

        XCTAssertEqual(migrations.map(\.state), [.migrated, .migrated, .migrated])
        for name in ["review-change", "verify-change", "skill-creator"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("skills/\(name)").path)
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: dataDirectory.appendingPathComponent("skills/.system/\(name)/SKILL.md").path
                )
            )
        }
    }

    func testModifiedLegacySkillIsPreservedWithShadowWarning() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try copyLegacyFixture(into: dataDirectory)
        let legacy = dataDirectory.appendingPathComponent("skills/verify-change/SKILL.md")
        let handle = try FileHandle(forWritingTo: legacy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nuser modification\n".utf8))
        try handle.close()

        let migrations = try BundledSkillsInstaller.install(
            bundleRoot: try bundledSystemSkills(),
            dataDirectory: dataDirectory,
            source: "test"
        )

        let preserved = migrations.first { $0.name == "verify-change" }
        XCTAssertEqual(preserved?.state, .preserved)
        XCTAssertTrue(preserved?.warning?.contains("shadows system skill") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("skills/.system/verify-change/SKILL.md").path)
        )
    }

    func testResourcesSkillsContainsOnlySystemBundle() throws {
        guard let skills = Bundle.agentKitResourceBundle.url(forResource: "skills", withExtension: nil) else {
            throw BundledSkillsInstallerError.missingFile("skills test resource")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: skills,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(children.map(\.lastPathComponent), [".system"])
    }

    func testCleanAppDataInstallsSystemBundle() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try BundledSkillsInstaller.install(
            bundleRoot: try bundledSystemSkills(),
            dataDirectory: dataDirectory,
            source: "test"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: installedSkill(dataDirectory).path))
        let marker = dataDirectory
            .appendingPathComponent("skills/.system/\(BundledSkillsInstaller.markerFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepeatedInstallIsIdempotentAndPreservesUserSibling() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let userSkill = dataDirectory.appendingPathComponent("skills/mine/SKILL.md")
        try FileManager.default.createDirectory(at: userSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userBody = "---\nname: mine\ndescription: user skill\n---\nbody"
        try userBody.write(to: userSkill, atomically: true, encoding: .utf8)

        let bundle = try bundledSystemSkills()
        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")
        let marker = dataDirectory.appendingPathComponent("skills/.system/\(BundledSkillsInstaller.markerFilename)")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: marker.path)

        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")

        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
        XCTAssertEqual(try String(contentsOf: userSkill, encoding: .utf8), userBody)
    }


    func testMatchingMarkerRepairsUndeclaredFiles() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let bundle = try bundledSystemSkills()
        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")
        let rogue = dataDirectory.appendingPathComponent("skills/.system/rogue/SKILL.md")
        try FileManager.default.createDirectory(at: rogue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: rogue\ndescription: rogue\n---\nbody".write(to: rogue, atomically: true, encoding: .utf8)

        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")

        XCTAssertFalse(FileManager.default.fileExists(atPath: rogue.path))
    }

    func testBrokenMarkerAndContentAreRepaired() throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let bundle = try bundledSystemSkills()
        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")

        let marker = dataDirectory.appendingPathComponent("skills/.system/\(BundledSkillsInstaller.markerFilename)")
        try Data("broken".utf8).write(to: marker)
        try Data("broken".utf8).write(to: installedSkill(dataDirectory))
        try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")

        let repaired = try String(contentsOf: installedSkill(dataDirectory), encoding: .utf8)
        XCTAssertTrue(repaired.contains("name: ui-adaptation"))
        XCTAssertNotEqual(try Data(contentsOf: marker), Data("broken".utf8))
    }

    func testHashMismatchFailsBeforeMutation() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitBundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.copyItem(at: try bundledSystemSkills(), to: bundle)
        try Data("tampered".utf8).write(to: bundle.appendingPathComponent("ui-adaptation/SKILL.md"))
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKitSkills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        XCTAssertThrowsError(
            try BundledSkillsInstaller.install(bundleRoot: bundle, dataDirectory: dataDirectory, source: "test")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("skills/.system").path))
    }
}
