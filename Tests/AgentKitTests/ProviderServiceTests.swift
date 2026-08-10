import Foundation
import XCTest
@testable import AgentKit

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    static func setHandler(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func httpResponse(statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://127.0.0.1:8797/v1/providers")!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

private func envelopeJSON(_ data: Any) -> Data {
    let obj: [String: Any] = ["code": 0, "msg": "success", "data": data]
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func makeService(
    session: URLSession,
    token: String = "token-123"
) async throws -> RuntimeProviderService {
    let store = MemoryCredentialStore()
    try await store.set(
        Credential(kind: .bearer, secret: token),
        for: .runtimeAccess("test")
    )
    let client = RuntimeHTTPClient(
        environment: RuntimeEnvironment(host: "127.0.0.1", port: 8797),
        session: session,
        credentialStore: store,
        credentialTarget: .runtimeAccess("test")
    )
    return RuntimeProviderService(client: client)
}

// MARK: - RuntimeProviderService (HTTP CRUD)

final class RuntimeProviderServiceTests: XCTestCase {

    func testListProvidersReturnsFullDefinitions() async throws {
        let session = makeMockSession()
        let payload: [String: Any] = [
            "providers": [
                [
                    "id": "deepseek",
                    "api": "openai",
                    "base_url": "https://api.deepseek.com",
                    "credential": ["namespace": "llm", "name": "deepseek"],
                    "enabled": true,
                    "models": [[
                        "id": "deepseek-chat",
                        "context_window": 128_000,
                    ]],
                ],
                [
                    "id": "qwen",
                    "api": "openai",
                    "base_url": "https://api.qwen.example",
                    "credential": nil,
                    "enabled": false,
                    "models": [],
                ],
            ],
        ]
        MockURLProtocol.setHandler { _ in
            (httpResponse(), envelopeJSON(payload))
        }
        let service = try await makeService(session: session)

        let providers = try await service.listProviders()
        XCTAssertEqual(providers.map(\.id), ["deepseek", "qwen"])
        XCTAssertEqual(providers[0].enabled, true)
        XCTAssertEqual(providers[0].api, "openai")
        XCTAssertEqual(providers[0].baseURL, "https://api.deepseek.com")
        XCTAssertEqual(providers[0].models.first?.id, "deepseek-chat")
        XCTAssertEqual(providers[1].enabled, false)
    }

    func testProvidersRequestsSendBearerAuth() async throws {
        let session = makeMockSession()
        var captured: URLRequest?
        MockURLProtocol.setHandler { request in
            captured = request
            return (httpResponse(), envelopeJSON([
                "providers": [[
                    "id": "deepseek",
                    "api": "openai",
                    "base_url": "https://api.deepseek.com",
                    "enabled": true,
                    "models": [],
                ]],
            ]))
        }
        let service = try await makeService(session: session, token: "secret-token")

        _ = try await service.listProviders()
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.path, "/v1/providers")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testGetProviderDecodesDefinition() async throws {
        let session = makeMockSession()
        let definition: [String: Any] = [
            "id": "deepseek",
            "api": "openai",
            "base_url": "https://api.deepseek.com",
            "credential": ["namespace": "llm", "name": "deepseek"],
            "enabled": false,
            "models": [[
                "id": "deepseek-chat",
                "context_window": 128_000,
            ]],
        ]
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/providers/deepseek")
            return (httpResponse(), envelopeJSON(definition))
        }
        let service = try await makeService(session: session)

        let provider = try XCTUnwrap(try await service.getProvider(id: "deepseek"))
        XCTAssertEqual(provider.id, "deepseek")
        XCTAssertEqual(provider.api, "openai")
        XCTAssertEqual(provider.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(provider.enabled, false)
        XCTAssertEqual(provider.credential?.name, "deepseek")
        XCTAssertEqual(provider.models.first?.id, "deepseek-chat")
    }

    func testGetProviderMissingReturnsNil() async throws {
        let session = makeMockSession()
        MockURLProtocol.setHandler { _ in
            (httpResponse(statusCode: 404), Data())
        }
        let service = try await makeService(session: session)

        let provider = try await service.getProvider(id: "missing")
        XCTAssertNil(provider)
    }

    func testUpsertProviderSendsEnabledAndParsesApplied() async throws {
        let session = makeMockSession()
        var captured: URLRequest?
        MockURLProtocol.setHandler { request in
            captured = request
            return (httpResponse(), envelopeJSON(["applied": true]))
        }
        let service = try await makeService(session: session)

        let definition = RuntimeProviderDefinition(
            id: "deepseek",
            api: "openai",
            baseURL: "https://api.deepseek.com",
            credential: RuntimeConnectionCredentialDeclaration(namespace: "llm", name: "deepseek"),
            enabled: false,
            models: [RuntimeProviderModelDefinition(
                id: "deepseek-chat",
                contextWindow: 128_000
            )]
        )
        let result = try await service.upsertProvider(definition)

        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/v1/providers/deepseek")
        let body = try XCTUnwrap(captured?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["api"] as? String, "openai")
        XCTAssertEqual(json["base_url"] as? String, "https://api.deepseek.com")
        XCTAssertEqual(json["enabled"] as? Bool, false)
        XCTAssertEqual((json["models"] as? [[String: Any]])?.first?["id"] as? String, "deepseek-chat")
        XCTAssertEqual(result.applied, true)
    }

    func testUpsertProviderAppliedFalseMeansRestartRequired() async throws {
        let session = makeMockSession()
        MockURLProtocol.setHandler { _ in
            (httpResponse(), envelopeJSON(["applied": false]))
        }
        let service = try await makeService(session: session)

        let result = try await service.upsertProvider(
            RuntimeProviderDefinition(
                id: "qwen",
                api: "openai",
                baseURL: "https://api.qwen.example",
                credential: nil,
                models: []
            )
        )
        XCTAssertEqual(result.applied, false)
    }

    func testDeleteProviderParsesApplied() async throws {
        let session = makeMockSession()
        var captured: URLRequest?
        MockURLProtocol.setHandler { request in
            captured = request
            return (httpResponse(), envelopeJSON(["applied": false]))
        }
        let service = try await makeService(session: session)

        let result = try await service.deleteProvider(id: "deepseek")
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/v1/providers/deepseek")
        XCTAssertEqual(result.applied, false)
    }
}

// MARK: - Mapping (ProviderConnection ↔ RuntimeProviderDefinition)

final class ProviderMappingTests: XCTestCase {

    func testGatewayConnectionMapsToGatewayProvider() throws {
        let gateway = ProviderConnection.talkifyGateway(
            baseURL: URL(string: "https://api.objc.com")!,
            models: [ProviderModel(id: "deepseek-v4-pro", displayName: "DeepSeek Pro")],
            isEnabled: true
        )
        let definition = gateway.asRuntimeProviderDefinition()
        XCTAssertEqual(definition.id, "talkify-gateway")
        XCTAssertEqual(definition.api, "gateway")
        XCTAssertEqual(definition.credential?.namespace, "gateway")
        XCTAssertEqual(definition.credential?.name, "default")
        XCTAssertEqual(definition.enabled, true)
        XCTAssertEqual(definition.models.first?.id, "deepseek-v4-pro")
    }

    func testApiKeyConnectionMapsToOpenAIProvider() throws {
        let connection = ProviderConnection(
            id: "deepseek",
            providerID: "deepseek",
            displayName: "DeepSeek",
            transport: .openAIChatCompletions,
            authentication: .apiKey,
            baseURL: URL(string: "https://api.deepseek.com")!,
            models: [ProviderModel(id: "deepseek-chat")],
            isEnabled: false
        )
        let definition = connection.asRuntimeProviderDefinition()
        XCTAssertEqual(definition.api, "openai")
        XCTAssertEqual(definition.credential?.name, "deepseek")
        XCTAssertEqual(definition.credential?.namespace, "llm")
        XCTAssertEqual(definition.enabled, false)
        XCTAssertEqual(definition.models.first?.id, "deepseek-chat")
    }

    func testOllamaConnectionMapsToOllamaProvider() throws {
        let connection = ProviderConnection(
            id: "local-ollama",
            providerID: "ollama",
            displayName: "Ollama",
            transport: .ollama,
            authentication: .none,
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            models: [ProviderModel(id: "qwen3")]
        )
        let definition = connection.asRuntimeProviderDefinition()
        XCTAssertEqual(definition.api, "ollama")
        XCTAssertNil(definition.credential)
    }

    func testDefinitionMapsBackToConnection() throws {
        let definition = RuntimeProviderDefinition(
            id: "deepseek",
            api: "openai",
            baseURL: "https://api.deepseek.com",
            credential: RuntimeConnectionCredentialDeclaration(namespace: "llm", name: "deepseek"),
            enabled: false,
            models: [RuntimeProviderModelDefinition(
                id: "deepseek-chat",
                contextWindow: 128_000
            )]
        )
        let connection = definition.asProviderConnection()
        XCTAssertEqual(connection.id, "deepseek")
        XCTAssertEqual(connection.transport, .openAIChatCompletions)
        XCTAssertEqual(connection.authentication, .apiKey)
        XCTAssertEqual(connection.baseURL.absoluteString, "https://api.deepseek.com")
        XCTAssertEqual(connection.isEnabled, false)
        XCTAssertEqual(connection.models.first?.id, "deepseek-chat")
        XCTAssertEqual(connection.models.first?.contextWindow, 128_000)
    }
}

// MARK: - LocalProviderStore (registry-backed, iOS embedded)

@MainActor
final class LocalProviderStoreTests: XCTestCase {
    private func makeRegistry() -> ProviderConnectionRegistry {
        ProviderConnectionRegistry(
            defaults: UserDefaults(suiteName: "LocalProviderStoreTests.\(UUID().uuidString)")!,
            storageKey: "connections"
        )
    }

    func testUpsertAndGetRoundTrip() async throws {
        let registry = makeRegistry()
        let store = ProviderStoreFactory.embedded(registry: registry)

        let definition = RuntimeProviderDefinition(
            id: "deepseek",
            api: "openai",
            baseURL: "https://api.deepseek.com",
            credential: RuntimeConnectionCredentialDeclaration(namespace: "llm", name: "deepseek"),
            enabled: false,
            models: [RuntimeProviderModelDefinition(
                id: "deepseek-chat"
            )]
        )
        let result = try await store.upsertProvider(definition)
        XCTAssertEqual(result.applied, true)

        let restored = try await store.getProvider(id: "deepseek")
        XCTAssertEqual(restored?.id, "deepseek")
        XCTAssertEqual(restored?.enabled, false)
        XCTAssertEqual(restored?.models.first?.id, "deepseek-chat")
    }

    func testListReflectsEnabledFlag() async throws {
        let registry = makeRegistry()
        let store = ProviderStoreFactory.embedded(registry: registry)

        let enabled = RuntimeProviderDefinition(
            id: "a",
            api: "openai",
            baseURL: "https://a.example",
            credential: nil,
            models: []
        )
        let disabled = RuntimeProviderDefinition(
            id: "b",
            api: "openai",
            baseURL: "https://b.example",
            credential: nil,
            enabled: false,
            models: []
        )
        _ = try await store.upsertProvider(enabled)
        _ = try await store.upsertProvider(disabled)

        let list = try await store.listProviders()
        XCTAssertEqual(list.map(\.id), ["a", "b"])
        XCTAssertEqual(list[1].enabled, false)
    }

    func testDeleteRemovesFromRegistry() async throws {
        let registry = makeRegistry()
        let store = ProviderStoreFactory.embedded(registry: registry)
        _ = try await store.upsertProvider(RuntimeProviderDefinition(
            id: "a",
            api: "openai",
            baseURL: "https://a.example",
            credential: nil,
            models: []
        ))

        let result = try await store.deleteProvider(id: "a")
        XCTAssertEqual(result.applied, true)
        let restored = try await store.getProvider(id: "a")
        XCTAssertNil(restored)
    }
}
