import Foundation

/// Finds a CLI's logo on its own screen (a `tmux capture-pane -e` of its first screenful) and cuts it out with its
/// colours, so any agent, including ones added later, shows the logo it draws itself. Nothing here knows any
/// particular CLI.
///
/// 1. Art: the first cluster of block characters (▀ ▄ █ ▌ ▐ quadrants) or Braille near the top, skipping long
///    rules (input box edges). Its bounding box is the full logo; the first part of it, cut at a gap of blank columns
///    and kept roughly square, is the mark (Gemini CLI's chevron before its lettering, the first letters of a wide
///    wordmark).
/// 2. Text: otherwise a short coloured symbol at the start of a header line, followed by the name ("  >_ OpenAI
///    Codex", "✻ Welcome to …").
enum LogoExtractor {
    struct Cell: Equatable {
        var character: Character
        var foreground: String?
        var background: String?
        var bold: Bool

        var isBlank: Bool { character == " " && background == nil }
    }

    static func extract(_ screen: String, now: Date = .now) -> TerminalLogo? {
        let rows = parse(screen)
        if let logo = artLogo(rows, now: now) { return logo }
        return textLogo(rows, now: now)
    }

    // MARK: Parsing

    /// Each line as cells, one per terminal column (wide characters take two).
    static func parse(_ screen: String) -> [[Cell]] {
        var rows: [[Cell]] = []
        var foreground: String?
        var background: String?
        var bold = false
        for line in screen.components(separatedBy: "\n") {
            var row: [Cell] = []
            let scalars = Array(line.unicodeScalars)
            var i = 0
            while i < scalars.count {
                let scalar = scalars[i]
                if scalar == "\u{1B}" {
                    i += 1
                    guard i < scalars.count else { break }
                    if scalars[i] == "[" {
                        i += 1
                        var params = ""
                        while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                            params.unicodeScalars.append(scalars[i])
                            i += 1
                        }
                        if i < scalars.count, scalars[i] == "m" {
                            applySGR(params, foreground: &foreground, background: &background, bold: &bold)
                        }
                        i += 1
                    } else if scalars[i] == "]" {
                        while i < scalars.count, scalars[i] != "\u{07}", !(scalars[i] == "\\" && i > 0 && scalars[i - 1] == "\u{1B}") { i += 1 }
                        i += 1
                    } else {
                        i += 1
                    }
                    continue
                }
                if scalar.value < 0x20 { i += 1; continue }
                let cell = Cell(character: Character(scalar), foreground: foreground, background: background, bold: bold)
                row.append(cell)
                if isWide(scalar) { row.append(Cell(character: " ", foreground: nil, background: background, bold: false)) }
                i += 1
            }
            rows.append(row)
        }
        return rows
    }

    /// Keeps the colour codes themselves ("38;5;174", "48;2;10;10;10"), so the logo is written back unchanged.
    static func applySGR(_ params: String, foreground: inout String?, background: inout String?, bold: inout Bool) {
        let codes = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < codes.count {
            let code = Int(codes[i]) ?? 0
            switch code {
            case 0: foreground = nil; background = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 30...37, 90...97: foreground = "\(code)"
            case 39: foreground = nil
            case 40...47, 100...107: background = "\(code)"
            case 49: background = nil
            case 38, 48:
                var value: String?
                if i + 2 < codes.count, codes[i + 1] == "5" {
                    value = "\(code);5;\(codes[i + 2])"
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == "2" {
                    value = "\(code);2;\(codes[i + 2]);\(codes[i + 3]);\(codes[i + 4])"
                    i += 4
                }
                if code == 38 { foreground = value } else { background = value }
            default:
                break
            }
            i += 1
        }
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if scalar.properties.isEmojiPresentation { return true }
        return (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
    }

    static func isArt(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x2580...0x259F).contains(scalar.value) || (0x2800...0x28FF).contains(scalar.value)
    }

    // MARK: Block-character logos

    static func artLogo(_ rows: [[Cell]], now: Date) -> TerminalLogo? {
        let top = Array(rows.prefix(30))
        func isArtRow(_ row: [Cell]) -> Bool {
            let art = row.filter { isArt($0.character) }
            guard !art.isEmpty else { return false }
            // A rule (an input box's edge) is one long run of the same character.
            var longest = 0, run = 0
            var previous: Character?
            for cell in row {
                if isArt(cell.character), cell.character == previous { run += 1 } else { run = isArt(cell.character) ? 1 : 0 }
                previous = cell.character
                longest = max(longest, run)
            }
            return longest < 24
        }
        var start: Int?
        var end = 0
        for (index, row) in top.enumerated() {
            if isArtRow(row) {
                if start == nil { start = index }
                end = index
            } else if let first = start {
                let count = top[first...end].reduce(0) { $0 + $1.count(where: { isArt($0.character) }) }
                if count >= 3 { break }
                start = nil
            }
        }
        guard let first = start else { return nil }
        let block = Array(top[first...end])
        guard block.reduce(0, { $0 + $1.count(where: { isArt($0.character) }) }) >= 3 else { return nil }

        // Columns: from the first to the last art cell in the block.
        var minColumn = Int.max, maxColumn = 0
        for row in block {
            for (column, cell) in row.enumerated() where isArt(cell.character) {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
            }
        }
        let width = maxColumn - minColumn + 1
        let grid: [[Cell]] = block.map { row in
            (minColumn...maxColumn).map { column in
                column < row.count ? row[column] : Cell(character: " ", foreground: nil, background: nil, bold: false)
            }
        }
        let full = trimRows(grid)

        // The mark: the first cluster before a gap of 2+ blank columns, kept roughly square.
        func blankColumn(_ column: Int) -> Bool { full.allSatisfy { column >= $0.count || $0[column].isBlank } }
        var markEnd = width - 1
        var gap = 0
        for column in 0..<width {
            if blankColumn(column) {
                gap += 1
                if gap >= 2 {
                    markEnd = column - gap
                    break
                }
            } else {
                gap = 0
            }
        }
        let rowsHigh = full.count
        let squareWidth = max(4, Int((Double(rowsHigh) * 2.4).rounded()))
        if markEnd + 1 > squareWidth * 3 / 2 {
            // A wide wordmark: cut after a whole letter, at the last blank column inside a square-ish width.
            if let cut = (2..<min(markEnd, squareWidth + 2)).reversed().first(where: blankColumn) {
                markEnd = cut - 1
            } else {
                markEnd = min(markEnd, squareWidth - 1)
            }
        }
        let mark = trimRows(full.map { Array($0.prefix(markEnd + 1)) })
        return TerminalLogo(mark: serialize(mark), full: serialize(full), source: "art", capturedAt: now)
    }

    /// Drops blank rows at the top and bottom.
    static func trimRows(_ rows: [[Cell]]) -> [[Cell]] {
        var result = rows
        while let firstRow = result.first, firstRow.allSatisfy(\.isBlank) { result.removeFirst() }
        while let lastRow = result.last, lastRow.allSatisfy(\.isBlank) { result.removeLast() }
        return result
    }

    // MARK: Symbol logos

    static func textLogo(_ rows: [[Cell]], now: Date) -> TerminalLogo? {
        // Lines outside any box first; then lines inside a box ("│ ✻ Welcome to …").
        for framed in [false, true] {
            for row in rows.prefix(20) {
                if let logo = symbolToken(row, insideFrame: framed, now: now) { return logo }
            }
        }
        return nil
    }

    private static let frames: Set<Character> = ["│", "┃", "║", "╭", "╰", "┌", "└", "|", "─", "━"]
    /// Status lines ("[✔] loaded", "✓ done", "• item") are never a logo.
    private static let statusMarks: Set<Character> = ["[", "]", "(", ")", "{", "}", "✔", "✓", "✗", "✘", "☑", "☐", "⚠", "ℹ"]
    /// Neither is a lone menu cursor or bullet ("❯ No, exit", "› Ask Codex").
    private static let menuMarks: Set<Character> = ["❯", "›", ">", "▶", "→", "•", "●", "○", "◦", "-", "*", "+", "#", "$", "%",
                                                    "!", "?", "↳", "⏵", "⎿"]

    private static func symbolToken(_ row: [Cell], insideFrame: Bool, now: Date) -> TerminalLogo? {
        guard var index = row.firstIndex(where: { $0.character != " " }) else { return nil }
        if frames.contains(row[index].character) {
            guard insideFrame, row[index].character == "│" || row[index].character == "┃" || row[index].character == "║" else { return nil }
            index += 1
            while index < row.count, row[index].character == " " { index += 1 }
        } else if insideFrame {
            return nil
        }
        var token: [Cell] = []
        while index < row.count, row[index].character != " ", token.count < 4 {
            token.append(row[index])
            index += 1
        }
        guard (1...3).contains(token.count), index < row.count, row[index].character == " ",
              token.allSatisfy({ !$0.character.isLetter && !$0.character.isNumber && !frames.contains($0.character) }),
              !token.contains(where: { statusMarks.contains($0.character) }),
              !(token.count == 1 && menuMarks.contains(token[0].character)),
              token.contains(where: { $0.foreground != nil }) else { return nil }
        // A name follows: a word of letters right after the symbol.
        let rest = row[(index + 1)...].prefix(while: { $0.character != " " })
        guard rest.count >= 2, rest.first?.character.isLetter == true else { return nil }
        let lines = serialize([token])
        return TerminalLogo(mark: lines, full: lines, source: "text", capturedAt: now)
    }

    // MARK: Writing back

    static func serialize(_ rows: [[Cell]]) -> [String] {
        rows.map { row in
            var line = ""
            var current: (String?, String?, Bool) = (nil, nil, false)
            var trimmed = row
            while let last = trimmed.last, last.isBlank { trimmed.removeLast() }
            for cell in trimmed {
                let style = (cell.foreground, cell.background, cell.bold)
                if style != current {
                    var codes = ["0"]
                    if cell.bold { codes.append("1") }
                    if let foreground = cell.foreground { codes.append(foreground) }
                    if let background = cell.background { codes.append(background) }
                    line += "\u{1B}[" + codes.joined(separator: ";") + "m"
                    current = style
                }
                line.append(cell.character)
            }
            if current != (nil, nil, false) { line += "\u{1B}[0m" }
            return line
        }
    }
}
