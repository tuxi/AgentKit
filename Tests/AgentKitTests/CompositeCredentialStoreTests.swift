import Foundation
import XCTest
@testable import AgentKit

final class CompositeCredentialStoreTests: XCTestCase {
    func testMergesGatewayAndDirectCredentials() async throws {
        let gateway = MemoryCredentialStore()
        let direct = MemoryCredentialStore()
        let composite = CompositeCredentialStore(
            storesByNamespace: [
                "gateway": gateway,
                "llm": direct,
            ]
        )

        try await composite.set(
            Credential(kind: .bearer, secret: "gateway-token"),
            for: .gateway
        )
        try await composite.set(
            Credential(kind: .bearer, secret: "direct-key"),
            for: .llm("company-production")
        )

        let all = try await composite.all()
        XCTAssertEqual(all[.gateway]?.secret, "gateway-token")
        XCTAssertEqual(all[.llm("company-production")]?.secret, "direct-key")
    }

    func testMissingNamespaceDoesNotLeakAnotherStore() async throws {
        let direct = MemoryCredentialStore()
        let composite = CompositeCredentialStore(storesByNamespace: ["llm": direct])
        let resolved = try await composite.resolve(.gateway)
        XCTAssertNil(resolved)
    }
}
