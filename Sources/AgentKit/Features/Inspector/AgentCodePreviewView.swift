import SwiftUI

/// AgentKit 的跨平台代码预览入口。
///
/// macOS 使用 `NSTextView`、原生滚动与行号 ruler；iOS 使用轻量 SwiftUI 行预览。
/// FileViewerKit 可通过其 text renderer 注入点复用这个视图，而无需依赖 AgentKit。
public struct AgentCodePreviewView: View {
    public let filePath: String
    public let content: String
    public let language: String?
    public let focusLine: Int?

    public init(
        filePath: String,
        content: String,
        language: String? = nil,
        focusLine: Int? = nil
    ) {
        self.filePath = filePath
        self.content = content
        self.language = language
        self.focusLine = focusLine
    }

    public var body: some View {
        FileArtifactBody(
            filePath: filePath,
            content: content,
            language: language,
            maxHeight: nil,
            focusLine: focusLine
        )
    }
}
