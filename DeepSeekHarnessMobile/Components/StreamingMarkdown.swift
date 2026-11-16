import UIKit

/// Incremental Markdown renderer for the actively streaming assistant row.
///
/// The text is split into blank-line separated chunks (fence aware). Every
/// chunk except the last is "stable": its attributed output is cached and the
/// shared `NSTextStorage` is edited only from the first changed chunk onward,
/// so TextKit relayouts just the tail instead of the entire response. Unclosed
/// inline syntax (`**bold`, `` `code ``, `[link](`) is styled optimistically so
/// Markdown appears while the text is still arriving instead of at the end.
final class StreamingMarkdownDocument {
    let storage = NSTextStorage()
    private(set) var version = 0

    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(
        size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    private var stableSources: [String] = []
    private var stableOutputs: [NSAttributedString] = []
    private(set) var currentText = ""
    private var currentFade: CGFloat = -1
    private var styleSize: CGFloat = 0
    private var measuredWidthInPixels = 0
    private var lastHeight: CGFloat?

    init() {
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// `tailFade` in 0...1 controls how strongly the newest characters are
    /// dimmed; the reveal buffer drives it back to 0 once the backlog drains.
    @discardableResult
    func update(text: String, tailFade: CGFloat) -> Bool {
        let style = MarkdownStreamStyle.current()
        let fade = (tailFade * 20).rounded() / 20
        if style.size != styleSize {
            styleSize = style.size
            stableSources.removeAll()
            stableOutputs.removeAll()
            currentText = ""
            currentFade = -1
            storage.setAttributedString(NSAttributedString())
        }
        guard text != currentText || fade != currentFade else { return false }

        let chunks = Self.splitChunks(text)
        let stableCount = max(0, chunks.count - 1)

        var common = 0
        let limit = min(stableSources.count, stableCount)
        while common < limit && stableSources[common] == chunks[common] { common += 1 }
        if stableSources.count > common {
            stableSources.removeSubrange(common...)
            stableOutputs.removeSubrange(common...)
        }

        var prefixLength = 0
        for output in stableOutputs { prefixLength += output.length }

        let suffix = NSMutableAttributedString()
        for index in common..<stableCount {
            let output = MarkdownStreamRenderer.render(chunk: chunks[index], style: style)
            stableSources.append(chunks[index])
            stableOutputs.append(output)
            suffix.append(output)
        }
        if let last = chunks.last {
            let tail = NSMutableAttributedString(
                attributedString: MarkdownStreamRenderer.render(chunk: last, style: style)
            )
            if tail.length > 0, tail.string.hasSuffix("\n") {
                tail.deleteCharacters(in: NSRange(location: tail.length - 1, length: 1))
            }
            MarkdownStreamRenderer.applyTailFade(to: tail, strength: fade)
            suffix.append(tail)
        }

        let replaceStart = min(prefixLength, storage.length)
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: replaceStart, length: storage.length - replaceStart),
            with: suffix
        )
        storage.endEditing()

        currentText = text
        currentFade = fade
        version &+= 1
        return true
    }

    /// Same vertical metrics as the previous plain-text measurer: 15pt row
    /// padding on both sides plus room for the action bar that appears once
    /// the response is final, so the swap to the final row does not jump.
    func height(width: CGFloat) -> CGFloat {
        let availableWidth = max(1, width - 4)
        let widthInPixels = Int((availableWidth * UIScreen.main.scale).rounded())
        if widthInPixels != measuredWidthInPixels {
            measuredWidthInPixels = widthInPixels
            container.size = CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        let textHeight: CGFloat
        if storage.length == 0 {
            textHeight = 0
        } else {
            layoutManager.ensureLayout(for: container)
            textHeight = ceil(layoutManager.usedRect(for: container).height)
        }
        return ceil(15 + 26 + 7 + textHeight + 15)
    }

    func measuredHeight(width: CGFloat) -> (height: CGFloat, changed: Bool) {
        let height = height(width: width)
        let changed = lastHeight.map { abs($0 - height) >= 0.5 } ?? true
        lastHeight = height
        return (height, changed)
    }

    /// Splits on blank lines outside fenced code blocks.
    static func splitChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence && trimmed.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                if !current.isEmpty {
                    chunks.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }
}

// MARK: - Style

struct MarkdownStreamStyle {
    let size: CGFloat
    let body: UIFont

