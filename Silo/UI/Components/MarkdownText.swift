import SwiftUI

// MARK: - Remend (incomplete markdown closer)

/// Auto-closes incomplete markdown delimiters during streaming to prevent
/// rendering artifacts. Inspired by Vercel's remend package.
func remend(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text

    // Strip trailing single space (preserve double space for line breaks)
    if result.hasSuffix(" ") && !result.hasSuffix("  ") {
        result = String(result.dropLast())
    }

    // Close incomplete fenced code blocks
    let fenceCount = result.components(separatedBy: "```").count - 1
    if fenceCount % 2 == 1 {
        result += "\n```"
    }

    // Close incomplete inline code
    let backtickCount = result.filter { $0 == "`" }.count
    if backtickCount % 2 == 1 {
        result += "`"
    }

    // Close incomplete bold-italic (***)
    let tripleStarCount = countOccurrences(of: "***", in: result)
    if tripleStarCount % 2 == 1 {
        result += "***"
        return result
    }

    // Close incomplete bold (**)
    let doubleStarCount = countOccurrences(of: "**", in: result)
    if doubleStarCount % 2 == 1 {
        result += "**"
        return result
    }

    // Close incomplete italic (*)
    // Only count unescaped asterisks not part of ** or ***
    let singleStarCount = countSingleDelimiters("*", in: result)
    if singleStarCount % 2 == 1 {
        result += "*"
    }

    // Close incomplete strikethrough
    let tildeCount = countOccurrences(of: "~~", in: result)
    if tildeCount % 2 == 1 {
        result += "~~"
    }

    return result
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    var count = 0
    var search = haystack[haystack.startIndex...]
    while let range = search.range(of: needle) {
        count += 1
        search = search[range.upperBound...]
    }
    return count
}

private func countSingleDelimiters(_ char: Character, in text: String) -> Int {
    var count = 0
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == char {
            let next = text.index(after: i)
            if next < text.endIndex && text[next] == char {
                // Skip double/triple
                var skip = next
                while skip < text.endIndex && text[skip] == char {
                    skip = text.index(after: skip)
                }
                i = skip
                continue
            }
            count += 1
        }
        i = text.index(after: i)
    }
    return count
}

// MARK: - Block Model

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case codeBlock(String, String?)
    case unorderedListItem(String, Int)  // content, indent level (0, 1, 2...)
    case orderedListItem(Int, String, Int)  // number, content, indent level
    case divider
}

// MARK: - Block Parser

func parseMarkdownBlocks(_ input: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = input.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            i += 1
            continue
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blocks.append(.divider)
            i += 1
            continue
        }

        if trimmed.hasPrefix("```") {
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let language = lang.isEmpty ? nil : lang
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            blocks.append(.codeBlock(codeLines.joined(separator: "\n"), language))
            continue
        }

        if let heading = parseHeading(trimmed) {
            blocks.append(heading)
            i += 1
            continue
        }

        // Detect indent level from original line (before trimming)
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let indentLevel = indent / 2  // 2 spaces per level

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("· ") {
            let content = String(trimmed.dropFirst(2))
            blocks.append(.unorderedListItem(content, indentLevel))
            i += 1
            continue
        }

        if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
            let num = Int(match.output.1) ?? 1
            let content = String(match.output.2)
            blocks.append(.orderedListItem(num, content, indentLevel))
            i += 1
            continue
        }

        var paraLines: [String] = [trimmed]
        i += 1
        while i < lines.count {
            let next = lines[i].trimmingCharacters(in: .whitespaces)
            if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") ||
               next.hasPrefix("- ") || next.hasPrefix("* ") || next.hasPrefix("+ ") ||
               next == "---" || next == "***" || next == "___" ||
               next.firstMatch(of: /^\d+\.\s+/) != nil {
                break
            }
            paraLines.append(next)
            i += 1
        }
        blocks.append(.paragraph(paraLines.joined(separator: " ")))
    }

    return blocks
}

private func parseHeading(_ line: String) -> MarkdownBlock? {
    var level = 0
    for ch in line {
        if ch == "#" { level += 1 } else { break }
    }
    guard level >= 1, level <= 6, line.count > level,
          line[line.index(line.startIndex, offsetBy: level)] == " " else {
        return nil
    }
    let content = String(line.dropFirst(level + 1))
    return .heading(level, content)
}

// MARK: - Cached Block View (memoized — only re-renders when content changes)

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.block == rhs.block
    }

    var body: some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdown(text)
                .lineSpacing(4)
                .padding(.bottom, 10)

        case .heading(let level, let text):
            inlineMarkdown(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 16 : 10)
                .padding(.bottom, 6)

        case .codeBlock(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 10)

        case .unorderedListItem(let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                Text(indent > 0 ? "◦" : "•")
                    .foregroundColor(.secondary)
                    .font(indent > 0 ? .caption : .body)
                inlineMarkdown(text)
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 20 + 4)
            .padding(.bottom, 6)

        case .orderedListItem(let num, let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                Text("\(num).")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                inlineMarkdown(text)
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 20 + 4)
            .padding(.bottom, 6)

        case .divider:
            Divider()
                .padding(.vertical, 10)
        }
    }

    func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}

