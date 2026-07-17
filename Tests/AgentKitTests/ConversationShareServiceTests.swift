import XCTest
@testable import AgentKit

@MainActor
final class ConversationShareServiceTests: XCTestCase {
    func testMarkdownKeepsTurnRolesAndOrdering() {
        let document = ConversationShareDocument(
            title: "Release notes",
            turns: [
                .init(userPrompt: "What changed?", assistantTranscript: "Fixed sharing."),
                .init(userPrompt: "Anything else?", assistantTranscript: "Added tests.")
            ]
        )

        XCTAssertEqual(
            document.markdown,
            """
            # Release notes

            ## 第 1 轮

            ### You

            What changed?

            ### Agent

            Fixed sharing.

            ## 第 2 轮

            ### You

            Anything else?

            ### Agent

            Added tests.

            """
        )
    }

    func testAllExportFormatsProduceShareableFiles() async throws {
        let document = ConversationShareDocument(
            title: "Export / Test",
            turns: [.init(userPrompt: "Hello", assistantTranscript: "World")]
        )

        for format in ConversationShareFormat.allCases {
            let url = try await ConversationShareService.export(document, as: format)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty)
            switch format {
            case .image:
                XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            case .pdf:
                XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
            case .markdown:
                XCTAssertEqual(String(decoding: data, as: UTF8.self), document.markdown)
            }
        }
    }

    func testConversationTurnBuildsStyledWebExport() async throws {
        let turn = ConversationTurn(
            id: "styled-turn",
            userPrompt: MessageNodePayload(role: .user, text: "Show a formatted answer"),
            blocks: [.text(
                id: "styled-answer",
                MessageNodePayload(
                    role: .assistant,
                    text: """
                    ## Result

                    | Name | Value |
                    | --- | --- |
                    | status | ready |

                    ```swift
                    let ready = true
                    ```
                    """
                )
            )],
            footer: nil,
            isLive: false
        )
        let document = ConversationShareService.document(for: turn, title: "Styled export")
        XCTAssertNotNil(document.webDocument)

        let imageURL = try await ConversationShareService.export(document, as: .image)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let imageData = try Data(contentsOf: imageURL)
        XCTAssertEqual(Array(imageData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertGreaterThan(imageData.count, 10_000)
    }
}
