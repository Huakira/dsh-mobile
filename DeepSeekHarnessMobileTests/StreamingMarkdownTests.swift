import XCTest
import UIKit
import SwiftUI
@testable import DeepSeekHarnessMobile

@MainActor
final class StreamingMarkdownTests: XCTestCase {
    private let sample = """
    # 标题 Heading

    这是一段包含 **加粗**、*斜体*、`行内代码` 和 [链接](https://example.com) 的文字。

    - 第一项
    - 第二项 **bold**
      - 嵌套项

    1. one
    2. two

    > 引用内容

    ```swift
    let x = 1
    print(x)
    ```

    | A | B |
    |---|---|
    | 1 | 2 |

    最后一段，未闭合的 **粗体 和 `代码
    """

    func testIncrementalMatchesFullRender() {
        let incremental = StreamingMarkdownDocument()
        for end in stride(from: 1, through: sample.count, by: 7) {
            incremental.update(text: String(sample.prefix(end)), tailFade: 0)
        }
        incremental.update(text: sample, tailFade: 0)
        let fresh = StreamingMarkdownDocument()
        fresh.update(text: sample, tailFade: 0)
        XCTAssertEqual(incremental.storage.string, fresh.storage.string)
        XCTAssertGreaterThan(fresh.storage.length, 0)
        XCTAssertFalse(fresh.storage.string.contains("**"))
        XCTAssertFalse(fresh.storage.string.contains("```"))
    }

    func testHeightGrowsMonotonically() {
        let document = StreamingMarkdownDocument()
        var last: CGFloat = 0
        for end in stride(from: 1, through: sample.count, by: 5) {
            document.update(text: String(sample.prefix(end)), tailFade: 0)
            let height = document.height(width: 360)
            XCTAssertGreaterThanOrEqual(height, last - 0.5)
            last = height
        }
    }

    func testRevealBufferDrainsAndHandsOver() {
        var buffer = StreamingRevealBuffer()
        func item(_ text: String, streaming: Bool) -> ConversationItem {
            ConversationItem(id: "a", kind: .assistant,
                title: streaming ? L10n.streamingAssistantTitle : "DeepSeek",
                text: text, isError: false, date: .now)
        }
        let full = String(repeating: "你好世界 ", count: 30)
        var now: CFTimeInterval = 100
        _ = buffer.smoothed([item("", streaming: true)], now: now, advance: true)
        now += 0.016
        var shown = buffer.smoothed([item(full, streaming: true)], now: now, advance: true)[0].text.count
        XCTAssertLessThan(shown, full.count)
        for _ in 0..<600 {
            now += 0.016
            let out = buffer.smoothed([item(full, streaming: false)], now: now, advance: true)[0]
            XCTAssertGreaterThanOrEqual(out.text.count, shown)
            shown = out.text.count
            if out.title != L10n.streamingAssistantTitle { break }
        }
        let final = buffer.smoothed([item(full, streaming: false)], now: now + 1, advance: true)[0]
        XCTAssertEqual(final.title, "DeepSeek")
        XCTAssertEqual(final.text, full)
        XCTAssertFalse(buffer.needsTick)
    }

    func testRenderSnapshotImage() throws {
        let document = StreamingMarkdownDocument()
        document.update(text: sample, tailFade: 0.6)
        let width: CGFloat = 360
        let height = document.height(width: width)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width - 4, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        document.storage.addLayoutManager(layout)
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let range = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 2, y: 15))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 2, y: 15))
        }
        document.storage.removeLayoutManager(layout)
        let path = ProcessInfo.processInfo.environment["STREAM_SNAPSHOT_PATH"] ?? "/tmp/streaming-markdown.png"
        try image.pngData()!.write(to: URL(fileURLWithPath: path))
    }

    func testCompareWithFinalRenderer() throws {
        let width: CGFloat = 358
        let document = StreamingMarkdownDocument()
        document.update(text: sample, tailFade: 0)
        let streamingText = document.height(width: width) - (15 + 26 + 7 + 15)

        let host = UIHostingController(rootView:
            MarkdownContent(sample).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        try image.pngData()!.write(to: URL(fileURLWithPath: "/tmp/final-markdown.png"))
        try "streamingText=\(streamingText) finalText=\(size.height)".write(
            toFile: "/tmp/streaming-vs-final.txt", atomically: true, encoding: .utf8)
        window.isHidden = true
    }

    /// End to end: bursty network chunks must reach the screen as a gradual,
    /// monotonic reveal with no large per-frame jumps.
    func testBurstyChunksRevealGraduallyThroughViewport() async throws {
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 362, height: 500)
        controller.view.layoutIfNeeded()
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.configure(
            sessionID: "bursty-reveal",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { ConversationViewportEntry(
                    id: $0.id, revision: $0.text.utf16.count,
                    streamingAssistant: .init(title: $0.title, text: $0.text)) }
            },
            bottomInset: 0
        )
        func publish(_ text: String) {
            timeline.publish([ConversationItem(
                id: "burst", kind: .assistant, title: L10n.streamingAssistantTitle,
                text: text, isError: false, date: Date(timeIntervalSince1970: 1))])
        }
        let collectionView = try XCTUnwrap(findDescendant(UICollectionView.self, in: controller.view))

        var text = ""
        var samples: [Int] = []
        var generator = SystemRandomNumberGenerator()
        // ~2.5s: a burst of 40-160 chars every 250ms, sampled every 16ms.
        let start = Date()
        var nextChunk = start
        while Date().timeIntervalSince(start) < 2.5 {
            if Date() >= nextChunk {
                text += String(repeating: "流式输出的一段文字 ", count: Int.random(in: 4...16, using: &generator))
                publish(text)
                nextChunk = Date().addingTimeInterval(0.25)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
            if let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? StreamingAssistantCell {
                samples.append(cell.renderedCharacterCount)
            }
        }
        XCTAssertGreaterThan(samples.count, 50)
        var maxStep = 0
        var stalledFrames = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "reveal must be monotonic")
            maxStep = max(maxStep, b - a)
            if b == a { stalledFrames += 1 }
        }
        let report = "frames=\(samples.count) maxStep=\(maxStep) stalled=\(stalledFrames) final=\(samples.last ?? 0)/\(text.count)"
        try report.write(toFile: "/tmp/streaming-frames.txt", atomically: true, encoding: .utf8)
        // A raw burst is up to ~160 chars; smoothing must keep single frames far below that.
        XCTAssertLessThan(maxStep, 40, report)
    }
}

private func findDescendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let match = findDescendant(type, in: subview) { return match }
    }
    return nil
}
