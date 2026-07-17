import Foundation
import XCTest
@testable import AgentKit

final class CredentialMapTests: XCTestCase {
    func testSecretsJSONUsesMobileCompatibleStringValues() throws {
        let expiry = Date(timeIntervalSince1970: 1_784_718_813)
        let credential = Credential(
            kind: .bearer,
            secret: "jwt-token",
            expiresAt: expiry,
            metadata: ["refresh_token": "must-not-leak"]
        )
        let map = CredentialMap(entries: [.gateway: credential])

        let outerData = try XCTUnwrap(map.toSecretsJSON().data(using: .utf8))
        let outer = try XCTUnwrap(
            JSONSerialization.jsonObject(with: outerData) as? [String: String]
        )
        let encodedCredential = try XCTUnwrap(outer[CredentialTarget.gateway.id])
        let innerData = try XCTUnwrap(encodedCredential.data(using: .utf8))
        let inner = try XCTUnwrap(
            JSONSerialization.jsonObject(with: innerData) as? [String: Any]
        )

        XCTAssertEqual(inner["type"] as? String, "bearer")
        XCTAssertEqual(inner["secret"] as? String, "jwt-token")
        XCTAssertEqual(inner["expires_at"] as? Int64, 1_784_718_813)
        XCTAssertNil(inner["kind"])
        XCTAssertNil(inner["expiresAt"])
        XCTAssertNil(inner["metadata"])
        XCTAssertFalse(map.toSecretsJSON().contains("must-not-leak"))
    }
}