    static func current() -> MarkdownStreamStyle {
        let body = UIFont.appPreferredFont(forTextStyle: .body)
        return MarkdownStreamStyle(size: body.pointSize, body: body)
    }

    func font(size: CGFloat? = nil, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> UIFont {
        let pointSize = size ?? self.size
        if mono {
            return UIFont.monospacedSystemFont(ofSize: pointSize, weight: bold ? .semibold : .regular)
        }
        let base = UIFont.systemFont(ofSize: pointSize, weight: bold ? .semibold : .regular)
        guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func paragraph(
        spacing: CGFloat = 6.5,
        before: CGFloat = 0,
        first: CGFloat = 0,
        head: CGFloat = 0,
        tail: CGFloat = 0,
        tabs: [NSTextTab] = [],
        fontSize: CGFloat? = nil,
        clip: Bool = false
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = (fontSize ?? size) * 0.22
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = first
        style.headIndent = head
        style.tailIndent = tail
        style.tabStops = tabs
        style.defaultTabInterval = 0
        style.lineBreakMode = clip ? .byClipping : .byWordWrapping
        return style
    }
}

// MARK: - Block renderer

enum MarkdownStreamRenderer {
    private enum Pending {
        case plain
        case quote
        case list(level: Int, marker: String)
    }

    /// Renders one chunk. Every paragraph is newline terminated.
    static func render(chunk: String, style: MarkdownStreamStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        var pending: (kind: Pending, text: String)?
        var listIndents: [Int] = []

        func flush(nextIsList: Bool = false) {
            guard let current = pending else { return }
            pending = nil
            switch current.kind {
            case .plain:
                out.append(paragraph(inline(current.text, style: style, base: .init()),
                    style.paragraph(), color: .label))
            case .quote:
                out.append(paragraph(inline(current.text, style: style, base: .init()),
                    style.paragraph(first: 14, head: 14), color: .secondaryLabel))
            case .list(let level, let marker):
                let indent = CGFloat(level) * 20
                let tabs = [NSTextTab(textAlignment: .left, location: indent + 20)]
                let body = NSMutableAttributedString(
                    string: marker + "\t",
                    attributes: [.font: style.body, .foregroundColor: UIColor.secondaryLabel]
                )
                body.append(inline(current.text, style: style, base: .init()))
                out.append(paragraph(body,
                    style.paragraph(spacing: nextIsList ? 0 : 6, first: indent, head: indent + 20, tabs: tabs),
                    color: .label))
            }
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                listIndents.removeAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                appendCodeBlock(code, language: language, to: out, style: style)
                continue
            }

            if let heading = headingLevel(trimmed) {
                flush()
                listIndents.removeAll()
                let sizes: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]
                let size = style.size * sizes[heading.level - 1]
                var base = InlineState()
                base.headingSize = size
                out.append(paragraph(inline(heading.text, style: style, base: base),
                    style.paragraph(spacing: 8, before: 18, fontSize: size), color: .label))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flush()
                listIndents.removeAll()
                out.append(NSAttributedString(
                    string: String(repeating: "─", count: 80) + "\n",
                    attributes: [
                        .font: style.font(size: style.size * 0.7),
                        .foregroundColor: UIColor.tertiaryLabel,
                        .paragraphStyle: style.paragraph(spacing: 6.5, before: 8, fontSize: style.size * 0.7, clip: true)
                    ]
                ))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var text = trimmed.dropFirst()
                if text.hasPrefix(" ") { text = text.dropFirst() }
                if case .quote? = pending?.kind {
                    pending?.text += " " + text
                } else {
                    flush()
                    listIndents.removeAll()
                    pending = (.quote, String(text))
                }
                index += 1
                continue
            }

            if let item = listItem(line) {
                let isNewList = listIndents.isEmpty
                flush(nextIsList: true)
                while let top = listIndents.last, top > item.indent { listIndents.removeLast() }
                if listIndents.last.map({ $0 < item.indent }) ?? true { listIndents.append(item.indent) }
                let level = min(listIndents.count - 1, 5)
                _ = isNewList
                var marker = item.marker
                var text = item.text
                if marker == "•" {
                    marker = ["•", "◦", "▪"][level % 3]
                    if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
                    else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
                }
                pending = (.list(level: level, marker: marker), text)
                index += 1
                continue
            }

            if isTableStart(lines, at: index) {
                flush()
                listIndents.removeAll()
                var rows: [[String]] = []
                var rowIndex = index
                while rowIndex < lines.count, lines[rowIndex].contains("|") {
                    if rowIndex != index + 1 { rows.append(tableCells(lines[rowIndex])) }
                    rowIndex += 1
                }
                appendTable(rows, to: out, style: style)
                index = rowIndex
                continue
            }

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            switch pending?.kind {
            case .some(.plain), .some(.list):
                pending?.text += " " + trimmed
            case .some(.quote):
                pending?.text += " " + trimmed
            case .none:
                listIndents.removeAll()
                pending = (.plain, trimmed)
            }
            index += 1
        }
        flush()
        return out
    }

