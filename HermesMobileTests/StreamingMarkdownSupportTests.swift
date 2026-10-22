import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class StreamingMarkdownBlockSplitterTests: XCTestCase {
    func testCompletedFenceSealsStableChunk() {
        let stableBody = String(repeating: "A", count: 6_100)
        let text = """
        \(stableBody)
        ```swift
        let answer = 42
        ```
        Still streaming
        """

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.count, 1)
        XCTAssertTrue(segments.stableChunks[0].text.contains(stableBody))
        XCTAssertTrue(segments.activeMarkdown.contains("Still streaming"))
    }

    /// A longer or different fence can hold ``` lines (Markdown about Markdown); only the
    /// matching closing run ends it, so a chunk never seals inside the outer fence.
    func testNestedFenceSealsOnlyAfterItsOwnClosingRun() {
        let prose = String(repeating: "Line of prose.\n", count: 400)
        for (open, close) in [("````markdown", "````"), ("~~~markdown", "~~~")] {
            let fence = "\(open)\n```swift\nlet a = 1\n\nlet b = 2\n```\n\(close)\n"
            let segments = StreamingMarkdownBlockSplitter.split(prose + fence + "After\n")

            XCTAssertEqual(segments.stableChunks.map(\.text), [prose + fence], open)
            XCTAssertEqual(segments.activeMarkdown, "After\n", open)
        }
    }

    func testHeadingBoundaryCanSealWithoutFence() {
        let prose = String(repeating: "Line of prose.\n", count: 500)
        let text = prose + "## Next section\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertFalse(segments.stableChunks.isEmpty)
        XCTAssertTrue(segments.activeMarkdown.contains("More text"))
    }

    /// The seal threshold counts UTF-8 bytes: 2,600 characters of Japanese
    /// prose are about 7,300 bytes, so they seal at the heading.
    func testStableChunkThresholdCountsUTF8Bytes() {
        let prose = String(repeating: "日本語の文章です。\n", count: 260)
        XCTAssertLessThan(prose.count, StreamingMarkdownBlockSplitter.stableChunkTargetUTF8Count)
        let text = prose + "## 次の節\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.map(\.text), [prose + "## 次の節\n"])
        XCTAssertEqual(segments.activeMarkdown, "More text")
    }

    /// Fence lines are recognised after trimming surrounding whitespace, so
    /// blank lines inside an indented fence never seal it half-open.
    func testIndentedFenceWithTrailingWhitespaceKeepsItsBody() {
        let fence = "   ```swift \t\n" + String(repeating: "let x = 1\n\n", count: 700) + "\t```\t\n"
        let text = fence + "tail"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.map(\.text), [fence])
        XCTAssertEqual(segments.activeMarkdown, "tail")
    }
}

final class MarkdownPreviewChunkerTests: XCTestCase {
    /// About 60 KB of sections, each a heading, a paragraph, and a fenced code
    /// block, shaped like a long CHANGELOG. Shared with the file preview view model test.
    static func largeDocument() -> String {
        (1...120).map { index in
            """
            ## Release \(index)

            \(String(repeating: "Fixed a stream reattach edge case after a tunnel idle timeout. ", count: 6))

            ```swift
            let cursor = stream.lastEventID // \(index)

            try await client.resume(from: cursor)
            ```

            """
        }.joined() + "Final paragraph.\n"
    }

    func testLargeMarkdownWithoutSafeBoundaryStaysOneDocument() {
        let oneParagraph = String(repeating: "word ", count: 2_000)

        XCTAssertNil(MarkdownPreviewChunker.chunks(for: oneParagraph))
    }

