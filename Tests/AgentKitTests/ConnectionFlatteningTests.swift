import Foundation
import XCTest
@testable import AgentKit

// MARK: - connection-flattening Wave 2 tests (PRD §4.3 A1-A4)

final class ConnectionFlatteningTests: XCTestCase {

    // MARK: A2.2 dual-key secretsJSON emission

    private func makeGatewayAndLLMCredentials() -> CredentialMap {
        let gateway = Credential(
            kind: .bearer,
            secret: "gateway-token",
            expiresAt: nil,
            metadata: ["refresh_token": "must-not-leak"]
        )
        let deepseek = Credential(
            kind: .bearer,
            secret: "deepseek-key",
            expiresAt: nil,
            metadata: [:]
        )
        return CredentialMap(entries: [
            .gateway: gateway,
            .llm("deepseek"): deepseek,
        ])
    }

    func testDefaultKeyModeIsNamespacedAndMatchesLegacyShape() throws {
        let map = makeGatewayAndLLMCredentials()
        let defaultJSON = map.toSecretsJSON()
        let namespacedJSON = map.toSecretsJSON(keyMode: .namespaced)

        // 语义比较：JSONEncoder 对 [String:String] 的 key 顺序不确定（未用
        // sortedKeys），原始字符串字节顺序可能不同，必须解析后比较字典。
        let defaultParsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaultJSON.data(using: .utf8)))
                as? [String: String]
        )
        let namespacedParsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(namespacedJSON.data(using: .utf8)))
                as? [String: String]
        )
        XCTAssertEqual(defaultParsed, namespacedParsed)

        let namespaced = namespacedParsed
        XCTAssertNotNil(namespaced["gateway/default"])
        XCTAssertNotNil(namespaced["llm/deepseek"])
        XCTAssertNil(namespaced["gateway"])
        XCTAssertNil(namespaced["deepseek"])
        XCTAssertEqual(namespaced.count, 2)
    }

    func testFlatKeyModeEmitsConnectionIDs() throws {
        let map = makeGatewayAndLLMCredentials()
        let flatJSON = map.toSecretsJSON(keyMode: .flat)
        let flat = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(flatJSON.data(using: .utf8)))
                as? [String: String]
        )
        XCTAssertNotNil(flat["gateway"])
        XCTAssertNotNil(flat["deepseek"])
        XCTAssertNil(flat["gateway/default"])
        XCTAssertNil(flat["llm/deepseek"])
        XCTAssertEqual(flat.count, 2)
    }

    func testDualKeyModeEmitsBothKeyFormsWithIdenticalValues() throws {
        let map = makeGatewayAndLLMCredentials()
        let dualJSON = map.toSecretsJSON(keyMode: .dual)
        let dual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(dualJSON.data(using: .utf8)))
                as? [String: String]
        )
        XCTAssertEqual(dual.count, 4)
        XCTAssertEqual(dual["gateway/default"], dual["gateway"])
        XCTAssertEqual(dual["llm/deepseek"], dual["deepseek"])

        // value 形状与 v1 一致：{type, secret, expires_at?}（expires_at 仅在
        // 有过期时间时出现，nil 时省略），且不含 refresh_token。
        for key in ["gateway/default", "gateway", "llm/deepseek", "deepseek"] {
            let inner = try XCTUnwrap(dual[key])
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(inner.data(using: .utf8)))
                    as? [String: Any]
            )
            XCTAssertEqual(object["type"] as? String, "bearer")
            XCTAssertNotNil(object["secret"])
            XCTAssertTrue(
                Set(object.keys).isSubset(of: ["type", "secret", "expires_at"]),
                "unexpected inner keys: \(object.keys)"
            )
        }
        XCTAssertFalse(dualJSON.contains("must-not-leak"))
    }

    func testDualKeyModePreservesExpiresAtWhenPresent() throws {
        let map = CredentialMap(entries: [
            .llm("deepseek"): Credential(
                kind: .bearer,
                secret: "deepseek-key",
                expiresAt: Date(timeIntervalSince1970: 1_784_718_813),
                metadata: [:]
            ),
        ])
        let dualJSON = map.toSecretsJSON(keyMode: .dual)
        let dual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(dualJSON.data(using: .utf8)))
                as? [String: String]
        )
        for key in ["llm/deepseek", "deepseek"] {
            let inner = try XCTUnwrap(dual[key])
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(inner.data(using: .utf8)))
                    as? [String: Any]
            )
            XCTAssertEqual(object["expires_at"] as? Int64, 1_784_718_813)
        }
    }

    func testFlatIDsDifferAcrossNamespaces() {
        XCTAssertEqual(CredentialTarget.gateway.flatID, "gateway")
        XCTAssertEqual(CredentialTarget.llm("deepseek").flatID, "deepseek")
        XCTAssertEqual(CredentialTarget.mcp("github").flatID, "github")
        XCTAssertEqual(CredentialTarget.llm("deepseek").id, "llm/deepseek")
        // persisted identity (namespaced) is unchanged
        XCTAssertEqual(CredentialTarget.gateway.id, "gateway/default")
    }

    // MARK: A1.2 schema prefix acceptance

    func testCatalogSchemaPrefixMatchAcceptsV1AndV2() throws {
        for schema in ["runtime-model-catalog/v1", "runtime-model-catalog/v2"] {
            let catalog = RuntimeServerModelCatalog(
                schema: schema,
                revision: 1,
                defaultRuntimeAlias: "",
                connections: []
            )
            XCTAssertTrue(catalog.hasSupportedSchema, "expected \(schema) to be accepted")
        }
        let unsupported = RuntimeServerModelCatalog(
            schema: "runtime-model-catalogx/v1",
            revision: 1,
            defaultRuntimeAlias: "",
            connections: []
        )
        XCTAssertFalse(unsupported.hasSupportedSchema)
    }

    // MARK: A1.1 v2 optional fields

    func testV2OptionalFieldsDecodeWhenPresentAndAbsent() throws {
        let withV2 = """
        {
          "schema": "runtime-model-catalog/v2",
          "revision": 8,
          "default_runtime_alias": "provider.ZGVlcHNlZWs.model.ZGVlcHNlZWstY2hhdA",
          "connections": [{
            "id": "deepseek",
            "provider_id": "deepseek",
            "display_name": "DeepSeek",
            "billing_source": "server_managed",
            "credential": {
              "status": "missing",
              "source": "injected"
            },
            "models": [{
              "runtime_alias": "provider.ZGVlcHNlZWs.model.ZGVlcHNlZWstY2hhdA",
              "wire_model_id": "deepseek-chat",
              "display_name": "DeepSeek Chat",
              "context_window": 64000,
              "supports_tools": true,
              "supports_reasoning": false,
              "input_modalities": ["text"],
              "available": false,
              "unavailable_reason": "quota exhausted"
            }]
          }]
        }
        """
        let catalog = try JSONDecoder().decode(
            RuntimeServerModelCatalog.self,
            from: try XCTUnwrap(withV2.data(using: .utf8))
        )
        let connection = try XCTUnwrap(catalog.connections.first)
        XCTAssertEqual(connection.credential?.status, "missing")
        XCTAssertEqual(connection.credential?.source, "injected")
        let model = try XCTUnwrap(connection.models.first)
        XCTAssertEqual(model.available, false)
        XCTAssertEqual(model.unavailableReason, "quota exhausted")

        // v1 payload without the new fields still decodes (optionals absent)
        let v1Connection = RuntimeServerModelConnection(
            id: "deepseek",
            providerID: "deepseek",
            displayName: "DeepSeek",
            billingSource: "server_managed",
            models: [RuntimeServerModelDescriptor(
                runtimeAlias: "a",
                wireModelID: "b",
                displayName: "B",
                contextWindow: nil,
                supportsTools: true,
                supportsReasoning: false,
                inputModalities: ["text"],
                available: true
            )]
        )
        XCTAssertNil(v1Connection.credential)
        XCTAssertNil(v1Connection.models.first?.unavailableReason)
    }

    // MARK: A3.1/A3.2 connectionsJSON serialization

    private func makeConnections() -> [ProviderConnection] {
        let gateway = ProviderConnection.talkifyGateway(
            baseURL: URL(string: "https://api.objc.com")!,
            models: [ProviderModel(id: "deepseek-v4-pro", displayName: "DeepSeek Pro")],
            isEnabled: true
        )
        let deepseek = ProviderConnection(
            id: "deepseek",
            providerID: "deepseek",
            displayName: "DeepSeek",
            transport: .openAIChatCompletions,
            authentication: .apiKey,
            baseURL: URL(string: "https://api.deepseek.com")!,
            models: [ProviderModel(id: "deepseek-chat", displayName: "DeepSeek Chat")],
            isEnabled: true
        )
        let disabled = ProviderConnection(
            id: "disabled",
            providerID: "openai-compatible",
            displayName: "Disabled",
            transport: .openAIChatCompletions,
            authentication: .apiKey,
            baseURL: URL(string: "https://example.com/v1")!,
            models: [ProviderModel(id: "m1")],
            isEnabled: false
        )
        return [gateway, deepseek, disabled]
    }

    func testBuildConnectionsJSONEmitsDefinitionsAndSkipsDisabled() throws {
        let json = try RuntimeProviderConfigurationBuilder.buildConnectionsJSON(
            connections: makeConnections()
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try JSONDecoder().decode(RuntimeConnectionsDocument.self, from: data)

        // 顶层是 map（connection_id → definition），无 schema 字段。
        XCTAssertEqual(document.connections.count, 2)
        XCTAssertEqual(Set(document.connections.keys), Set(["talkify-gateway", "deepseek"]))

        let gateway = try XCTUnwrap(document.connections["talkify-gateway"])
        XCTAssertEqual(gateway.id, "talkify-gateway")
        XCTAssertEqual(gateway.api, "openai")
        XCTAssertEqual(gateway.baseURL, "https://api.objc.com")
        XCTAssertEqual(gateway.credential?.source, "injected")
        XCTAssertEqual(gateway.credential?.ref, "gateway")

        let deepseek = try XCTUnwrap(document.connections["deepseek"])
        XCTAssertEqual(deepseek.id, "deepseek")
        XCTAssertEqual(deepseek.api, "openai")
        XCTAssertEqual(deepseek.credential?.ref, "deepseek")
        let model = try XCTUnwrap(deepseek.models.first)
        XCTAssertEqual(
            model.runtimeAlias,
            UnifiedModelDescriptor.makeRuntimeAlias(connectionID: "deepseek", wireModelID: "deepseek-chat")
        )
        XCTAssertEqual(model.wireModelID, "deepseek-chat")

        // 未启用 connection 不出现。
        XCTAssertNil(document.connections["disabled"])

        // wire 层不输出 schema 字段。
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(raw["schema"])
    }
}
