//
//  PreviewResolverRetry.swift
//  AgentKit
//
//  A viewer/asset fetch can race the runtime's artifact registration when a
//  session is switched or replayed: the client snapshot already carries the
//  artifact revision, while the runtime's preview route has not observed it
//  yet and answers 404 `preview_artifact_missing` / `preview_asset_unavailable`.
//  One short, transparent retry covers that window. A real 404 still surfaces
//  after the retry, and no request is issued twice for the same revision.
//

import Foundation

struct PreviewResolverRetryPolicy: Sendable, Equatable {
    /// Total attempts, including the first one.
    let maximumAttempts: Int
    /// Delay between attempts. Kept short so a real failure is not hidden.
    let delay: Duration

    static let registrationLag = PreviewResolverRetryPolicy(
        maximumAttempts: 2,
        delay: .milliseconds(300)
    )

    init(maximumAttempts: Int, delay: Duration) {
        self.maximumAttempts = maximumAttempts
        self.delay = delay
    }
}

struct PreviewResolverRetry: Sendable {
    let policy: PreviewResolverRetryPolicy

    init(policy: PreviewResolverRetryPolicy = .registrationLag) {
        self.policy = policy
    }

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < policy.maximumAttempts,
                      Self.isRegistrationLag(error) else {
                    throw error
                }
                try await Task.sleep(for: policy.delay)
                attempt += 1
            }
        }
    }

    /// Only a "the runtime has not registered this yet" 404 is retried. Other
    /// preview failures — digest mismatch, security violation, expiry, a real
    /// missing artifact — are preserved for the caller's failure presentation.
    static func isRegistrationLag(_ error: Error) -> Bool {
        if let error = error as? PreviewHTTPError {
            return error.httpStatus == 404
        }
        if let error = error as? RuntimeHTTPError {
            switch error {
            case .notFound:
                return true
            case .unexpectedStatus(let status, _):
                return status == 404
            case .preview(let preview):
                return preview.httpStatus == 404
            default:
                return false
            }
        }
        return false
    }
}