    func testLargeMarkdownSplitsLosslesslyWithoutBreakingFences() throws {
        let document = Self.largeDocument()
        let chunks = try XCTUnwrap(MarkdownPreviewChunker.chunks(for: document))

        XCTAssertGreaterThanOrEqual(chunks.count, 8)
        XCTAssertEqual(chunks.map(\.text).joined(), document)
        XCTAssertEqual(chunks.map(\.id), Array(chunks.indices))
        XCTAssertEqual(chunks.first?.topSpacing, 0)
        for chunk in chunks {
            let fences = chunk.text.split(separator: "\n").filter { $0.hasPrefix("```") }
            XCTAssertTrue(fences.count.isMultiple(of: 2), "Chunk \(chunk.id) splits a code fence.")
        }
    }
}

final class StreamingReasoningTextStateTests: XCTestCase {
    func testLargePrefixStreamReconstructsExactlyAndPreservesStableChunks() {
        let paragraph = "Hermes inspects the workspace before choosing the next step.\n\n"
        let fullText = String(String(repeating: paragraph, count: 1_500).prefix(80_000))
        var state = StreamingReasoningTextState()
        var previousChunks: [StreamingReasoningChunk] = []

        for characterCount in stride(from: 2_000, through: 80_000, by: 2_000) {
            let end = fullText.index(fullText.startIndex, offsetBy: characterCount)
            state.update(with: String(fullText[..<end]))

            XCTAssertEqual(Array(state.stableChunks.prefix(previousChunks.count)), previousChunks)
            XCTAssertLessThanOrEqual(
                state.activeTail.count,
                StreamingReasoningTextState.maximumActiveTailCharacterCount
            )
            previousChunks = state.stableChunks
        }

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(fullText.utf8))
        XCTAssertFalse(state.stableChunks.isEmpty)
    }

    func testLongUnbrokenTextUsesBoundedGraphemeSafeChunks() {
        let text = String(repeating: "x", count: 5_000)
        let state = StreamingReasoningTextState(text: text)

        XCTAssertTrue(state.stableChunks.allSatisfy {
            $0.text.count == StreamingReasoningTextState.targetChunkCharacterCount
        })
        XCTAssertLessThanOrEqual(
            state.activeTail.count,
            StreamingReasoningTextState.maximumActiveTailCharacterCount
        )
        XCTAssertEqual(state.reconstructedText, text)
    }

    func testEmojiAndMultiScalarGraphemesStayIntact() {
        let graphemes = ["👨🏽‍💻", "e\u{301}", "🇺🇸", "🫶🏻"]
        let text = String(repeating: graphemes.joined(), count: 800)
        let state = StreamingReasoningTextState(text: text)

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(text.utf8))
        XCTAssertTrue(state.stableChunks.allSatisfy { chunk in
            chunk.text.allSatisfy { graphemes.contains(String($0)) }
        })
    }

    func testPrefixAppendCanExtendTheFinalGrapheme() {
        let initialText = String(repeating: "x", count: 2_000) + "e"
        let extendedText = initialText + "\u{301}"
        var state = StreamingReasoningTextState(text: initialText)

        state.update(with: extendedText)

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(extendedText.utf8))
        XCTAssertTrue(state.activeTail.hasSuffix("e\u{301}"))
    }

    func testNonPrefixReplacementDropsPreviousChunks() {
        let original = String(repeating: "Original paragraph.\n\n", count: 200)
        let replacement = String(repeating: "Replacement paragraph.\n\n", count: 200)
        var state = StreamingReasoningTextState(text: original)

        state.update(with: replacement)

        XCTAssertEqual(state.stableChunks.first?.id, 0)
        XCTAssertTrue(state.stableChunks.first?.text.hasPrefix("Replacement") == true)
        XCTAssertFalse(state.reconstructedText.contains("Original"))
        XCTAssertEqual(state.reconstructedText, replacement)
    }

    func testTextStorageUpdateAppendsOnlyNewSuffix() {
        let rendered = String(repeating: "Long paragraph without breaks. ", count: 100)
        let newText = rendered + "Still streaming."

        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: rendered,
                newText: newText
            ),
            .append("Still streaming.")
        )
    }

    func testTextStorageUpdateReplacesNonPrefixContent() {
        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: "Old stream",
                newText: "Replacement stream"
            ),
            .replace("Replacement stream")
        )
    }

    func testTextStorageUpdatePreservesCrossUpdateGraphemeBytes() {
        let rendered = "Planning e"
        let newText = rendered + "\u{301}"

        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: rendered,
                newText: newText
            ),
            .append("\u{301}")
        )
    }
}

