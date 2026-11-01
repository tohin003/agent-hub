import Foundation

/// Agent replies are Markdown. Blocks (headings, lists, code, tables, quotes) are parsed here; text inside each block
/// uses Foundation's inline Markdown (bold, italics, `code`, links).
nonisolated enum MarkdownBlock: Hashable, Identifiable {
    case heading(level: Int, text: AttributedString, id: Int)
    case paragraph(AttributedString, id: Int)
    case list(items: [ListItem], ordered: Bool, id: Int)
    case code(language: String?, text: String, id: Int)
    case quote(AttributedString, id: Int)
    case table(header: [AttributedString], rows: [[AttributedString]], id: Int)
    case rule(id: Int)

    var id: Int {
        switch self {
        case .heading(_, _, let id), .paragraph(_, let id), .list(_, _, let id), .code(_, _, let id), .quote(_, let id),
             .table(_, _, let id), .rule(let id):
            id
        }
    }

    struct ListItem: Hashable {
        var marker: String
        var text: AttributedString
        var indent: Int
        var checked: Bool?
    }
}

nonisolated enum Markdown {
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var counter = 0
        func nextId() -> Int {
            counter += 1
            return counter
        }
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(inline(text), id: nextId())) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n"), id: nextId()))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            // Headings.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: inline(String(trimmed.dropFirst(level + 1))), id: nextId()))
                    i += 1
                    continue
                }
            }
            // Rules.
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               ["-", "*", "_"].contains(trimmed.first.map(String.init) ?? "") {
                flushParagraph()
                blocks.append(.rule(id: nextId()))
                i += 1
                continue
            }
            // Tables: a header row, then a |---| separator.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed).map(inline)
                var rows: [[AttributedString]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)).map(inline))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, id: nextId()))
                continue
            }
            // Quotes.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(inline(quote.joined(separator: "\n")), id: nextId()))
                continue
            }
            // Lists.
            if let first = listItem(line) {
                flushParagraph()
                var items = [first.item]
                let ordered = first.ordered
                i += 1
                while i < lines.count {
                    if let next = listItem(lines[i]) {
                        items.append(next.item)
                        i += 1
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix("  "), var last = items.popLast() {
                        // A continuation line of the previous item.
                        last.text.append(AttributedString(" "))
                        last.text.append(inline(lines[i].trimmingCharacters(in: .whitespaces)))
                        items.append(last)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items, ordered: ordered, id: nextId()))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func listItem(_ line: String) -> (item: MarkdownBlock.ListItem, ordered: Bool)? {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(bullet) {
            var body = String(trimmed.dropFirst(2))
            var checked: Bool?
            if body.hasPrefix("[ ] ") { checked = false; body.removeFirst(4) }
            else if body.lowercased().hasPrefix("[x] ") { checked = true; body.removeFirst(4) }
            return (.init(marker: "•", text: inline(body), indent: indent, checked: checked), false)
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (.init(marker: "\(digits).", text: inline(String(rest.dropFirst(2))), indent: indent, checked: nil), true)
            }
        }
        return nil
    }
}
