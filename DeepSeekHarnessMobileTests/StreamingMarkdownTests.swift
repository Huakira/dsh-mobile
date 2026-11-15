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
}
