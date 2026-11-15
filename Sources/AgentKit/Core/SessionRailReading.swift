import Foundation

public protocol SessionRailReading: Sendable {
    func sessionRail(scope: SessionRailScope) async throws -> SessionRailSnapshot
    func sessionRailOutputs(scope: SessionRailScope, cursor: String?) async throws -> SessionRailOutputs
    func sessionRailOutput(scope: SessionRailScope, outputID: String) async throws -> SessionRailOutput
    func sessionRailConnectors(scope: SessionRailScope) async throws -> SessionRailConnectors
    func sessionRailConnector(scope: SessionRailScope, connectorID: String) async throws -> SessionRailConnector
    func sessionRailChanges(scope: SessionRailScope) async throws -> SessionRailChanges
    func sessionRailPatch(scope: SessionRailScope, snapshotID: String, fileID: String) async throws -> SessionRailPatch
    func sessionRailRequest(scope: SessionRailScope, snapshotID: String?) async throws -> SessionRailRequest
    func sessionRailSource(scope: SessionRailScope, snapshotID: String, sourceID: String) async throws -> SessionRailSourceContent
    func sessionRailJobs(scope: SessionRailScope, cursor: String?) async throws -> SessionRailJobs
}

public extension SessionRailReading {
    func sessionRail(scope: SessionRailScope) async throws -> SessionRailSnapshot { throw RuntimeHTTPError.unsupported }
    func sessionRailOutputs(scope: SessionRailScope, cursor: String?) async throws -> SessionRailOutputs { throw RuntimeHTTPError.unsupported }
    func sessionRailOutput(scope: SessionRailScope, outputID: String) async throws -> SessionRailOutput { throw RuntimeHTTPError.unsupported }
    func sessionRailConnectors(scope: SessionRailScope) async throws -> SessionRailConnectors { throw RuntimeHTTPError.unsupported }
    func sessionRailConnector(scope: SessionRailScope, connectorID: String) async throws -> SessionRailConnector { throw RuntimeHTTPError.unsupported }
    func sessionRailChanges(scope: SessionRailScope) async throws -> SessionRailChanges { throw RuntimeHTTPError.unsupported }
    func sessionRailPatch(scope: SessionRailScope, snapshotID: String, fileID: String) async throws -> SessionRailPatch { throw RuntimeHTTPError.unsupported }
    func sessionRailRequest(scope: SessionRailScope, snapshotID: String?) async throws -> SessionRailRequest { throw RuntimeHTTPError.unsupported }
    func sessionRailSource(scope: SessionRailScope, snapshotID: String, sourceID: String) async throws -> SessionRailSourceContent { throw RuntimeHTTPError.unsupported }
    func sessionRailJobs(scope: SessionRailScope, cursor: String?) async throws -> SessionRailJobs { throw RuntimeHTTPError.unsupported }
}
