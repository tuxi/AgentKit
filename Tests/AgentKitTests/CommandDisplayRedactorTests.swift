#if os(macOS)
import XCTest
@testable import AgentKit

final class CommandDisplayRedactorTests: XCTestCase {
    func testDevelopmentCommandsAndSearchTermsRemainUnchanged() {
        for command in [
            "rg \"beforeTokens\" Sources", "rg 'token secret password cookie authorization' Sources",
            "rg -u token Sources", "rg 'TOKEN=example' Sources", "rg TOKEN=example Sources",
            "CLANG_MODULE_CACHE_PATH=/tmp/module-cache swift test", "GOCACHE=/tmp/go-cache go test ./...",
            "MAX_TOKENS=8192 TOKENIZERS_PARALLELISM=false swift test", "git show Sources/TokenParser.swift",
            "git commit -m 'Fix token budget and password field parsing'", "git fetch git@github.com:example/repo.git",
            "API_KEY=$OPENAI_API_KEY swift test", "curl --token \"${API_TOKEN}\" https://example.test",
            "curl -H 'Authorization: Bearer $API_TOKEN' https://example.test"
        ] {
            XCTAssertEqual(CommandDisplayRedactor.redact(command), command, command)
            XCTAssertFalse(MacToolPresentation.shouldRedactCommand(command), command)
        }
    }
    func testCredentialsAreMaskedWithoutLosingCommandStructure() {
        let cases: [(String, String)] = [
            ("curl --token private-value https://example.test", "curl --token •••••• https://example.test"),
            ("curl --api-key='private value' https://example.test", "curl --api-key='••••••' https://example.test"),
            ("API_KEY=private-value swift test", "API_KEY=•••••• swift test"),
            ("GOCACHE=/tmp/cache OPENAI_API_KEY='private value' swift test", "GOCACHE=/tmp/cache OPENAI_API_KEY='••••••' swift test"),
            ("export API_TOKEN=private-value", "export API_TOKEN=••••••"),
            ("curl -H 'Authorization: Bearer private-value' https://example.test", "curl -H 'Authorization: Bearer ••••••' https://example.test"),
            ("curl --header=\"X-Api-Key: private-value\" https://example.test", "curl --header=\"X-Api-Key: ••••••\" https://example.test"),
            ("curl -H'Authorization: Basic private-value' https://example.test", "curl -H'Authorization: Basic ••••••' https://example.test"),
            ("curl -H 'Cookie: session=private-value; theme=dark' https://example.test", "curl -H 'Cookie: ••••••' https://example.test"),
            ("curl -u user:private-value https://example.test", "curl -u •••••• https://example.test"),
            ("curl --user=user:private-value https://example.test", "curl --user=•••••• https://example.test"),
            ("curl -uuser:private-value https://example.test", "curl -u•••••• https://example.test"),
            ("curl 'https://user:private-value@example.test/path?token=second-private&q=swift'", "curl 'https://••••••@example.test/path?token=••••••&q=swift'"),
            ("curl -d '{\"password\":\"private-value\",\"name\":\"测试\"}' https://example.test", "curl -d '{\"password\":\"••••••\",\"name\":\"测试\"}' https://example.test")
        ]
        for (command, expected) in cases {
            let redacted = CommandDisplayRedactor.redact(command)
            XCTAssertEqual(redacted, expected)
            XCTAssertEqual(CommandDisplayRedactor.redact(redacted), redacted, "redaction is idempotent")
            XCTAssertFalse(redacted.contains("private-value"))
        }
    }
    func testUnicodeLongMultilineAndEscapedCredentialValues() {
        let long = String(repeating: "printf '普通 token 输出'\n", count: 600)
        let command = long + "curl --password \"密钥\\\"含空格\" --token another-value https://example.test"
        let redacted = CommandDisplayRedactor.redact(command)
        XCTAssertTrue(redacted.hasPrefix(long))
        XCTAssertTrue(redacted.hasSuffix("curl --password \"••••••\" --token •••••• https://example.test"))
        XCTAssertFalse(redacted.contains("密钥"))
        let key = "rg 'sk-very-private' Sources"
        XCTAssertEqual(CommandDisplayRedactor.redact(key), "rg '••••••' Sources")
        XCTAssertEqual(CommandDisplayRedactor.redact("curl --token; echo safe"), "curl --token; echo safe", "missing values do not consume the next command")
    }
    @MainActor
    func testWebAndNativeCommandCopiesUseTheSameMaskedText() throws {
        let original = "curl -H 'Authorization: Bearer private-value' https://example.test"
        let safe = "curl -H 'Authorization: Bearer ••••••' https://example.test"
        let tool = ToolNodePayload(callID: "cmd", toolName: "run_command", args: .object(["command": .string(original)]), status: .completed)
        let turn = ConversationTurn(id: "turn", userPrompt: nil, blocks: [.toolGroup(.init(id: "g", entries: [.tool(tool)]))], footer: nil, isLive: false)
        let registry = ConversationWebActionRegistry(); registry.beginRevision()
        let document = ConversationWebDocumentBuilder.build(snapshot: .init(timeline: [], turns: [turn]), conversationID: "c", registerAction: registry.register)
        registry.finishRevision()
        let webTool = try XCTUnwrap(document.turns.first?.blocks.first?.tools.first)
        XCTAssertEqual(webTool.command, safe)
        XCTAssertEqual(webTool.input, safe)
        XCTAssertEqual(webTool.inputIsRedacted, true)
        guard case .transcript(_, .copyBlock(let text))? = registry.resolve(try XCTUnwrap(webTool.copyInputActionID)) else { return XCTFail("missing command copy action") }
        XCTAssertEqual(text, safe)
        let native = TurnTranscriptBuilder.build(turn: turn, state: .init(expandedToolIDs: ["group:g", "cmd"]))
        XCTAssertFalse(native.attributedString.string.contains("private-value"))
        XCTAssertTrue(native.actions.values.contains(.copyBlock(text: safe)))
        XCTAssertEqual(MacToolPresentation.input(for: tool), original, "display masking must not rewrite execution data")
    }
}
#endif
