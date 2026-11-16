//
//  ToolPayloadPerformanceTests.swift
//  AgentKitTests
//
//  P1-F.2 regression coverage: expanding a failed `ui_preview` tool group must
//  not synchronously pretty-print or lay out its multi-megabyte input/output.
//  The expanded row shows a bounded summary first and formats the payload only
//  on demand, off the main actor.
//

import Foundation
import SwiftUI
import XCTest
@testable import AgentKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class ToolPayloadPerformanceTests: XCTestCase {
    private func largeHTML(approximateBytes: Int) -> String {
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;font-family:-apple-system}
        .card{display:flex;padding:24px;border-radius:18px}
        </style></head><body><main id="root">
        """
        var index = 0
        while html.utf8.count < approximateBytes {
            html += """
            <section class="card" data-index="\(index)">
              <h2>Section \(index)</h2>
              <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>
            </section>
            """
            index += 1
        }
        html += "</main></body></html>"
        return html
    }

    private func largeFailedPreviewTool(
        htmlBytes: Int = 5_000_000,
        structuredError: JSONValue? = nil
    ) -> ToolNodePayload {
        let html = largeHTML(approximateBytes: htmlBytes)
        let args: JSONValue = .object([
            "artifact_key": .string("dreamlog-duo-home"),
            "kind": .string("interactive_html"),
            "title": .string("DreamLog Duo creation home"),
            "target": .string("duo_folded"),
            "html": .string(html),
            "fallback_asset": .object([
                "asset_id": .string("asset_dreamlog_fallback"),
                "relative_path": .string("previews/dreamlog-fallback.png"),
                "mime_type": .string("image/png"),
            ]),
        ])
        let output = "ui_preview failed: preview_digest_mismatch\nrequest:\n" + html
        return ToolNodePayload(
            callID: "call_ui_preview_failed",
            toolName: "ui_preview",
            args: args,
            status: .failed,
            output: output,
            structuredOutput: structuredError,
            exitCode: 1,
            elapsedMs: 42
        )
    }

    func testLargeFailedPreviewSummaryStaysBounded() {
        let tool = largeFailedPreviewTool()
        let start = ContinuousClock().now
        let summary = ToolPayloadSummaryBuilder.make(tool: tool)
        let elapsed = ContinuousClock().now - start

        XCTAssertLessThan(elapsed, .seconds(0.5))
        let input = try? XCTUnwrap(summary.input)
        let output = try? XCTUnwrap(summary.output)
        XCTAssertGreaterThan(input?.byteCount ?? 0, 4 * 1024 * 1024)
        XCTAssertGreaterThan(output?.byteCount ?? 0, 4 * 1024 * 1024)
        XCTAssertLessThan(input?.previewText.utf8.count ?? .max, 1_024)
        XCTAssertLessThan(output?.previewText.utf8.count ?? .max, 1_024)
        XCTAssertEqual(
            input?.topLevelKeys,
            ["artifact_key", "fallback_asset", "html", "kind", "target", "title"]
        )
    }

    @MainActor
    func testExpandedLargeFailedPreviewLayoutStaysUnderOneSecond() {
        warmUpLayout()
        let tool = largeFailedPreviewTool()
        let group = ToolGroup(id: "group_probe", tools: [tool])
        let state = TranscriptDocumentState(expandedToolIDs: [
            "group_probe", tool.callID,
        ])
        let view = ToolCallGroupView(
            group: group,
            documentState: .constant(state),
            onAction: { _ in }
        )
        let elapsed = layoutDuration(of: view, size: CGSize(width: 390, height: 640))
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "expanding a failed ui_preview group must not lay out the whole payload"
        )
    }

    @MainActor
    func testExpandedDetailWithSummaryDoesNotRenderFullPayload() {
        warmUpLayout()
        let tool = largeFailedPreviewTool(htmlBytes: 2_000_000)
        let summary = ToolPayloadSummaryBuilder.make(tool: tool)
        let input = summary.input!
        let model = ToolPayloadDetailModel()
        let view = ToolPayloadDetailSection(
            title: "input",
            kind: .inputJSON,
            summary: input,
            tool: tool,
            model: model,
            isExpanded: .constant(false),
            maxHeight: 96,
            horizontalScroll: true
        )
        let elapsed = layoutDuration(of: view, size: CGSize(width: 390, height: 160))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testFormatterTruncatesAndCacheReusesOneFormat() async throws {
        let tool = largeFailedPreviewTool(htmlBytes: 2_000_000)
        let counter = FormatCounter()
        let key = ToolPayloadTextCache.Key(
            callID: tool.callID,
            kind: .inputJSON,
            limit: ToolPayloadDetailMetrics.transcriptPreviewBytes
        )

        let start = ContinuousClock().now
        let first = await ToolPayloadTextCache.shared.payload(for: key) {
            counter.increment()
            return ToolPayloadFormatter.make(
                tool: tool,
                kind: .inputJSON,
                limit: ToolPayloadDetailMetrics.transcriptPreviewBytes
            )
        }
        let elapsed = ContinuousClock().now - start
        let second = await ToolPayloadTextCache.shared.payload(for: key) {
            counter.increment()
            return ToolPayloadFormatter.make(
                tool: tool,
                kind: .inputJSON,
                limit: ToolPayloadDetailMetrics.transcriptPreviewBytes
            )
        }

        XCTAssertLessThan(elapsed, .seconds(1))
        let payload = try XCTUnwrap(first)
        XCTAssertTrue(payload.isTruncated)
        XCTAssertGreaterThan(payload.totalByteCount, 2_000_000)
        XCTAssertLessThanOrEqual(
            payload.text.utf8.count,
            ToolPayloadDetailMetrics.transcriptPreviewBytes + 4
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(counter.value, 1, "identical payloads must not be formatted twice")
    }

    func testFailureSummaryShowsCodeMessageAndSizeWithoutFullPayload() throws {
        let tool = largeFailedPreviewTool(
            htmlBytes: 3_000_000,
            structuredError: .object([
                "error": .object([
                    "code": .string("preview_digest_mismatch"),
                    "message": .string("Viewer digest did not match."),
                ]),
            ])
        )
        let summary = ToolPayloadSummaryBuilder.make(tool: tool)
        let failure = try XCTUnwrap(summary.failure)
        XCTAssertEqual(failure.code, "preview_digest_mismatch")
        XCTAssertEqual(failure.message, "Viewer digest did not match.")
        XCTAssertGreaterThan(failure.byteCount, 3_000_000)
        XCTAssertLessThan(failure.label.utf8.count, 300)
        XCTAssertFalse(failure.label.contains("<section"))

        let firstLine = ToolPayloadSummaryBuilder.make(
            tool: largeFailedPreviewTool(htmlBytes: 1_000_000)
        ).failure
        XCTAssertNil(firstLine?.code)
        XCTAssertEqual(firstLine?.message, "ui_preview failed: preview_digest_mismatch")
    }

    @MainActor
    func testPreparationDoesNotFormatPayload() async throws {
        let tool = largeFailedPreviewTool(htmlBytes: 3_000_000)
        let model = ToolPayloadDetailModel()
        model.prepare(tool: tool)
        try await waitForSummary(model)

        XCTAssertNotNil(model.summary)
        XCTAssertTrue(
            model.payloads.isEmpty,
            "expanding must not format the full payload"
        )
        XCTAssertTrue(model.loadingKinds.isEmpty)
    }

    @MainActor
    func testRepeatedExpandCollapseAndSteadyLayoutStayBounded() {
        warmUpLayout()
        let tool = largeFailedPreviewTool(htmlBytes: 5_000_000)
        let group = ToolGroup(id: "group_probe", tools: [tool])
        var durations: [Duration] = []

        for expanded in [true, false, true, false, true, false, true, false, true, false] {
            let state = TranscriptDocumentState(expandedToolIDs: expanded ? [
                "group_probe", tool.callID,
            ] : [])
            let view = ToolCallGroupView(
                group: group,
                documentState: .constant(state),
                onAction: { _ in }
            )
            durations.append(layoutDuration(of: view, size: CGSize(width: 390, height: 640)))
        }

        // Repeated layout passes approximate body/layout churn while scrolling.
        for _ in 0..<20 {
            let state = TranscriptDocumentState(expandedToolIDs: [
                "group_probe", tool.callID,
            ])
            let view = ToolCallGroupView(
                group: group,
                documentState: .constant(state),
                onAction: { _ in }
            )
            durations.append(layoutDuration(of: view, size: CGSize(width: 390, height: 640)))
        }

        XCTAssertLessThan(durations.max() ?? .zero, .seconds(1))
        XCTAssertLessThan(durations.reduce(Duration.zero, +), .seconds(10))
    }

    @MainActor
    private func waitForSummary(_ model: ToolPayloadDetailModel) async throws {
        let deadline = ContinuousClock().now + .seconds(2)
        while model.summary == nil, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(model.summary)
    }

    @MainActor
    private func warmUpLayout() {
        _ = layoutDuration(
            of: Text("warm-up"),
            size: CGSize(width: 32, height: 32)
        )
    }

    @MainActor
    private func layoutDuration<V: View>(of view: V, size: CGSize) -> Duration {
        let start = ContinuousClock().now
        #if canImport(UIKit)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        window.isHidden = true
        #else
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        host.layoutSubtreeIfNeeded()
        #endif
        return ContinuousClock().now - start
    }
}

private final class FormatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
