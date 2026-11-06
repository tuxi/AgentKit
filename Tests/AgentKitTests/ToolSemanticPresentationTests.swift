import XCTest
@testable import AgentKit

final class ToolSemanticPresentationTests: XCTestCase {
    private func tool(_ name: String, _ args: JSONValue? = nil, status: ToolNodeStatus = .completed, output: String = "") -> ToolNodePayload {
        ToolNodePayload(callID: "call", toolName: name, args: args, status: status, output: output)
    }
    private func command(_ command: String, locale: String = "zh-Hans") -> ToolTranscriptPresentation {
        ToolTranscriptPresenter.presentation(for: tool("run_command", .object(["command": .string(command)])), locale: locale)
    }

    func testStructuredActionsUseTargetsAndBothLanguages() {
        let args: JSONValue = .object(["path": .string("src/CPackReader.cpp")])
        let read = tool("read_file", args)
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: read, locale: "zh-Hans").title, "读取 CPackReader.cpp")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: read, locale: "en").title, "Read CPackReader.cpp")
        let search = tool("grep", .object(["pattern": .string("ColladaConverter"), "path": .string("tools")]))
        let result = ToolTranscriptPresenter.presentation(for: search, locale: "zh-Hans")
        XCTAssertEqual(result.title, "搜索“ColladaConverter”")
        XCTAssertEqual(result.detail, "范围：tools")
        let dynamicPattern = tool("grep", .object(["pattern": .string("common.action.cancel %@")]))
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: dynamicPattern, locale: "zh-Hans").title, "搜索“common.action.cancel %@”")
        XCTAssertEqual(result.family, .search)
        XCTAssertEqual(result.systemImage, "magnifyingglass")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tool("edit_file", args), locale: "zh-Hans").title, "修改 CPackReader.cpp")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tool("list_files", .object(["path": .string("tools")])), locale: "zh-Hans").title, "列出 tools 目录")
    }

    func testReadRangeRequiresExplicitValidLineUnits() {
        let ranged = tool("read_file", .object(["path": .string("src/A.cpp"), "start_line": .integer(40), "end_line": .integer(90)]))
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: ranged, locale: "zh-Hans").title, "查看 A.cpp 第40–90行")
        let bytes = tool("read_file", .object(["path": .string("A.cpp"), "offset": .integer(40), "limit": .integer(90)]))
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: bytes, locale: "en").title, "Read A.cpp", "byte/unknown offsets must not become line claims")
    }

    func testLiteralShellSearchAndQuotedSpacePaths() {
        let grep = command("grep -n 'ColladaConverter' 'tools/Converter file.cpp'")
        XCTAssertEqual(grep.title, "搜索“ColladaConverter”")
        XCTAssertEqual(grep.detail, "范围：tools/Converter file.cpp")
        XCTAssertEqual(grep.outputKind, .terminal)
        let rg = command("rg --glob '*.cpp' -n \"ColladaConverter\" tools")
        XCTAssertEqual(rg.family, .search)
        XCTAssertEqual(rg.title, "搜索“ColladaConverter”")
        XCTAssertEqual(command("rg -e '-literal' -- 'a b.cpp'").title, "搜索“-literal”")
    }

    func testSedFindAndHexOnlyDescribeExplicitFacts() {
        XCTAssertEqual(command("sed -n '40,90p' 'src/CPack Reader.cpp'").title, "查看 CPack Reader.cpp 第40–90行")
        XCTAssertEqual(command("find tools -type f -name '*.cpp'").title, "查找 tools 下的文件")
        XCTAssertEqual(command("find tools").title, "查找 tools 下的条目", "find without -type f also returns directories")
        XCTAssertEqual(command("xxd -l 64 'data/model file.bin'").title, "查看文件头十六进制内容：model file.bin")
        XCTAssertEqual(command("xxd data/model.bin").title, "查看十六进制内容：model.bin")
        XCTAssertEqual(command("xxd -l 64 -s 16 data/model.bin").title, "查看十六进制内容：model.bin", "nonzero offset is not a file header")
    }

    func testComplexAndUncertainShellAlwaysFallsBack() {
        let uncertain = ["rg foo src | head", "grep foo src && sed -n '1p' src/A.cpp", "rg foo src; echo ok",
            "rg foo > result.txt", "rg $(cat query.txt) src", "rg \"$PATTERN\" src", "rg `cat query` src",
            "rg 'unclosed src", "rg foo\\ bar src", "rg foo *.cpp", "rg 'foo'bar src", "rg --unknown foo src",
            "rg -h needle src", "rg -E UTF-8 needle src", "rg -r replacement needle src", "grep --glob '*.cpp' needle src",
            "sed -n '40,90p;d' file", "sed -i 's/a/b/' file", "find tools -exec rm {} +", "find tools -delete",
            "xxd -r file", "xxd file output", "python script.py", "swift test", "rg foo src\nxxd file"]
        for shell in uncertain {
            let presentation = command(shell)
            XCTAssertEqual(presentation.title, "运行命令", shell)
            XCTAssertEqual(presentation.family, .terminal, shell)
            XCTAssertNotNil(presentation.detail, shell)
        }
    }

    func testSensitiveCommandValuesNeverAppearInHeaderOrPreview() {
        for shell in ["curl --token very-private https://example.com", "API_KEY=very-private rg foo .",
                      "curl -u user:very-private https://example.com", "curl https://user:very-private@example.com",
                      "rg 'sk-very-private' src", "curl -H 'Authorization: Bearer very-private' url", "curl --key very-private url",
                      "curl 'https://example.com?key=very-private'"] {
            let presentation = command(shell)
            XCTAssertEqual(presentation.title, "运行命令")
            XCTAssertFalse(presentation.compactLine.contains("very-private"), shell)
            XCTAssertEqual(presentation.detail, "命令预览已隐藏（含敏感参数）", shell)
        }
    }

    func testUnknownMissingMalformedAndLongArgumentsAreSafe() {
        for args: JSONValue? in [nil, .string("{broken json"), .object([:]), .object(["command": .array([])])] {
            XCTAssertEqual(ToolTranscriptPresenter.presentation(for: tool("run_command", args), locale: "en").title, "Run command")
        }
        for name in ["mcp__read_private_state", "web.custom_read", "unknown_read", "client_run"] {
            let unknown = ToolTranscriptPresenter.presentation(for: tool(name, .object(["password": .string("private-value")])), locale: "en")
            XCTAssertEqual(unknown.family, .other)
            XCTAssertEqual(unknown.title, "Use tool: \(name)")
            XCTAssertNil(unknown.detail)
        }
        let long = command("rg '" + String(repeating: "a", count: 20_000) + "' src")
        XCTAssertEqual(long.title, "运行命令")
        XCTAssertLessThanOrEqual(long.detail?.count ?? 999, 160)
    }

    func testStatusAndDiffEvidenceRemainIndependentOfAction() {
        let running = ToolTranscriptPresenter.presentation(for: tool("grep", .object(["pattern": .string("needle")]), status: .running), locale: "zh-Hans")
        XCTAssertEqual(running.statusTone, .running)
        XCTAssertEqual(running.statusText, "运行中")
        let failed = ToolTranscriptPresenter.presentation(for: tool("edit_file", .object(["path": .string("A.cpp")]), status: .failed, output: "not applied"), locale: "zh-Hans")
        XCTAssertEqual(failed.title, "修改 A.cpp")
        XCTAssertEqual(failed.statusTone, .failed)
        XCTAssertEqual(failed.statusText, "失败")
        XCTAssertNil(failed.changeSummary)
        let edited = tool("edit_file", .object(["path": .string("A.cpp")]), output: "--- a/A.cpp\n+++ b/A.cpp\n@@ -1 +1,2 @@\n-old\n+new\n+extra")
        XCTAssertEqual(ToolTranscriptPresenter.presentation(for: edited, locale: "en").changeSummary, "+2 -1")
        XCTAssertNil(ToolTranscriptPresenter.presentation(for: tool("edit_file", nil, output: "- ordinary bullet"), locale: "en").changeSummary)
        XCTAssertNil(ToolTranscriptPresenter.presentation(for: tool("edit_file", nil, output: "a@@b\n-not a diff\n+ordinary text"), locale: "en").changeSummary)
        let failedDiff = tool("edit_file", nil, status: .failed, output: "@@ -1 +1 @@\n-old\n+new")
        XCTAssertNil(ToolTranscriptPresenter.presentation(for: failedDiff, locale: "en").changeSummary, "failed edits must not claim applied changes")
    }

    func testThinkingAndActivityCatalogFallbacks() {
        XCTAssertEqual(ToolTranscriptText(locale: "en").thinkingTitle(streaming: false), "Thought")
        XCTAssertEqual(ToolTranscriptText(locale: "zh-Hans").thinkingTitle(streaming: true), "思考中…")
        XCTAssertEqual(ToolTranscriptText(locale: "unavailable-locale").text("run"), "Run command")
        let group = ToolGroup(id: "g", entries: [.tool(tool("read_file")), .tool(tool("run_command", .object(["command": .string("rg needle src")])) )])
        XCTAssertEqual(ToolTranscriptPresenter.groupPresentation(for: group, locale: "en").summary, "Read files, Run commands · 2 calls")
        XCTAssertEqual(ToolTranscriptPresenter.groupPresentation(for: group, locale: "zh-Hans").summary, "读取文件、运行命令 · 2 次调用")
    }
}
