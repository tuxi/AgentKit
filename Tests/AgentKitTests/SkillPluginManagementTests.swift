import Foundation
import XCTest
@testable import AgentKit

@MainActor
final class SkillPluginManagementTests: XCTestCase {
    func testInventoryDecodingPreservesGroupsAndTamperedPluginItem() throws {
        let skillJSON = #"""
        {
          "schema": "runtime-skill-inventory/v1",
          "scope": {
            "session_id": "sess_dreamlog",
            "workspace_id": "ws_123",
            "display_name": "DreamLog",
            "resolved": true
          },
          "items": [
            {
              "name": "ui-adaptation",
              "display_name": "UI Adaptation",
              "description": "Adapt UI",
              "scope": "project",
              "source": "project",
              "source_group": "project",
              "path": ".agents/skills/ui-adaptation/SKILL.md",
              "version": "1",
              "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "enabled": true,
              "status": "active",
              "resources": {"count": 0, "names": []},
              "warnings": [],
              "parse_errors": []
            },
            {
              "name": "docs:search",
              "display_name": "Docs Search",
              "description": "Search docs",
              "scope": "plugin",
              "source": "plugin",
              "source_group": "plugin",
              "path": "plugins/cache/docs/1.0.0/skills/search/SKILL.md",
              "version": "1.0.0",
              "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "enabled": true,
              "status": "active",
              "plugin_name": "docs",
              "resources": {"count": 0, "names": []},
              "warnings": [],
              "parse_errors": []
            }
          ],
          "warnings": [],
          "reload_required": false
        }
        """#
        let pluginJSON = #"""
        {
          "schema": "runtime-plugin-inventory/v1",
          "items": [
            {
              "name": "broken",
              "version": "1.0.0",
              "description": "Broken plugin",
              "enabled": true,
              "source": "local",
              "source_kind": "local_directory",
              "cache_id": "plg_broken",
              "cache_path": "plugins/cache/broken/1.0.0",
              "manifest_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "bundle_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
              "installed_skills": [],
              "mcp_servers": [],
              "has_apps": false,
              "has_hooks": false,
              "integrity_status": "failed",
              "error_code": "plugin_integrity_error",
              "reload_required": false
            }
          ],
          "reload_required": false
        }
        """#

        let decoder = JSONDecoder()
        let skills = try decoder.decode(RuntimeSkillInventory.self, from: Data(skillJSON.utf8))
        let plugins = try decoder.decode(RuntimePluginInventory.self, from: Data(pluginJSON.utf8))

        XCTAssertTrue(skills.scope.resolved)
        XCTAssertEqual(skills.items.map(\.sourceGroup), [.project, .plugin])
        XCTAssertEqual(skills.items[0].displayTitle, "UI Adaptation")
        XCTAssertEqual(plugins.items.first?.integrityStatus, "failed")
        XCTAssertEqual(plugins.items.first?.errorCode, "plugin_integrity_error")
        XCTAssertTrue(plugins.items.first?.integrityFailed == true)
    }

    func testViewModelKeepsTallHealthyInventoryWhenOnePluginIsTampered() async {
        let client = StubSkillPluginClient(
            skillResult: .success(
                RuntimeSkillInventory(
                    scope: .init(sessionID: "sess_dreamlog", displayName: "DreamLog", resolved: true),
                    items: [
                        skill(name: "ui-adaptation", group: "project"),
                        skill(name: "verify-change", group: "system"),
                    ]
                )
            ),
            pluginResult: .success(
                RuntimePluginInventory(items: [
                    plugin(name: "docs", enabled: true),
                    plugin(name: "broken", enabled: true, integrity: "failed"),
                    plugin(name: "paused", enabled: false),
                ])
            )
        )
        let viewModel = SkillPluginManagementViewModel(client: client, sessionID: "sess_dreamlog")

        await viewModel.load()

        XCTAssertNil(viewModel.pluginError)
        XCTAssertNil(viewModel.skillError)
        XCTAssertEqual(viewModel.effectiveSkillCount, 2)
        XCTAssertEqual(viewModel.skillCount(for: .project), 1)
        XCTAssertEqual(viewModel.skillCount(for: .system), 1)
        XCTAssertEqual(viewModel.skillCount(for: .plugin), 0)
        XCTAssertEqual(viewModel.failedIntegrityPluginCount, 1)
        XCTAssertEqual(viewModel.enabledPluginCount, 2)
        XCTAssertTrue(viewModel.pluginInventory.items.contains(where: { $0.name == "paused" && !$0.enabled }))
    }

    func testViewModelSurfacesAuthenticationAndKeepsPluginInventorySeparate() async {
        let client = StubSkillPluginClient(
            skillResult: .failure(SkillPluginManagementError.authenticationRequired("missing bearer token")),
            pluginResult: .success(RuntimePluginInventory(items: [plugin(name: "docs", enabled: true)]))
        )
        let viewModel = SkillPluginManagementViewModel(client: client, sessionID: "sess_dreamlog")

        await viewModel.load()

        XCTAssertTrue(viewModel.requiresAuthentication)
        XCTAssertNotNil(viewModel.skillError)
        XCTAssertNil(viewModel.pluginError)
        XCTAssertEqual(viewModel.pluginInventory.items.map(\.name), ["docs"])
    }

    func testDisabledPluginSkillIsNotProjectedAsActive() async {
        let client = StubSkillPluginClient(
            skillResult: .success(
                RuntimeSkillInventory(
                    scope: .init(sessionID: "sess_dreamlog", displayName: "DreamLog", resolved: true),
                    items: [skill(name: "docs:search", group: "plugin", pluginName: "docs")]
                )
            ),
            pluginResult: .success(
                RuntimePluginInventory(items: [plugin(name: "docs", enabled: false)])
            )
        )
        let viewModel = SkillPluginManagementViewModel(client: client, sessionID: "sess_dreamlog")

        await viewModel.load()

        XCTAssertEqual(viewModel.effectiveSkillCount, 0)
        XCTAssertEqual(viewModel.skillCount(for: .plugin), 0)
        XCTAssertTrue(viewModel.visibleSkills(for: .plugin).isEmpty)
    }

    func testInstalledGroupFilterOnlyProjectsSelectedSourceGroup() async {
        let client = StubSkillPluginClient(
            skillResult: .success(
                RuntimeSkillInventory(
                    scope: .init(sessionID: "sess_dreamlog", displayName: "DreamLog", resolved: true),
                    items: [
                        skill(name: "user-skill", group: "user"),
                        skill(name: "system-skill", group: "system"),
                    ]
                )
            ),
            pluginResult: .success(RuntimePluginInventory())
        )
        let viewModel = SkillPluginManagementViewModel(client: client, sessionID: "sess_dreamlog")
        await viewModel.load()

        viewModel.sourceFilter = .system

        XCTAssertTrue(viewModel.visibleSkills(for: .personal).isEmpty)
        XCTAssertEqual(viewModel.visibleSkills(for: .system).map(\.name), ["system-skill"])
    }

    func testStableHTTPErrorCodesMapToActionableErrors() {
        XCTAssertEqual(
            SkillPluginManagementError.mapped(statusCode: 401, code: "runtime_auth_required", message: nil),
            .authenticationRequired("")
        )
        XCTAssertEqual(
            SkillPluginManagementError.mapped(statusCode: 409, code: "workspace_scope_unresolved", message: nil),
            .workspaceScopeUnresolved("")
        )
        XCTAssertEqual(
            SkillPluginManagementError.mapped(statusCode: 409, code: "plugin_integrity_error", message: nil),
            .pluginIntegrityFailed("")
        )
        XCTAssertEqual(
            SkillPluginManagementError.mapped(statusCode: 422, code: "plugin_manifest_invalid", message: nil),
            .pluginManifestInvalid("")
        )
        XCTAssertEqual(
            SkillPluginManagementError.mapped(statusCode: 428, code: "plugin_confirmation_required", message: nil),
            .pluginConfirmationRequired("")
        )
    }

    private func skill(name: String, group: String, pluginName: String? = nil) -> RuntimeSkillItem {
        RuntimeSkillItem(
            name: name,
            displayName: name,
            description: "",
            scope: group,
            source: group,
            sourceGroupRaw: group,
            path: "\(group)/\(name)/SKILL.md",
            version: "1",
            sha256: String(repeating: "a", count: 64),
            enabled: true,
            status: "active",
            pluginName: pluginName
        )
    }

    private func plugin(
        name: String,
        enabled: Bool,
        integrity: String = "verified"
    ) -> RuntimePluginItem {
        RuntimePluginItem(
            name: name,
            version: "1.0.0",
            description: "",
            enabled: enabled,
            source: "local",
            sourceKind: "local_directory",
            integrityStatus: integrity,
            errorCode: integrity == "verified" ? nil : "plugin_integrity_error"
        )
    }
}

private final class StubSkillPluginClient: SkillPluginManaging, @unchecked Sendable {
    let skillResult: Result<RuntimeSkillInventory, Error>
    let pluginResult: Result<RuntimePluginInventory, Error>

    init(
        skillResult: Result<RuntimeSkillInventory, Error>,
        pluginResult: Result<RuntimePluginInventory, Error>
    ) {
        self.skillResult = skillResult
        self.pluginResult = pluginResult
    }

    func runtimeCapabilities() async throws -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(capabilities: ["skill_plugin_management_v1": true])
    }

    func skillInventory(sessionID: String?) async throws -> RuntimeSkillInventory {
        try skillResult.get()
    }

    func pluginInventory() async throws -> RuntimePluginInventory {
        try pluginResult.get()
    }

    func installLocalPlugin(source: String, confirmed: Bool) async throws -> RuntimePluginMutation {
        throw RuntimeHTTPError.unsupported
    }

    func setPluginEnabled(name: String, enabled: Bool) async throws -> RuntimePluginMutation {
        throw RuntimeHTTPError.unsupported
    }

    func uninstallPlugin(name: String) async throws -> RuntimePluginMutation {
        throw RuntimeHTTPError.unsupported
    }
}
