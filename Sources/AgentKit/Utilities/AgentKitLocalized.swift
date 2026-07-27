import Foundation

/// AgentKit localization helper using the package's own String Catalog.
///
/// Uses `Bundle.module` by default so that AgentKit is self-contained.
/// Host apps may override the bundle to inject their own translations:
///
/// ```swift
/// AgentKitLocalized.bundle = .main
/// ```
public enum AgentKitLocalized {
    public static nonisolated(unsafe) var bundle: Bundle = .module

    public static func string(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: comment)
    }
}