// MARK: - Main View

/// Streaming-optimized markdown renderer. Parses text into discrete blocks,
/// memoizes completed blocks so only the last (in-progress) block re-renders
/// during streaming. Auto-closes incomplete markdown via remend.
struct MarkdownText: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        let processed = isStreaming ? remend(text) : text
        let blocks = parseMarkdownBlocks(processed)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let isLastBlock = index == blocks.count - 1

                if isStreaming && isLastBlock {
                    // Last block during streaming — always re-renders
                    MarkdownBlockView(block: block)
                } else {
                    // Completed blocks — memoized, won't re-render
                    EquatableView(content: MarkdownBlockView(block: block))
                }
            }
        }
    }
}

// MARK: - Inline Markdown Parsing

enum InlineSpan {
    case plain(String)
    case bold(String)
    case italic(String)
    case boldItalic(String)
    case code(String)
    case link(String, String)
}

func inlineMarkdown(_ input: String) -> Text {
    let spans = parseInlineSpans(input)
    var result = Text("")
    for span in spans {
        result = result + renderSpan(span)
    }
    return result
}

func parseInlineSpans(_ input: String) -> [InlineSpan] {
    var spans: [InlineSpan] = []
    var remaining = input[input.startIndex..<input.endIndex]

    while !remaining.isEmpty {
        // Inline code
        if remaining.hasPrefix("`") {
            if let endIdx = remaining[remaining.index(after: remaining.startIndex)...].firstIndex(of: "`") {
                let codeStart = remaining.index(after: remaining.startIndex)
                spans.append(.code(String(remaining[codeStart..<endIdx])))
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }
        }

        // Link: [text](url)
        if remaining.hasPrefix("[") {
            if let closeBracket = remaining.firstIndex(of: "]"),
               remaining.index(after: closeBracket) < remaining.endIndex,
               remaining[remaining.index(after: closeBracket)] == "(" {
                let parenStart = remaining.index(after: closeBracket)
                if let closeParen = remaining[remaining.index(after: parenStart)...].firstIndex(of: ")") {
                    let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])
                    let url = String(remaining[remaining.index(after: parenStart)..<closeParen])
                    spans.append(.link(linkText, url))
                    remaining = remaining[remaining.index(after: closeParen)...]
                    continue
                }
            }
        }

        // Bold-italic: ***text*** or ___text___
        if remaining.hasPrefix("***") || remaining.hasPrefix("___") {
            let delim = String(remaining.prefix(3))
            let after = remaining[remaining.index(remaining.startIndex, offsetBy: 3)...]
            if let endRange = after.range(of: delim) {
                spans.append(.boldItalic(String(after[after.startIndex..<endRange.lowerBound])))
                remaining = after[endRange.upperBound...]
                continue
            }
        }

        // Bold: **text** or __text__
        if remaining.hasPrefix("**") || remaining.hasPrefix("__") {
            let delim = String(remaining.prefix(2))
            let after = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...]
            if let endRange = after.range(of: delim) {
                spans.append(.bold(String(after[after.startIndex..<endRange.lowerBound])))
                remaining = after[endRange.upperBound...]
                continue
            }
        }

        // Italic: *text* or _text_
        if remaining.hasPrefix("*") || remaining.hasPrefix("_") {
            let delim = String(remaining.prefix(1))
            let after = remaining[remaining.index(after: remaining.startIndex)...]
            if let endIdx = after.firstIndex(of: Character(delim)) {
                let content = String(after[after.startIndex..<endIdx])
                if !content.isEmpty && !content.contains(" ") || delim == "*" {
                    spans.append(.italic(content))
                    remaining = after[after.index(after: endIdx)...]
                    continue
                }
            }
        }

        // Plain text — consume until next special character
        var endIdx = remaining.index(after: remaining.startIndex)
        while endIdx < remaining.endIndex {
            let ch = remaining[endIdx]
            if ch == "`" || ch == "*" || ch == "_" || ch == "[" {
                break
            }
            endIdx = remaining.index(after: endIdx)
        }
        spans.append(.plain(String(remaining[remaining.startIndex..<endIdx])))
        remaining = remaining[endIdx...]
    }

    return spans
}

func renderSpan(_ span: InlineSpan) -> Text {
    switch span {
    case .plain(let str):
        return Text(str)
    case .bold(let str):
        return Text(str).bold()
    case .italic(let str):
        return Text(str).italic()
    case .boldItalic(let str):
        return Text(str).bold().italic()
    case .code(let str):
        return Text(str)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(.orange)
    case .link(let label, _):
        return Text(label)
            .foregroundColor(.blue)
            .underline()
    }
}
