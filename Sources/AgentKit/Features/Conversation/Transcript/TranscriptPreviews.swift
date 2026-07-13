//
//  TranscriptPreviews.swift
//  AgentKit
//
//  Palette workbench: one synthetic turn exercising every themed element
//  (links, inline code, quote bar, list wrapping, CJK table, syntax
//  highlight, diff stripes, error block, tool rows) so TranscriptTheme
//  values can be tuned side by side in light and dark canvases.
//

#if DEBUG
import SwiftUI

private enum TranscriptPreviewData {

    static let markdown = """
    ## 调色板验证

    正文里有一个外部链接 [TextKit 文档](https://developer.apple.com/documentation/appkit/textkit)、\
    一个裸 URL https://example.com/docs、一个文件路径 Sources/AgentKit/Features/Conversation/Transcript/TranscriptTheme.swift，\
    以及 `inline code` 和 **加粗**、*斜体* 文本。English words should wrap at word boundaries, \
    not mid-word, even in a fairly long sentence like this one.

    > 引用块：绘制层只负责画左侧竖条和缩进，正文降为次级色。这一段写得足够长，\
    > 用来验证换行之后引用的缩进与竖条是否对齐。

    - 列表项一：这一行故意写得比较长，验证换行之后悬挂缩进是否与首行文字对齐 hanging indent check
    - 列表项二 with `inline code` and Sources/App.swift

    1. 有序列表第一项
    2. 有序列表第二项

    | 文件 | 行数 | 说明 |
    | --- | ---: | --- |
    | TranscriptTheme.swift | 342 | 调色板与块级标注 |
    | NativeTranscriptView.swift | 310 | TextKit 渲染层 |

    宽单元格表格（验证窄容器下的退化行为——续行应悬挂在第二列下，而不是竖排）：

    | 项目 | samber/cc-skills-golang | code-agent |
    | --- | --- | --- |
    | 额外字段 | user-invocable, metadata, requires, allowed-tools, homepage, openclaw | 静默忽略，不报错 |
    | 说明 | 行号标注（中文"第 109 行"、英文"L109"等）、Markdown 表格行号列，目录类型带 trailing-slash | 同，还支持裸 .md |

    ```swift
    struct Example {
        // 注释色验证 comment tone
        let answer = 42
        func run() throws -> String {
            guard answer > 0 else { throw Failure() }
            return "done"
        }
    }
    ```

    ---

    分隔线上下的收尾段落。
    """

    static func makeTurn() -> ConversationTurn {
        let readTool = ToolNodePayload(
            callID: "tool_read",
            toolName: "read_file",
            args: .object(["path": .string("Sources/App.swift")]),
            status: .completed,
            output: "import SwiftUI\n\nlet palette = TranscriptTheme.self",
            exitCode: 0,
            elapsedMs: 12
        )
        let diffTool = ToolNodePayload(
            callID: "tool_diff",
            toolName: "edit_file",
            args: .object(["path": .string("Sources/App.swift")]),
            status: .completed,
            output: """
            @@ -1,3 +1,3 @@
             import SwiftUI
            -let color = Color.red
            +let color = Color.accentColor
            """,
            exitCode: 0,
            elapsedMs: 240
        )
        let failedTool = ToolNodePayload(
            callID: "tool_fail",
            toolName: "run_command",
            args: .object(["command": .string("swift test")]),
            status: .failed,
            output: "error: no tests found",
            exitCode: 1,
            elapsedMs: 900
        )

        return ConversationTurn(
            id: "preview_turn",
            userPrompt: MessageNodePayload(role: .user, text: "把 transcript 的浅色/深色样式都过一遍。"),
            blocks: [
                .text(id: "t1", MessageNodePayload(role: .assistant, text: markdown)),
                .toolGroup(ToolGroup(id: "tools", tools: [readTool, diffTool, failedTool])),
                .system(id: "err", SystemNodePayload(
                    kind: .error,
                    text: "Tool error: fetch https://example.com/api → HTTP 404"
                )),
                .childStream(id: "job", ChildStreamNodePayload(
                    kind: .job,
                    childID: "job_1",
                    title: "swift build --configuration release",
                    status: .completed,
                    result: "Build complete! (12.4s)",
                    exitCode: 0,
                    elapsedMs: 12400
                ))
            ],
            footer: TurnStats(contextTokens: 24900, totalTokens: 72100, usageUnits: 73500,
                              hasUsageUnits: true, elapsedMs: 14300, invocationCount: 3),
            isLive: false
        )
    }
}

private struct TranscriptPreviewHost: View {
    var body: some View {
        ScrollView {
            NativeTranscriptView(
                transcript: TurnTranscriptBuilder.build(
                    turn: TranscriptPreviewData.makeTurn(),
                    // Expand the group and both interesting tools so code,
                    // JSON args, and diff stripes are all visible.
                    state: TranscriptDocumentState(expandedToolIDs: [
                        "group:tools", "tool_read", "tool_diff"
                    ])
                ),
                onAction: { _ in }
            )
            .padding(16)
        }
    }
}

#Preview("Transcript — Light") {
    TranscriptPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Transcript — Dark") {
    TranscriptPreviewHost()
        .preferredColorScheme(.dark)
}

/// Narrow canvas — tables and code must degrade gracefully, never into
/// one-glyph-per-line vertical text.
#Preview("Transcript — Narrow") {
    TranscriptPreviewHost()
        .frame(width: 390)
        .preferredColorScheme(.light)
}
#endif
