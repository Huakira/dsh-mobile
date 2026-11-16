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

    private func assistant(_ id: String, _ text: String, streaming: Bool) -> ConversationItem {
        ConversationItem(id: id, kind: .assistant,
            title: streaming ? L10n.streamingAssistantTitle : "DeepSeek",
            text: text, isError: false, date: Date(timeIntervalSince1970: 1))
    }

    /// 真机录屏 2026-11-15：首个网络块 >160 字时整块一次弹出。只有刚打开会话
    /// （历史中途）才允许跳过揭示；live 视口里新出现的流式行必须从头揭示。
    func testFirstLargeLiveChunkIsRevealedGradually() {
        let chunk = String(repeating: "金价表格的一行内容 ", count: 40)
        var opened = StreamingRevealBuffer()
        let reopened = opened.smoothed([assistant("live-a1-text-delta-0", chunk, streaming: true)],
            now: 100, advance: true, isLive: false)[0]
        XCTAssertEqual(reopened.text, chunk, "刚打开会话的长流式行不重放")

        var live = StreamingRevealBuffer()
        let first = live.smoothed([assistant("live-a1-text-delta-0", chunk, streaming: true)],
            now: 100, advance: true, isLive: true)[0]
        XCTAssertLessThan(first.text.count, 40, "live 视口不得整块弹出首个大块")
        XCTAssertTrue(live.needsTick)
    }

    /// 真机录屏 2026-11-15：assistant-stream-v1 的 live 行在流结束时被删除，
    /// 最终消息以新 id 插入；揭示进度必须延续到新 id，剩余文字不得一次性弹出。
    func testFinalMessageUnderNewIDContinuesTheLiveReveal() {
        let full = String(repeating: "近期走势：11 月 5 日冲到 4146 美元。", count: 20)
        let streamed = String(full.prefix(200))
        var buffer = StreamingRevealBuffer()
        var now: CFTimeInterval = 100
        var shown = buffer.smoothed([assistant("live-a1-text-delta-0", streamed, streaming: true)],
            now: now, advance: true, isLive: true)[0]
        for _ in 0..<30 {
            now += 0.016
            shown = buffer.smoothed([assistant("live-a1-text-delta-0", streamed, streaming: true)],
                now: now, advance: true, isLive: true)[0]
        }
        let onScreen = shown.text.count
        XCTAssertGreaterThan(onScreen, 0)

        now += 0.016
        let handedOver = buffer.smoothed([assistant("s1-12", full, streaming: false)],
            now: now, advance: true, isLive: true)[0]
        XCTAssertEqual(handedOver.title, L10n.streamingAssistantTitle, "新 id 的最终消息应继续流式呈现")
        XCTAssertGreaterThanOrEqual(handedOver.text.count, onScreen)
        XCTAssertLessThan(handedOver.text.count, full.count, "剩余文字不得一次性弹出")
        XCTAssertTrue(full.hasPrefix(handedOver.text))

        var last = handedOver.text.count
        var final = handedOver
        for _ in 0..<600 where final.title == L10n.streamingAssistantTitle {
            now += 0.016
            final = buffer.smoothed([assistant("s1-12", full, streaming: false)],
                now: now, advance: true, isLive: true)[0]
            XCTAssertGreaterThanOrEqual(final.text.count, last)
            last = final.text.count
        }
        XCTAssertEqual(final.title, "DeepSeek")
        XCTAssertEqual(final.text, full)
    }

    /// 最终消息在 live 行一个字都还没显示时就到达（插入提交动画期间揭示暂停），
    /// 仍须按原文前缀接力，而不是由最终渲染器整块弹出。
    func testFinalBeforeAnyRevealStillContinuesFromLiveRow() {
        let full = String(repeating: "金价表格的一行内容 ", count: 60)
        var buffer = StreamingRevealBuffer()
        let live = buffer.smoothed([assistant("live-a1-text-delta-0", String(full.prefix(320)), streaming: true)],
            now: 100, advance: true, isLive: true)[0]
        XCTAssertEqual(live.text, "")
        let handedOver = buffer.smoothed([assistant("s1-12", full, streaming: false)],
            now: 100.016, advance: true, isLive: true)[0]
        XCTAssertEqual(handedOver.title, L10n.streamingAssistantTitle)
        XCTAssertLessThan(handedOver.text.count, full.count)
    }

    /// 不相干的最终消息（文字不以 live 行已显示内容开头）不得接管进度。
    func testUnrelatedFinalMessageDoesNotAdoptLiveProgress() {
        var buffer = StreamingRevealBuffer()
        var now: CFTimeInterval = 100
        for _ in 0..<20 {
            _ = buffer.smoothed([assistant("live-a1-text-delta-0", "流式回复的前半段文字", streaming: true)],
                now: now, advance: true, isLive: true)
            now += 0.016
        }
        let other = buffer.smoothed([assistant("s1-30", "完全不同的另一条回复", streaming: false)],
            now: now, advance: true, isLive: true)[0]
        XCTAssertEqual(other.title, "DeepSeek")
        XCTAssertEqual(other.text, "完全不同的另一条回复")
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

    /// 诊断探针：流式输出期间逐帧检查流式行的文字是否被自身边界裁掉
    /// （cell 高度落后于 TextKit 实际排版），以及最后一行是否落在可视区外。
    func testStreamingRowClipProbe() async throws {
        ConversationViewportController.clearReusableHeights()
        defer { ConversationViewportController.clearReusableHeights() }
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        controller.configure(
            sessionID: "clip-probe",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { ConversationViewportEntry(
                    id: $0.id, revision: $0.text.utf16.count,
                    streamingAssistant: .init(title: $0.title, text: $0.text)) }
            },
            bottomInset: 120
        )
        let answer = String(repeating: """
        ## 小结

        这是一个流式输出的中文段落，包含**加粗的强调**、`行内代码`以及较长的句子，用来让每一行都被排满并自然换行到下一行。

        - 第一项：说明某个机制为什么会在视口顶部留下半行
        - 第二项：说明逐帧追随与文字揭示使用同一个时钟

        最后一段继续输出，观察每次换行时行高增长与 cell 边界的关系。

        """, count: 6)
        func publish(_ text: String) {
            timeline.publish([ConversationItem(
                id: "probe", kind: .assistant, title: L10n.streamingAssistantTitle,
                text: text, isError: false, date: Date(timeIntervalSince1970: 1))])
        }
        let list = try XCTUnwrap(findDescendant(UICollectionView.self, in: controller.view))

        var report: [String] = []
        var frames = 0, internalClips = 0, staleHeights = 0, bottomClips = 0
        var maxInternalOverflow: CGFloat = 0, maxBottomOverflow: CGFloat = 0
        var innerScrolls = 0, maxInnerOffset: CGFloat = 0
        var stallRun = 0, maxStallRun = 0, lastOffset: CGFloat = .nan
        func sample(_ phase: String) {
            guard let cell = list.visibleCells.compactMap({ $0 as? StreamingAssistantCell }).first,
                  let textView = findDescendant(UITextView.self, in: cell) else { return }
            frames += 1
            let manager = textView.layoutManager
            manager.ensureLayout(for: textView.textContainer)
            let used = manager.usedRect(for: textView.textContainer).height
            let expectedCell = ceil(15 + 26 + 7 + ceil(used) + 15)
            let shownFrame = cell.layer.presentation()?.frame ?? cell.frame
            let internalOverflow = used - textView.bounds.height
            let visibleBottom = list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom
            let lastLineBottom = shownFrame.minY + textView.frame.minY + used
            let bottomOverflow = lastLineBottom - visibleBottom
            let target = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
            if internalOverflow > 0.5 { internalClips += 1; maxInternalOverflow = max(maxInternalOverflow, internalOverflow) }
            if abs(cell.bounds.height - expectedCell) > 0.5 { staleHeights += 1 }
            if bottomOverflow > 0.5 { bottomClips += 1; maxBottomOverflow = max(maxBottomOverflow, bottomOverflow) }
            let inner = textView.contentOffset.y
            if abs(inner) > 0.25 { innerScrolls += 1; maxInnerOffset = max(maxInnerOffset, abs(inner)) }
            if target - list.contentOffset.y > 0.5, list.contentOffset.y == lastOffset {
                stallRun += 1; maxStallRun = max(maxStallRun, stallRun)
            } else { stallRun = 0 }
            lastOffset = list.contentOffset.y
            if internalOverflow > 0.5 || abs(cell.bounds.height - expectedCell) > 0.5 || bottomOverflow > 0.5
                || abs(inner) > 0.25 || stallRun == 6,
               report.count < 40 {
                report.append(String(format: "%@ f%d chars=%d cellH=%.1f expected=%.1f tvH=%.1f used=%.2f container=%.0f internal=%.2f bottom=%.2f inner=%.2f stall=%d offset=%.1f target=%.1f",
                    phase, frames, cell.renderedCharacterCount, cell.bounds.height, expectedCell, textView.bounds.height,
                    used, textView.textContainer.size.height, internalOverflow, bottomOverflow, inner, stallRun,
                    list.contentOffset.y, target))
            }
        }

        var generator = SystemRandomNumberGenerator()
        var sent = answer.startIndex
        let start = Date()
        var nextChunk = start
        while sent < answer.endIndex, Date().timeIntervalSince(start) < 8 {
            if Date() >= nextChunk {
                sent = answer.index(sent, offsetBy: Int.random(in: 4...24, using: &generator), limitedBy: answer.endIndex) ?? answer.endIndex
                publish(String(answer[..<sent]))
                nextChunk = Date().addingTimeInterval(Double.random(in: 0.04...0.12, using: &generator))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            sample("stream")
        }
        let drainEnd = Date().addingTimeInterval(2)
        while Date() < drainEnd {
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            sample("drain")
        }
        let summary = "frames=\(frames) internalClips=\(internalClips) maxInternal=\(maxInternalOverflow) staleHeights=\(staleHeights) bottomClips=\(bottomClips) maxBottom=\(maxBottomOverflow) innerScrolls=\(innerScrolls) maxInner=\(maxInnerOffset) maxStallRun=\(maxStallRun)"
        try ([summary] + report).joined(separator: "\n")
            .write(toFile: "/tmp/streaming-clip-probe.txt", atomically: true, encoding: .utf8)
        print("CLIP PROBE \(summary)")
        XCTAssertGreaterThan(frames, 100)
    }

    /// 端到端复现录屏的事件序列：live 视口里出现 >160 字的首块，随后流结束、
    /// live 行删除、最终消息以新 id 插入。屏幕上的字数必须单调逐帧增长，
    /// 不得整块出现，也不得在最终切换时一次性补齐。
    func testLiveStreamToRekeyedFinalRevealsContinuouslyThroughViewport() async throws {
        ConversationViewportController.clearReusableHeights()
        defer { ConversationViewportController.clearReusableHeights() }
        let timeline = ConversationTimeline()
        let controller = ConversationViewportController(
            onContentAvailabilityChanged: { _, _ in },
            onPinnedToBottomChanged: { _ in },
            onBottomAlignmentCompleted: {},
            onApproachingTop: {}
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        controller.configure(
            sessionID: "rekeyed-final",
            timeline: timeline,
            supplementalEntries: [],
            makeEntries: { items in
                items.map { item in
                    item.title == L10n.streamingAssistantTitle
                        ? ConversationViewportEntry(id: item.id, revision: item.text.utf16.count,
                            streamingAssistant: .init(title: item.title, text: item.text))
                        : ConversationViewportEntry(id: item.id, revision: item.text.utf16.count,
                            content: AnyView(Text(item.text).frame(maxWidth: .infinity, alignment: .leading)))
                }
            },
            bottomInset: 120
        )
        let user = ConversationItem(id: "s1-1", kind: .user, title: L10n.userMessageTitle, text: "黄金",
            isError: false, date: Date(timeIntervalSince1970: 1))
        let full = String(repeating: "近期走势：11 月 5 日冲到 4146 美元（两周高位），随后回落。", count: 24)
        let firstChunk = String(full.prefix(320))
        let list = try XCTUnwrap(findDescendant(UICollectionView.self, in: controller.view))
        func streamedCount() -> Int? {
            list.visibleCells.compactMap { $0 as? StreamingAssistantCell }.map(\.renderedCharacterCount).max()
        }
        // 与其他视口测试一致：用 Task.sleep 让出主线程，而不是同步空转 RunLoop。
        var tailPendingFrames = 0
        func pump(_ seconds: TimeInterval, _ sample: () -> Void) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try await Task.sleep(for: .milliseconds(8))
                if controller.isTailCommitPendingForTesting { tailPendingFrames += 1 }
                sample()
            }
        }

        timeline.publish([user])
        try await pump(0.4) {}
        timeline.publish([user, ConversationItem(id: "live-a1-text-delta-0", kind: .assistant,
            title: L10n.streamingAssistantTitle, text: firstChunk, isError: false, date: Date(timeIntervalSince1970: 2))])
        var firstVisible: Int?
        var liveSamples: [Int] = []
        try await pump(0.3) {
            if let count = streamedCount() {
                if firstVisible == nil { firstVisible = count }
                liveSamples.append(count)
            }
        }
        let livePendingFrames = tailPendingFrames
        // 流结束：live 行删除、持久化最终消息以新 id 插入（同一次发布）。
        timeline.publish([user, ConversationItem(id: "s1-12", kind: .assistant, title: "DeepSeek",
            text: full, isError: false, date: Date(timeIntervalSince1970: 3))])
        var afterSwap: [Int] = []
        var finalHostedAt: Int?
        try await pump(2.5) {
            if let count = streamedCount() { afterSwap.append(count) }
            else if finalHostedAt == nil { finalHostedAt = afterSwap.count }
        }
        let report = "firstVisible=\(firstVisible ?? -1)/\(firstChunk.count) liveLast=\(liveSamples.last ?? -1) "
            + "liveFrames=\(liveSamples.count) livePending=\(livePendingFrames) "
            + "afterSwapFirst=\(afterSwap.first ?? -1) afterSwapLast=\(afterSwap.last ?? -1)/\(full.count) "
            + "afterSwapFrames=\(afterSwap.count) finalHostedAfter=\(finalHostedAt ?? -1) "
            + "totalPending=\(tailPendingFrames)"
        try report.write(toFile: "/tmp/streaming-rekeyed-final.txt", atomically: true, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(firstVisible, report), firstChunk.count / 2, "首块不得整块出现：\(report)")
        let swapStart = try XCTUnwrap(afterSwap.first, "切换后应仍由流式行继续揭示：\(report)")
        XCTAssertLessThan(swapStart, full.count, "切换瞬间不得一次性补齐：\(report)")
        XCTAssertGreaterThanOrEqual(swapStart, (liveSamples.last ?? 0) - 1, "切换不得回退已显示文字：\(report)")
        for (a, b) in zip(afterSwap, afterSwap.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "揭示必须单调：\(report)")
        }
        XCTAssertGreaterThan(Set(afterSwap).count, 5, "切换后必须逐帧增长，而不是停住后整块补齐：\(report)")
        XCTAssertGreaterThanOrEqual(afterSwap.last ?? 0, full.count * 9 / 10,
            "交给最终渲染器前应已基本揭示完：\(report)")
        XCTAssertNotNil(finalHostedAt, "揭示完成后应交给最终渲染器：\(report)")
    }
}

private func findDescendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let match = findDescendant(type, in: subview) { return match }
    }
    return nil
}
