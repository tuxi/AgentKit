import SwiftUI

private struct ComposerEnvironmentNameKey: EnvironmentKey { static let defaultValue = "执行环境" }
private struct ComposerEnvironmentSymbolKey: EnvironmentKey { static let defaultValue = "desktopcomputer" }
public extension EnvironmentValues {
    var composerEnvironmentName: String {
        get { self[ComposerEnvironmentNameKey.self] }
        set { self[ComposerEnvironmentNameKey.self] = newValue }
    }
    var composerEnvironmentSymbol: String {
        get { self[ComposerEnvironmentSymbolKey.self] }
        set { self[ComposerEnvironmentSymbolKey.self] = newValue }
    }
}