    // MARK: Block helpers

    private static func paragraph(
        _ content: NSAttributedString,
        _ paragraphStyle: NSParagraphStyle,
        color: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        result.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        result.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            if value == nil { result.addAttribute(.foregroundColor, value: color, range: subrange) }
        }
        return result
    }

    /// Mirrors the final code card's metrics (46pt header band, 12pt bottom
    /// padding) with background-filled lines, so the swap to the final row
    /// moves little. Indentation uses an em space instead of paragraph indents
    /// because TextKit leaves indent gutters unfilled.
    private static func appendCodeBlock(
        _ code: [String],
        language: String,
        to out: NSMutableAttributedString,
        style: MarkdownStreamStyle
    ) {
        let codeSize = style.size * 0.86
        let labelSize = style.size * 0.7
        let label = language.isEmpty ? "代码" : language.uppercased()
        let indent = "\u{2003}"

        func pad(_ height: CGFloat, spacing: CGFloat = 0) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.paragraphSpacing = spacing
            out.append(NSAttributedString(
                string: " \n",
                attributes: [
                    .font: style.font(size: 1, mono: true),
                    .backgroundColor: UIColor.secondarySystemFill,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        func line(_ text: String, size: CGFloat, color: UIColor) {
            out.append(NSAttributedString(
                string: indent + (text.isEmpty ? " " : text) + "\n",
                attributes: [
                    .font: style.font(size: size, mono: true),
                    .foregroundColor: color,
                    .backgroundColor: UIColor.secondarySystemFill,
                    .paragraphStyle: style.paragraph(spacing: 0, fontSize: size)
                ]
            ))
        }

        pad(14)
        line(label, size: labelSize, color: .secondaryLabel)
        pad(16)
        for text in code { line(text, size: codeSize, color: .label) }
        if code.isEmpty { line("", size: codeSize, color: .label) }
        pad(12, spacing: 10)
    }

    private static func appendTable(_ rows: [[String]], to out: NSMutableAttributedString, style: MarkdownStreamStyle) {
        for (offset, row) in rows.enumerated() {
            let isLast = offset == rows.count - 1
            let line = NSMutableAttributedString()
            for (column, cell) in row.enumerated() {
                if column > 0 {
                    line.append(NSAttributedString(
                        string: "   │   ",
                        attributes: [.font: style.body, .foregroundColor: UIColor.tertiaryLabel]
                    ))
                }
                var base = InlineState()
                base.bold = offset == 0
                line.append(inline(cell, style: style, base: base))
            }
            out.append(paragraph(line, style.paragraph(spacing: isLast ? 6.5 : 0), color: .label))
        }
    }

    private static func headingLevel(_ trimmed: String) -> (level: Int, text: String)? {
        var count = 0
        for character in trimmed {
            if character == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count) else { return nil }
        let rest = trimmed.dropFirst(count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (count, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        var indent = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let rest = line[index...]
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            if isRule(rest.trimmingCharacters(in: .whitespaces)) { return nil }
            return (indent, "•", after.trimmingCharacters(in: .whitespaces))
        }
        var digits = 0
        for character in rest {
            if character.isASCII && character.isNumber, digits < 9 { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let afterDigits = rest.dropFirst(digits)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return (indent, String(rest.prefix(digits)) + ".", afterDigits.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard separator.contains("-"), separator.contains("|") || separator.hasPrefix("-") else { return false }
        return separator.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Tail fade

    /// Dims the newest characters so incoming text fades in instead of popping.
    static func applyTailFade(to text: NSMutableAttributedString, strength: CGFloat) {
        guard strength > 0.01, text.length > 0 else { return }
        let nsString = text.string as NSString
        var end = text.length
        var step = 0
        let steps = 14
        while end > 0, step < steps {
            let range = nsString.rangeOfComposedCharacterSequence(at: end - 1)
            let progress = CGFloat(step) / CGFloat(steps)
            let alpha = 1 - strength * 0.82 * (1 - progress)
            let color = (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor)
                ?? UIColor.label
            text.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: range)
            end = range.location
            step += 1
        }
    }

    // MARK: Inline

    struct InlineState {
        var bold = false
        var italic = false
        var strike = false
        var link = false
        var headingSize: CGFloat?
    }

    static func inline(_ text: String, style: MarkdownStreamStyle, base: InlineState) -> NSAttributedString {
        let characters = Array(text)
        let out = NSMutableAttributedString()
        var state = base
        var buffer = ""

        func attributes(code: Bool = false) -> [NSAttributedString.Key: Any] {
            let size = state.headingSize ?? style.size
            var attrs: [NSAttributedString.Key: Any] = [:]
            if code {
                attrs[.font] = style.font(size: size * 0.86, bold: state.bold, mono: true)
                attrs[.backgroundColor] = UIColor.secondarySystemFill
            } else {
                let bold = state.bold || state.headingSize != nil
                attrs[.font] = style.font(size: size, bold: bold, italic: state.italic)
            }
            if state.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if state.link { attrs[.foregroundColor] = UIColor.link }
            return attrs
        }
        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: attributes()))
            buffer = ""
        }
        func isPunctuation(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isPunctuation || character.isSymbol
        }
        func isSpace(_ character: Character?) -> Bool {
            guard let character else { return true }
            return character.isWhitespace
        }

        var index = 0
        let count = characters.count
        while index < count {
            let character = characters[index]

            if character == "\\", index + 1 < count, isPunctuation(characters[index + 1]) {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }

            if character == "`" {
                var run = 0
                while index + run < count, characters[index + run] == "`" { run += 1 }
                var search = index + run
                var closeStart: Int?
                while search < count {
                    if characters[search] == "`" {
                        var closeRun = 0
                        while search + closeRun < count, characters[search + closeRun] == "`" { closeRun += 1 }
                        if closeRun == run { closeStart = search; break }
                        search += closeRun
                    } else {
                        search += 1
                    }
                }
                flush()
                let contentEnd = closeStart ?? count
                var content = String(characters[(index + run)..<contentEnd])
                if content.hasPrefix(" "), content.hasSuffix(" "), content.count > 2 {
                    content = String(content.dropFirst().dropLast())
                }
                if !content.isEmpty || closeStart != nil {
                    out.append(NSAttributedString(
                        string: "\u{2009}\(content)\u{2009}",
                        attributes: attributes(code: true)
                    ))
                }
                index = closeStart.map { $0 + run } ?? count
                continue
            }

            if character == "*" || character == "_" {
                var run = 0
                while index + run < count, characters[index + run] == character { run += 1 }
                let previous: Character? = index > 0 ? characters[index - 1] : nil
                let next: Character? = index + run < count ? characters[index + run] : nil
                let leftFlanking = !isSpace(next) && (!isPunctuation(next) || isSpace(previous) || isPunctuation(previous))
                let rightFlanking = !isSpace(previous) && (!isPunctuation(previous) || isSpace(next) || isPunctuation(next))
                var canOpen = leftFlanking
                var canClose = rightFlanking
                if character == "_" {
                    canOpen = leftFlanking && (!rightFlanking || isPunctuation(previous))
                    canClose = rightFlanking && (!leftFlanking || isPunctuation(next))
                }
                let kind = min(run, 3)
                let active: Bool
                switch kind {
                case 1: active = state.italic
                case 2: active = state.bold
                default: active = state.bold && state.italic
                }
                if active && canClose {
                    flush()
                    if kind == 1 || kind == 3 { state.italic = false }
                    if kind >= 2 { state.bold = false }
                } else if !active && (canOpen || (next == nil && !canClose && character == "*")) {
                    flush()
                    if kind == 1 || kind == 3 { state.italic = true }
                    if kind >= 2 { state.bold = true }
                } else {
                    buffer.append(String(repeating: character, count: run))
                }
                index += run
                continue
            }

            if character == "~", index + 1 < count, characters[index + 1] == "~" {
                let previous: Character? = index > 0 ? characters[index - 1] : nil
                let next: Character? = index + 2 < count ? characters[index + 2] : nil
                if state.strike, !isSpace(previous) {
                    flush(); state.strike = false; index += 2; continue
                }
                if !state.strike, !isSpace(next) {
                    flush(); state.strike = true; index += 2; continue
                }
            }

            if character == "[" || (character == "!" && index + 1 < count && characters[index + 1] == "[") {
                let open = character == "[" ? index : index + 1
                var depth = 0
                var close: Int?
                var scan = open
                while scan < count {
                    if characters[scan] == "[" { depth += 1 }
                    else if characters[scan] == "]" {
                        depth -= 1
                        if depth == 0 { close = scan; break }
                    }
                    scan += 1
                }
                if let close {
                    let linkText = String(characters[(open + 1)..<close])
                    if close + 1 < count, characters[close + 1] == "(" {
                        var end = close + 2
                        while end < count, characters[end] != ")" { end += 1 }
                        flush()
                        var linkState = state
                        linkState.link = true
                        out.append(inline(linkText, style: style, base: linkState))
                        index = min(end + 1, count)
                        continue
                    }
                    if close + 1 == count {
                        // `[text]` may still become a link once `(` arrives.
                        flush()
                        var linkState = state
                        linkState.link = true
                        out.append(inline(linkText, style: style, base: linkState))
                        index = count
                        continue
                    }
                }
            }

            buffer.append(character)
            index += 1
        }
        flush()
        return out
    }
}

// MARK: - Reveal buffer

/// Decouples network chunk arrival from what is drawn. Text is revealed at an
/// adaptive rate (a share of the backlog per frame, with a floor) so bursts are
/// spread across frames, and a finished reply keeps its streaming presentation
/// until the backlog drains, which avoids a late pop-in before the final swap.
struct StreamingRevealBuffer {
    private struct Track {
        var shown: Double
        var lastTime: CFTimeInterval
        var settleUntil: CFTimeInterval
        /// Full source text last received for this row (not just the drawn
        /// prefix); a final message under a new id that starts with it is the
        /// same reply, even if nothing has been drawn yet.
        var source = ""
    }

    private var tracks: [String: Track] = [:]
    private(set) var tailFade: CGFloat = 0
    private(set) var needsTick = false

    mutating func reset() {
        tracks.removeAll()
        tailFade = 0
        needsTick = false
    }

    /// `isLive` is false for the first snapshot of a freshly opened session:
    /// rows that are already long then (history reload mid-stream) are shown
    /// at once. Once the viewport is live, every new streaming row is revealed
    /// from its first character, however large the first network chunk is.
    mutating func smoothed(
        _ items: [ConversationItem],
        now: CFTimeInterval,
        advance: Bool,
        isLive: Bool = false
    ) -> [ConversationItem] {
        var result = items
        var live = Set<String>()
        var needs = false
        var fade: CGFloat = 0
        let presentIDs = Set(items.map(\.id))

        for index in items.indices {
            let item = items[index]
            guard item.kind == .assistant,
                  item.images.isEmpty, item.files.isEmpty, item.knownFiles.isEmpty else { continue }
            let streaming = item.title == L10n.streamingAssistantTitle
            let total = item.text.count

            var track: Track
            if let existing = tracks[item.id] {
                track = existing
            } else if !streaming, let orphan = orphanedTrack(continuedBy: item, presentIDs: presentIDs) {
                // With assistant-stream-v1 the live row (`live-<attempt>-…`) is
                // removed when the stream ends and the persisted message is
                // inserted under a new id (`<session>-<seq>`). Continue the live
                // row's progress so the rest is revealed instead of popping in.
                tracks[orphan.id] = nil
                track = orphan.track
            } else {
                guard streaming else { continue }
                track = Track(shown: !isLive && total > 160 ? Double(total) : 0, lastTime: now, settleUntil: 0)
            }
            live.insert(item.id)

            let dt = min(max(now - track.lastTime, 0), 0.05)
            track.lastTime = now
            track.shown = min(track.shown, Double(total))
            if advance, track.shown < Double(total) {
                let backlog = Double(total) - track.shown
                // Exponential catch-up, capped by a backlog-scaled rate so one late
                // frame cannot swallow most of the backlog in a single step.
                let eased = backlog * (1 - exp(-dt * 9))
                let cap = max(300, backlog * 3) * dt
                let step = max(min(eased, cap), 45 * dt)
                track.shown = min(Double(total), track.shown + step)
            }

            let drained = track.shown >= Double(total)
            if !drained { track.settleUntil = now + 0.25 }

            if !streaming && drained {
                // Final item fully shown: hand over to the final renderer.
                tracks[item.id] = nil
                live.remove(item.id)
                continue
            }

            let revealed = String(item.text.prefix(Int(track.shown)))
            track.source = item.text
            tracks[item.id] = track
            result[index] = ConversationItem(
                id: item.id,
                kind: item.kind,
                title: L10n.streamingAssistantTitle,
                text: revealed,
                images: item.images,
                isError: item.isError,
                date: item.date,
                files: item.files,
                knownFiles: item.knownFiles,
                textParts: item.textParts
            )
            if !drained || now < track.settleUntil { needs = true }
            let strength = drained ? CGFloat(max(0, min(1, (track.settleUntil - now) / 0.25))) : 1
            fade = max(fade, strength)
        }

        tracks = tracks.filter { live.contains($0.key) }
        needsTick = needs
        tailFade = fade
        return result
    }

    /// A track whose row left this snapshot and whose source text is a
    /// prefix of `item`'s text: the same reply, re-keyed by persistence.
    private func orphanedTrack(
        continuedBy item: ConversationItem,
        presentIDs: Set<String>
    ) -> (id: String, track: Track)? {
        tracks
            .filter { !presentIDs.contains($0.key) && !$0.value.source.isEmpty
                && item.text.hasPrefix($0.value.source) }
            .max { $0.value.source.count < $1.value.source.count }
            .map { ($0.key, $0.value) }
    }
}