/// Width resolution for chat markdown table cells (issue #233). The layout
/// itself needs a render pass to verify; this covers the pure clamp that
/// decides the wrap width the cell height is measured at.
final class TableCellWidthCapTests: XCTestCase {
    private let minWidth: CGFloat = 96
    private let maxWidth: CGFloat = 260

    func testIdealWidthAboveMaxClampsToMax() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 1_200, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, maxWidth)
    }

    func testProposedColumnWidthOverridesIdealWidth() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: 200, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, 200)
    }
}

/// A live thinking body past the row window stays scrollable for the whole
/// turn: it follows the newest line until the reader scrolls it, keeps the
/// reader's position while text keeps arriving, and follows again once the
/// reader scrolls back to the newest line.
@MainActor
final class LiveReasoningScrollTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        suiteName = "LiveReasoningScrollTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(ThinkingAndToolCards.expanded.rawValue, forKey: ChatTranscriptDisplaySettings.thinkingAndToolCardsKey)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLiveBodyFollowsTheNewestLineWhileUntouched() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertEqual(textView.bounds.height, TranscriptLogRowMetrics.bodyWindowHeight, accuracy: 0.5)
        XCTAssertEqual(textView.contentOffset.y, tailOffset(of: textView), accuracy: 0.5)

        await update(host, lines: 1...120, textView: textView)

        XCTAssertGreaterThan(tailOffset(of: textView), 0)
        XCTAssertEqual(textView.contentOffset.y, tailOffset(of: textView), accuracy: 0.5)
    }

    func testLiveBodyReceivesTouches() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)

        var blockers: [String] = []
        var view: UIView? = textView
        while let current = view, current !== host.view {
            if !current.isUserInteractionEnabled {
                blockers.append(String(describing: type(of: current)))
            }
            view = current.superview
        }

        XCTAssertNotNil(view, "the live body must be hosted in the row")
        XCTAssertEqual(blockers, [], "the live body and its hosts must take the drag")
    }

    func testDraggedLiveBodyKeepsTheReadersPositionWhileTextArrives() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)

        drag(textView, to: 0)
        await update(host, lines: 1...120, textView: textView)

        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.5, "new thinking must not move the reader")
        XCTAssertGreaterThan(tailOffset(of: textView), 0)
    }

    func testDraggingBackToTheNewestLineFollowsAgain() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)
        drag(textView, to: 0)
        await update(host, lines: 1...100, textView: textView)

        drag(textView, to: tailOffset(of: textView))
        await update(host, lines: 1...140, textView: textView)

        XCTAssertEqual(textView.contentOffset.y, tailOffset(of: textView), accuracy: 0.5)
    }

    func testFailedAccessibilityScrollPreservesTailFollowing() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)
        let offsetBefore = textView.contentOffset.y

        // This vertically scrolling body has no horizontal page to visit.
        XCTAssertFalse(textView.accessibilityScroll(.left))
        XCTAssertEqual(textView.contentOffset.y, offsetBefore, accuracy: 0.5)
        await update(host, lines: 1...120, textView: textView)

        XCTAssertEqual(textView.contentOffset.y, tailOffset(of: textView), accuracy: 0.5)
    }

    func testFailedAccessibilityScrollPreservesTheReadersPosition() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)
        let readerOffset = tailOffset(of: textView) / 2
        drag(textView, to: readerOffset)

        XCTAssertFalse(textView.accessibilityScroll(.left))
        XCTAssertEqual(textView.contentOffset.y, readerOffset, accuracy: 0.5)
        await update(host, lines: 1...120, textView: textView)

        XCTAssertEqual(textView.contentOffset.y, readerOffset, accuracy: 0.5)
    }

    func testScrollingAnimationDelegatePolicyAtTailResumesFollowing() async throws {
        let (host, textView) = try await hostLiveReasoning(lines: 1...80)
        drag(textView, to: 0)
        await update(host, lines: 1...100, textView: textView)

        // Exercise the completion policy directly, not a VoiceOver action.
        textView.setContentOffset(CGPoint(x: 0, y: tailOffset(of: textView)), animated: false)
        textView.delegate?.scrollViewDidEndScrollingAnimation?(textView)
        await update(host, lines: 1...120, textView: textView)

        XCTAssertEqual(textView.contentOffset.y, tailOffset(of: textView), accuracy: 0.5)
    }

    // MARK: - Helpers

    private func hostLiveReasoning(
        lines: ClosedRange<Int>
    ) async throws -> (LiveReasoningHostingController, UITextView) {
        let host = LiveReasoningHostingController(rootView: LiveReasoningHarness(text: text(lines), defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window

        await settle(host)
        let textView = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UITextView }.first)
        await settle(host, textView: textView)
        return (host, textView)
    }

    private func update(
        _ host: LiveReasoningHostingController,
        lines: ClosedRange<Int>,
        textView: UITextView
    ) async {
        host.rootView = LiveReasoningHarness(text: text(lines), defaults: defaults)
        await settle(host, textView: textView)
    }

    /// Waits for a hosting layout that has the requested storage and its
    /// measured scroll extent, rather than guessing how many actor turns the
    /// SwiftUI onChange/updateUIView sequence needs.
    private func settle(_ host: LiveReasoningHostingController, textView: UITextView? = nil) async {
        let ready = expectation(description: "requested reasoning text has completed layout")
        let expectedText = host.rootView.text
        var completed = false
        host.didLayout = { [weak host] in
            guard !completed, let host,
                  let body = textView ?? self.descendants(of: host.view).compactMap({ $0 as? UITextView }).first,
                  body.window != nil, body.text == expectedText,
                  body.bounds.width > 0,
                  abs(body.bounds.height - TranscriptLogRowMetrics.bodyWindowHeight) < 0.5
            else { return }
            body.layoutIfNeeded()
            let measured = body.sizeThatFits(CGSize(width: body.bounds.width, height: .greatestFiniteMagnitude))
            guard body.contentSize.height > body.bounds.height,
                  abs(body.contentSize.height - measured.height) < 0.5 else { return }
            completed = true
            ready.fulfill()
        }
        let storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main
        ) { [weak host] _ in
            MainActor.assumeIsolated {
                host?.view.setNeedsLayout()
            }
        }
        defer {
            host.didLayout = nil
            NotificationCenter.default.removeObserver(storageObserver)
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [ready], timeout: 5)
    }

    /// Exercises the delegate policy with a supplied offset; this helper is
    /// not a synthesized finger gesture or evidence that UIKit delivered one.
    private func drag(_ textView: UITextView, to offsetY: CGFloat) {
        textView.delegate?.scrollViewWillBeginDragging?(textView)
        textView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
        textView.delegate?.scrollViewDidEndDragging?(textView, willDecelerate: false)
    }

    private func tailOffset(of textView: UITextView) -> CGFloat {
        max(0, textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
    }

    private func text(_ lines: ClosedRange<Int>) -> String {
        lines.map { "Thinking line \($0)" }.joined(separator: "\n")
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class LiveReasoningHostingController: UIHostingController<LiveReasoningHarness> {
    var didLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        didLayout?()
    }
}

private struct LiveReasoningHarness: View {
    let text: String
    let defaults: UserDefaults

    var body: some View {
        ReasoningBlockView(text: text, liveStreamID: "stream-1")
            .defaultAppStorage(defaults)
            .frame(width: 390)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
