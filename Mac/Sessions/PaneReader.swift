import Foundation

/// Reads an agent's terminal: whether it is working, and any choice it is waiting on (permission prompts, trust
/// dialogs, questions). Works on plain text (no colour codes), the last screenful of the pane.
enum PaneReader {
    struct Reading: Equatable {
        var working: Bool
        var statusLine: String?
        var prompt: AttentionPrompt?
    }

    /// Reads a screen. `styled` is the same screen captured with its colour codes (`capture-pane -e`): dialogs that
    /// show their selection only as a background colour (OpenCode's buttons and lists) need it; see `wantsStyle`.
    static func read(_ text: String, styled: String? = nil) -> Reading {
        let lines = cleanEscapes(text).components(separatedBy: "\n").map { stripTrailing($0) }
        let bottom = Array(lines.suffix(60))
        let styledBottom = styled.map { Array($0.components(separatedBy: "\n").suffix(60)) }
        let colours = styledBottom.flatMap { $0.count == bottom.count ? $0 : nil }
        // A spinner line can stay on screen under a dialog; a visible choice always wins.
        if let prompt = choicePrompt(bottom) ?? sliderPrompt(bottom) ?? buttonRowPrompt(bottom, styled: colours)
            ?? cursorMenuPrompt(bottom) ?? yesNoPrompt(bottom) ?? pressPrompt(bottom) {
            return Reading(working: false, statusLine: nil, prompt: prompt)
        }
        let (working, status) = workingStatus(bottom)
        // A survey waits on nobody: the session keeps its state.
        return Reading(working: working, statusLine: status, prompt: surveyPrompt(bottom))
    }

    /// Hyperlinks (OSC 8) and other escapes that survive a plain capture, e.g. "]8;id=x;https://…\\Security guide]8;;\\".
    private static let leftoverEscapes = try! NSRegularExpression(pattern: #"\x{1B}?\]8;[^\x{07}\\]*(\x{07}|\\)|\x{1B}\[[0-9;?]*[ -/]*[@-~]"#)

    static func cleanEscapes(_ text: String) -> String {
        guard text.contains("]8;") || text.contains("\u{1B}") else { return text }
        let ns = text as NSString
        return leftoverEscapes.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    // MARK: Working

    // "esc to cancel" is left out: dialogs use it as a hint while nothing is running.
    private static let workingPatterns = [
        "esc to interrupt", "esc interrupt", "(esc to stop)", "ctrl+c to interrupt", "esc to stop",
    ]

    static func workingStatus(_ lines: [String]) -> (Bool, String?) {
        for line in lines.suffix(14).reversed() {
            let lower = line.lowercased()
            guard workingPatterns.contains(where: { lower.contains($0) }) else { continue }
            return (true, cleanStatus(line))
        }
        return (false, nil)
    }

    /// "✻ Pondering… (34s · ↑ 1.2k tokens · esc to interrupt)" → "Pondering… (34s · ↑ 1.2k tokens)".
    static func cleanStatus(_ line: String) -> String {
        var text = stripBox(line)
        for phrase in ["· esc to interrupt", "• esc to interrupt", "esc to interrupt", "· esc to cancel", "esc to cancel",
                       "esc interrupt", "ctrl+c to interrupt"] {
            text = text.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "( )", with: "").replacingOccurrences(of: "()", with: "")
        text = text.replacingOccurrences(of: " )", with: ")").replacingOccurrences(of: "( ", with: "(")
        let spinners = CharacterSet(charactersIn: "✻✽✶✳✢·•*⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏◐◓◑◒●○◉ ")
        text = text.trimmingCharacters(in: spinners)
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Shared pieces of a dialog

    /// A checkbox at the start of an option: "[ ] name", "[✔] name", "◉ name", "☐ name".
    static func checkbox(_ label: String) -> (checked: Bool, rest: String, width: Int)? {
        let boxes: [(String, Bool)] = [
            ("[ ]", false), ("[x]", true), ("[X]", true), ("[✔]", true), ("[✓]", true), ("[*]", true), ("[•]", true),
            ("[✗]", false), ("◯", false), ("○", false), ("◉", true), ("●", true), ("☐", false), ("☑", true), ("☒", true),
            ("□", false), ("■", true),
        ]
        for (box, checked) in boxes where label.hasPrefix(box + " ") {
            return (checked, String(label.dropFirst(box.count + 1)).trimmingCharacters(in: .whitespaces), box.count + 1)
        }
        return nil
    }

    /// The keys a hint line names, as actions: "Space to select · Esc to reject all", "↑/↓ Navigate · enter Confirm".
    static func keyActions(_ hint: String?) -> [KeyAction] {
        guard let hint else { return [] }
        let names: [(String, [String], String)] = [
            ("shift+tab", ["BTab"], "⇧ tab"), ("shift-tab", ["BTab"], "⇧ tab"), ("space", ["Space"], "space"),
            ("escape", ["Escape"], "esc"), ("esc", ["Escape"], "esc"), ("enter", ["Enter"], "return"),
            ("return", ["Enter"], "return"), ("tab", ["Tab"], "tab"),
        ]
        var actions: [KeyAction] = []
        // Hints are separated by "·" (Claude Code, Gemini), "|" (Codex) or two spaces (OpenCode).
        let separated = hint.replacingOccurrences(of: #"\s{2,}"#, with: " · ", options: .regularExpression)
        for raw in separated.components(separatedBy: CharacterSet(charactersIn: "·•|,")) {
            var segment = raw.trimmingCharacters(in: .whitespaces)
            let lower = segment.lowercased()
            // "←/→ to adjust", "⇆ select": both arrows.
            if let arrows = segment.range(of: "←/→") ?? segment.range(of: "← →") ?? segment.range(of: "←→") ?? segment.range(of: "⇆") {
                var verb = String(segment[arrows.upperBound...]).trimmingCharacters(in: .whitespaces)
                if verb.lowercased().hasPrefix("to ") { verb = String(verb.dropFirst(3)) }
                let label = verb.isEmpty ? "Adjust" : verb.prefix(1).uppercased() + verb.dropFirst()
                actions.append(KeyAction(keys: ["Left"], label: label, keyName: "◀"))
                actions.append(KeyAction(keys: ["Right"], label: label, keyName: "▶"))
                continue
            }
            guard !segment.isEmpty, !lower.contains("navigate"), !lower.contains("↑"), !lower.contains("↓"),
                  !lower.hasPrefix("type ") else { continue }
            if lower.hasPrefix("press ") { segment = String(segment.dropFirst(6)) }
            let lowered = segment.lowercased()
            var match: ([String], String, Int)?
            if lowered.hasPrefix("ctrl+") || lowered.hasPrefix("ctrl-"), lowered.count > 5 {
                let letter = lowered[lowered.index(lowered.startIndex, offsetBy: 5)]
                match = (["C-\(letter)"], "⌃\(String(letter).uppercased())", 6)
            } else if let name = names.first(where: { lowered.hasPrefix($0.0 + " ") }) {
                match = (name.1, name.2, name.0.count)
            } else if let first = segment.first, first.isLetter, first.isASCII, segment.count > 2,
                      lowered.dropFirst().hasPrefix(" "), lowered.dropFirst(2).first?.isLetter == true {
                // "s to use this session only", "n to add notes" (Claude Code), "s session" (Codex): a letter key.
                match = ([String(first)], String(first).lowercased(), 1)
            }
            guard let (keys, keyName, length) = match else { continue }
            var verb = String(segment.dropFirst(length)).trimmingCharacters(in: .whitespaces)
            if verb.lowercased().hasPrefix("to ") { verb = String(verb.dropFirst(3)) }
            guard !verb.isEmpty else { continue }
            let label = verb.prefix(1).uppercased() + verb.dropFirst()
            actions.append(KeyAction(keys: keys, label: label, keyName: keyName))
        }
        return actions
    }

    /// The dialog's question: the last line above the options that asks something ("…?"), else its title (the first
    /// line after the rule). Everything else above the options is context.
    private static func questionAndContext(_ lines: [String], above firstLine: Int) -> (String, String?) {
        var above: [String] = []
        var index = firstLine - 1
        while index >= 0, above.count < 16 {
            let raw = lines[index]
            let text = stripBox(raw).trimmingCharacters(in: .whitespaces)
            if isRule(text) || isBoxEdge(raw) { break }
            if workingPatterns.contains(where: { text.lowercased().contains($0) }) { break }
            above.insert(stripBox(raw).trimmingTrailingWhitespace(), at: 0)
            index -= 1
        }
        while above.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { above.removeFirst() }
        while above.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { above.removeLast() }
        let questionIndex = above.lastIndex { $0.contains("?") } ?? above.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let questionIndex else { return ("Choose an option", nil) }
        // Leading marks go ("△ Permission required" → "Permission required"); the question mark stays.
        let line = above[questionIndex].trimmingCharacters(in: .whitespaces)
        let question = String(line.drop { "△▲●◆◇◉⚠ ".contains($0) }).nilIfEmpty ?? line
        var context = above
        context.remove(at: questionIndex)
        let text = dedent(context).joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (question, text.isEmpty ? nil : text)
    }

    // MARK: Numbered choices

    private struct OptionLine {
        var lineIndex: Int
        var number: Int
        var label: String
        /// Where the label starts in the line (columns), to find a second column of descriptions.
        var labelStart: Int
        /// Where the number starts, to find choices without numbers under the list.
        var numberStart: Int
        var selected: Bool
        /// "↑" or "↓" before the number: the list scrolls.
        var scrollMark: Character?
    }

    private static let optionRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[│┃|]\s*)?([❯›>▶→●◉↑↓])?\s*(\d{1,2})[.)]\s+(.+?)\s*(?:[│┃|])?\s*$"#)

    private static func optionLine(_ line: String, index: Int) -> OptionLine? {
        let ns = line as NSString
        guard let match = optionRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let marker = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
        guard let number = Int(ns.substring(with: match.range(at: 2))) else { return nil }
        var label = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "│┃|")).trimmingCharacters(in: .whitespaces)
        let labelStart = (ns.substring(to: match.range(at: 3).location) as String).count
        let numberStart = (ns.substring(to: match.range(at: 2).location) as String).count
        let selected = ["❯", "›", ">", "▶", "→", "●", "◉"].contains(marker)
        let scroll: Character? = marker == "↑" || marker == "↓" ? Character(marker) : nil
        return OptionLine(lineIndex: index, number: number, label: label, labelStart: labelStart, numberStart: numberStart,
                          selected: selected, scrollMark: scroll)
    }

    /// "Opus 5.5 ✔             For complex work…": descriptions in a second column, at the same place on most lines.
    private static func descriptionColumn(_ run: [OptionLine]) -> Int? {
        var counts: [Int: Int] = [:]
        for option in run {
            let characters = Array(option.label)
            var index = 0
            while index < characters.count {
                guard characters[index] == " " else { index += 1; continue }
                var end = index
                while end < characters.count, characters[end] == " " { end += 1 }
                if end - index >= 2, end < characters.count {
                    counts[option.labelStart + end, default: 0] += 1
                    break
                }
                index = end
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2, best.value * 2 >= run.count else { return nil }
        return best.key
    }

    /// Splits a label at the description column, and reads a trailing ✔ (the current one).
    private static func splitLabel(_ option: OptionLine, at column: Int?) -> (label: String, detail: String?, current: Bool) {
        var label = option.label
        var detail: String?
        if let column, column > option.labelStart {
            let characters = Array(option.label)
            let cut = column - option.labelStart
            if cut < characters.count, cut >= 2, characters[cut - 1] == " ", characters[cut - 2] == " " {
                label = String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
                detail = String(characters[cut...]).trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        }
        var current = false
        for mark in ["✔", "✓", "(current)", "(Current)"] where label.hasSuffix(" " + mark) || label == mark {
            current = true
            label = String(label.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return (label, detail, current)
    }

    /// A choice that takes your own words: "Type something.", "Type here to tell Claude what to change".
    static func takesText(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["type something", "type here", "type your", "write your own", "enter your own", "something else",
                "enter a custom value", "write-in", "write in"]
            .contains { lower.hasPrefix($0) }
    }

    /// "… +3 models", "↓ 4 more": the list goes on below.
    private static func isMoreLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("…") || lower.hasPrefix("...") || lower.hasPrefix("↓") || lower.hasPrefix("↑")
            || (lower.contains(" more") && lower.count <= 24 && lower.contains(where: \.isNumber))
    }

    /// The agent's message box, if it's on screen: Claude Code's "❯" line between two rules, Codex's "›" line with its
    /// model and folder under it. Dialogs take its place, so anything above it is conversation.
    static func messageBoxLine(_ lines: [String]) -> Int? {
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        for (position, index) in filled.enumerated().reversed().prefix(8) {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            if text == "❯" || text.hasPrefix("❯ ") {
                let above = position > 0 ? lines[filled[position - 1]] : ""
                let below = position + 1 < filled.count ? lines[filled[position + 1]] : ""
                if isRule(above) && isRule(below) { return index }
                // A draft over several lines: the rule closes it further down.
                if isRule(above), filled[(position + 1)...].prefix(4).contains(where: { isRule(lines[$0]) }) { return index }
            } else if text == "›" || text.hasPrefix("› ") {
                if position + 1 < filled.count, lines[filled[position + 1]].contains(" · ") { return index }
            }
        }
        return nil
    }

    static func choicePrompt(_ lines: [String]) -> AttentionPrompt? {
        // Collect option lines, then find the last run numbered 1, 2, 3… (or a scrolled one, "↑ 4.", "5.", …).
        var options: [OptionLine] = []
        for (index, line) in lines.enumerated() {
            if let option = optionLine(line, index: index) { options.append(option) }
        }
        guard options.count >= 2 else { return nil }
        var runs: [[OptionLine]] = []
        var current: [OptionLine] = []
        for option in options {
            if let last = current.last, option.number == last.number + 1, option.lineIndex - last.lineIndex <= 4 {
                current.append(option)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [option]
            }
        }
        if current.count >= 2 { runs.append(current) }
        guard let run = runs.last(where: { $0.first?.number == 1 || $0.first?.scrollMark == "↑" }) else { return nil }
        // Your own numbered message, echoed above the message box ("❯ 1. fix the login"), isn't a question.
        if let box = messageBoxLine(lines), box > run.last!.lineIndex { return nil }

        // Choices without numbers under a divider ("Chat about this"), at the numbers' column or with the cursor.
        var extras: [(label: String, selected: Bool)] = []
        var footer: [String] = []
        var hints: [String] = []
        var sawRule = false
        var trailing = 0
        /// Lines before the first key hint, and whether a rule came first (then the hint is the message box's).
        var firstHint: (after: Int, ruleBefore: Bool)?
        let runHasBoxes = run.contains { checkbox($0.label) != nil }
        for index in (run.last!.lineIndex + 1)..<lines.count {
            let raw = lines[index]
            let text = stripBox(raw).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            trailing += 1
            if isRule(text) { sawRule = true; continue }
            if isHint(text) || text.contains("←/→") || text.contains("← →") {
                if firstHint == nil { firstHint = (trailing - 1, sawRule) }
                hints.append(text)
                if !isHint(text) { footer.append(text) }
                continue
            }
            if isMoreLine(text) { footer.append(text); continue }
            if sawRule, hints.isEmpty, text.count <= 40, optionLine(raw, index: index) == nil {
                if let cursor = cursorLine(raw) {
                    extras.append((cursor.label, true))
                    continue
                }
                if let column = textColumn(raw), abs(column - run[0].numberStart) <= 2 {
                    extras.append((text, false))
                    continue
                }
            }
            // A checklist's own action right under it, at the numbers' column ("Done" in Gemini's questions).
            if !sawRule, runHasBoxes, hints.isEmpty, text.count <= 24, optionLine(raw, index: index) == nil,
               let column = textColumn(raw), abs(column - run[0].numberStart) <= 2 || text.hasPrefix("● ") {
                let marked = text.hasPrefix("● ") || cursorLine(raw) != nil
                let label = marked ? String(text.drop { "●◉❯›▶→> ".contains($0) }) : text
                if !label.isEmpty, checkbox(label) == nil {
                    extras.append((label, marked))
                    continue
                }
            }
            if !sawRule, hints.isEmpty, extras.isEmpty { continue } // the last option's description
            if hints.isEmpty { footer.append(text) }
        }
        // Only a dialog near the bottom of the screen: a numbered list higher up is the agent's own text.
        guard trailing <= 9 else { return nil }
        // No cursor glyph (OpenCode draws its cursor only in colour): its digit answers it, when a key hint right
        // under the list says it's a dialog. Every one of these CLIs takes the digit.
        var digitsOnly = false
        if !run.contains(where: \.selected), !extras.contains(where: \.selected) {
            // Strict, or every numbered list in an agent's reply would turn into a question: the dialog's own key
            // hint right under the list (no message box between), naming a key that chooses.
            guard let first = firstHint, first.after <= 1, !first.ruleBefore, run.count <= 9, run.first?.number == 1,
                  extras.isEmpty, let hint = hints.first?.lowercased(), hint.contains("enter"),
                  ["select", "toggle", "confirm", "submit"].contains(where: hint.contains) else { return nil }
            digitsOnly = true
        }

        let column = descriptionColumn(run)
        let hasBoxes = run.contains { checkbox($0.label) != nil }
        var parsed: [AttentionOption] = []
        for (position, option) in run.enumerated() {
            let nextIndex = position + 1 < run.count ? run[position + 1].lineIndex : min(option.lineIndex + 3, lines.count)
            var detailLines: [String] = []
            if option.lineIndex + 1 < nextIndex {
                for i in (option.lineIndex + 1)..<nextIndex {
                    let text = stripBox(lines[i]).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty, !isRule(text), !isHint(text), !isMoreLine(text) { detailLines.append(text) }
                }
            }
            if position == run.count - 1 { detailLines = [] }
            let split = splitLabel(option, at: column)
            let box = checkbox(split.label)
            let label = box?.rest ?? split.label
            let details = [split.detail].compactMap { $0 } + detailLines
            parsed.append(AttentionOption(index: option.number, label: label,
                                          detail: details.isEmpty ? nil : details.joined(separator: " "),
                                          checked: box?.checked, isAction: hasBoxes && box == nil ? true : nil,
                                          takesText: takesText(label) ? true : nil, isCurrent: split.current ? true : nil))
        }
        var selected = run.first(where: \.selected)?.number ?? 0
        if digitsOnly {
            for index in parsed.indices { parsed[index].keys = [String(parsed[index].index)] }
        }
        for (offset, extra) in extras.enumerated() {
            let number = run.last!.number + 1 + offset
            parsed.append(AttentionOption(index: number, label: extra.label, isAction: hasBoxes ? true : nil,
                                          takesText: takesText(extra.label) ? true : nil))
            if extra.selected { selected = number }
        }

        let (question, context) = questionAndContext(lines, above: run.first!.lineIndex)
        let hint = hints.last
        let signature = stableHash(question + "|" + parsed.map(\.label).joined(separator: "|"))
        var actions: [KeyAction] = []
        for line in hints {
            for action in keyActions(line) where !actions.contains(action) { actions.append(action) }
        }
        return AttentionPrompt(signature: signature, kind: digitsOnly ? .yesNo : .choice, question: question, context: context,
                               options: parsed, selectedIndex: digitsOnly ? 1 : selected, hint: hint,
                               multiSelect: hasBoxes ? true : nil, keyActions: actions,
                               footer: footer.isEmpty ? nil : footer.joined(separator: "\n"))
    }

    // MARK: Menus without numbers

    /// "❯ No, exit" / "  Yes, I trust this folder" / "Enter to confirm · Esc to cancel": a cursor on one line and the
    /// other choices aligned under its text. Checklists too ("  [✔] one", "❯ [ ] two", then "Enable selected"
    /// aligned with the names). Needs a hint line under the menu, so a typed "❯ text" in an input box isn't taken for
    /// a menu.
    private static let cursorRegex = try! NSRegularExpression(pattern: #"^(.*?)([❯›▶→>])\s+(\S.*?)\s*[│┃|]?\s*$"#)

    /// Key hints under a menu ("↑/↓ Navigate · enter Confirm", "Space to select · Esc to reject all").
    static func isHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("↑") || lower.contains("↓") { return true }
        let keys = ["enter", "esc", "tab", "return", "space"]
        let verbs = ["confirm", "select", "cancel", "continue", "navigate", "skip", "exit", "back", "choose", "submit",
                     "reject", "toggle", "accept", "close"]
        return keys.contains(where: lower.contains) && verbs.contains(where: lower.contains)
    }

    private static func cursorLine(_ line: String) -> (column: Int, label: String)? {
        let ns = line as NSString
        guard let match = cursorRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let before = ns.substring(with: match.range(at: 1))
        guard before.allSatisfy({ $0 == " " || "│┃|".contains($0) }) else { return nil }
        let label = ns.substring(with: match.range(at: 3))
        return ((ns.substring(to: match.range(at: 3).location) as String).count, label)
    }

    private static func textColumn(_ line: String) -> Int? {
        var column = 0
        for character in line {
            if character == " " || "│┃|".contains(character) {
                column += 1
                continue
            }
            return column
        }
        return nil
    }

    static func cursorMenuPrompt(_ lines: [String]) -> AttentionPrompt? {
        // With the message box on screen, a "❯ …" line is your own message (or what you're typing), not a menu.
        let box = messageBoxLine(lines)
        guard let markerIndex = lines.indices.reversed().first(where: { cursorLine(lines[$0]) != nil }),
              let marker = cursorLine(lines[markerIndex]), box == nil || box! < markerIndex && box! != markerIndex
        else { return nil }
        let column = marker.column
        let markerBox = checkbox(marker.label)
        func inBlock(_ index: Int) -> Bool {
            guard let col = textColumn(lines[index]), !isHint(lines[index]) else { return false }
            return col >= column && cursorLine(lines[index]) == nil
        }
        var start = markerIndex
        while start > 0, inBlock(start - 1) { start -= 1 }
        var end = markerIndex
        while end + 1 < lines.count, inBlock(end + 1) { end += 1 }

        // Is it a checklist? Then lines aligned with the names after the boxes ("Enable selected") are actions.
        var hasBoxes = markerBox != nil
        if !hasBoxes {
            for index in start...end where index != markerIndex && textColumn(lines[index]) == column {
                if checkbox(stripBox(lines[index]).trimmingCharacters(in: .whitespaces)) != nil { hasBoxes = true }
            }
        }
        let boxTextColumn = column + (markerBox?.width ?? 4)

        struct Item {
            var label: String
            var detail: [String] = []
            var selected = false
            var checked: Bool?
            var isAction = false
        }
        // The last line of the block that holds a checkbox: actions come after it.
        let lastBoxLine = (start...end).last { index in
            if index == markerIndex { return markerBox != nil }
            return textColumn(lines[index]) == column && checkbox(stripBox(lines[index]).trimmingCharacters(in: .whitespaces)) != nil
        } ?? start
        var items: [Item] = []
        for index in start...end {
            let line = lines[index]
            let text = stripBox(line).trimmingCharacters(in: .whitespaces)
            if index == markerIndex {
                items.append(Item(label: markerBox?.rest ?? marker.label, selected: true, checked: markerBox?.checked,
                                  isAction: hasBoxes && markerBox == nil))
            } else if let col = textColumn(line) {
                if col == column {
                    let box = checkbox(text)
                    items.append(Item(label: box?.rest ?? text, checked: box?.checked, isAction: hasBoxes && box == nil))
                } else if hasBoxes, col > column, col <= boxTextColumn + 2, index > lastBoxLine, text.count <= 32,
                          !text.hasSuffix("."), checkbox(text) == nil {
                    // Indented under the boxes, after the last one: an action such as "Enable selected" or "Submit".
                    items.append(Item(label: text, isAction: true))
                } else if !items.isEmpty {
                    items[items.count - 1].detail.append(text)
                }
            }
        }
        guard items.count >= 2, items.count <= 16 else { return nil }

        // A hint under the menu (Enter to confirm, Esc to cancel, ↑/↓ to navigate, Space to select) confirms it's a dialog.
        let after = lines[(end + 1)...].prefix(5).map { stripBox($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let hint = after.first(where: { line in
            let lower = line.lowercased()
            return lower.contains("enter") || lower.contains("esc") || lower.contains("↑") || lower.contains("select")
                || lower.contains("space")
        }) else { return nil }
        guard after.count <= 6 else { return nil }

        let (question, context) = questionAndContext(lines, above: start)
        let parsed = items.enumerated().map { offset, item in
            AttentionOption(index: offset + 1, label: item.label, detail: item.detail.isEmpty ? nil : item.detail.joined(separator: " "),
                            checked: item.checked, isAction: item.isAction ? true : nil)
        }
        let selected = (items.firstIndex { $0.selected } ?? 0) + 1
        let signature = stableHash("menu|" + question + "|" + parsed.map(\.label).joined(separator: "|"))
        let multi = hasBoxes || hint.lowercased().contains("space to")
        return AttentionPrompt(signature: signature, kind: .choice, question: question, context: context, options: parsed,
                               selectedIndex: selected, hint: hint, multiSelect: multi ? true : nil, keyActions: keyActions(hint))
    }

    /// "◐ Medium effort (default) ←/→ to adjust" under Claude Code's model picker → "medium".
    static func effortWord(_ prompt: AttentionPrompt) -> String? {
        guard let footer = prompt.footer else { return nil }
        for line in footer.components(separatedBy: "\n") {
            let words = line.lowercased().split(whereSeparator: { !$0.isLetter })
            if let index = words.firstIndex(of: "effort"), index > 0 { return String(words[index - 1]) }
        }
        return nil
    }

    /// Claude Code's answer to a model choice: "Set model to Opus 5.5 for this session only · max effort for this
    /// session only", "Set model to Sonnet 5.5 for this session only with low effort".
    static func modelConfirmation(_ text: String) -> (model: String, effort: String?)? {
        let lines = cleanEscapes(text).components(separatedBy: "\n")
        guard let line = lines.last(where: { $0.contains("Set model to ") }),
              let start = line.range(of: "Set model to ") else { return nil }
        let rest = String(line[start.upperBound...])
        var model = rest
        for stop in [" for this session", " and saved", " with ", " ·", " (", "  "] {
            if let range = model.range(of: stop) { model = String(model[..<range.lowerBound]) }
        }
        var effort: String?
        let words = rest.lowercased().split(whereSeparator: { !$0.isLetter })
        if let index = words.firstIndex(of: "effort"), index > 0 { effort = String(words[index - 1]) }
        let name = model.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, effort)
    }

    // MARK: Buttons on one line

    /// Button-ish words on a line ("Allow once   Allow always   Reject"), and the key hints after them.
    private static func buttonsAndHints(_ line: String)
        -> (buttons: [(text: String, start: Int, end: Int)], hints: [(text: String, start: Int, end: Int)])? {
        let tokens = spacedTokens(line).filter { !["┃", "│", "|", "║"].contains($0.text) }
        var buttons: [(text: String, start: Int, end: Int)] = []
        var hints: [(text: String, start: Int, end: Int)] = []
        for token in tokens {
            let lower = token.text.lowercased()
            let isKeyHint = isHint(token.text) || token.text.contains("⇆") || lower.hasPrefix("enter ") || lower.hasPrefix("esc ")
                || lower.hasPrefix("ctrl+") || lower.hasPrefix("tab ")
            if isKeyHint {
                hints.append(token)
            } else if hints.isEmpty, token.text.count <= 24, token.text.split(separator: " ").count <= 4,
                      token.text.first?.isLetter == true {
                buttons.append(token)
            } else if hints.isEmpty {
                return nil
            }
        }
        guard buttons.count >= 2 else { return nil }
        return (buttons: buttons, hints: hints)
    }

    /// Whether a screen has a dialog that shows its choice only in colour: read it again with `capture-pane -e`.
    static func wantsStyle(_ text: String) -> Bool {
        let lines = cleanEscapes(text).components(separatedBy: "\n").map { stripTrailing($0) }
        for index in lines.indices.reversed().prefix(10) {
            guard let row = buttonsAndHints(lines[index]) else { continue }
            if !row.hints.isEmpty { return true }
            if index + 1 < lines.count, isHint(lines[index + 1]) || lines[index + 1].contains("⇆") { return true }
        }
        return false
    }

    /// "Allow once   Allow always   Reject        ⇆ select  enter confirm" (OpenCode): buttons on one line; the one
    /// chosen is drawn only with a background, so the colour capture tells which.
    static func buttonRowPrompt(_ lines: [String], styled: [String]?) -> AttentionPrompt? {
        guard let styled else { return nil }
        for index in lines.indices.reversed().prefix(8) {
            guard let row = buttonsAndHints(lines[index]) else { continue }
            var hints = row.hints.map(\.text)
            if hints.isEmpty, index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if isHint(next) || next.contains("⇆") || next.lowercased().contains("enter ") { hints = [next] }
            }
            // A dialog's keys ("enter confirm", "⇆ select"), not any words in a row.
            guard hints.contains(where: { $0.lowercased().contains("enter") || $0.contains("⇆") }) else { continue }
            let colours = backgrounds(styled[index])
            func colour(_ column: Int) -> String? { column < colours.count ? colours[column] : nil }
            // The backdrop: under the key hints when they share the line, else what most buttons sit on. The chosen
            // button differs from it.
            let starts = row.buttons.map { colour($0.start) }
            var backdrop: String??
            if let hint = row.hints.first {
                backdrop = .some(colour(hint.start))
            } else {
                var counts: [String: Int] = [:]
                for start in starts { counts[start ?? "-", default: 0] += 1 }
                if let common = counts.max(by: { $0.value < $1.value }), common.value >= 2 {
                    backdrop = .some(common.key == "-" ? nil : common.key)
                }
            }
            guard let backdrop else { continue }
            let chosen = starts.indices.filter { starts[$0] != backdrop }
            guard chosen.count == 1 else { continue }
            let options = row.buttons.enumerated().map { AttentionOption(index: $0.offset + 1, label: $0.element.text) }
            let (question, context) = questionAndContext(lines, above: index)
            var actions: [KeyAction] = []
            for hint in hints {
                for action in keyActions(hint.replacingOccurrences(of: "  ", with: " · ")) where !actions.contains(action) {
                    actions.append(action)
                }
            }
            let signature = stableHash("buttons|" + question + "|" + options.map(\.label).joined(separator: "|"))
            return AttentionPrompt(signature: signature, kind: .choice, question: question, context: context, options: options,
                                   selectedIndex: chosen[0] + 1, hint: hints.joined(separator: " · "), keyActions: actions,
                                   horizontal: true)
        }
        return nil
    }

    /// The background at each column of a line captured with its colour codes (nil: the terminal's own). Reverse
    /// video counts as a background of its own.
    static func backgrounds(_ styled: String) -> [String?] {
        var result: [String?] = []
        var background: String?
        var reverse = false
        let characters = Array(styled)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\u{1B}" else {
                result.append(reverse ? "reverse" : background)
                index += 1
                continue
            }
            guard index + 1 < characters.count else { break }
            if characters[index + 1] == "[" {
                var end = index + 2
                while end < characters.count, !(characters[end].isLetter || characters[end] == "~" || characters[end] == "@") { end += 1 }
                guard end < characters.count else { break }
                if characters[end] == "m" {
                    let numbers = String(characters[(index + 2)..<end]).split(separator: ";", omittingEmptySubsequences: false)
                        .map { Int($0) ?? 0 }
                    applySGR(numbers.isEmpty ? [0] : numbers, background: &background, reverse: &reverse)
                }
                index = end + 1
            } else if characters[index + 1] == "]" {
                var end = index + 2
                while end < characters.count, characters[end] != "\u{07}", characters[end] != "\\" { end += 1 }
                index = end + 1
            } else {
                index += 2
            }
        }
        return result
    }

    private static func applySGR(_ codes: [Int], background: inout String?, reverse: inout Bool) {
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0: background = nil; reverse = false
            case 7: reverse = true
            case 27: reverse = false
            case 40...47, 100...107: background = "\(codes[i])"
            case 49: background = nil
            case 48 where i + 2 < codes.count && codes[i + 1] == 5:
                background = "5;\(codes[i + 2])"
                i += 2
            case 48 where i + 4 < codes.count && codes[i + 1] == 2:
                background = "2;\(codes[i + 2]);\(codes[i + 3]);\(codes[i + 4])"
                i += 4
            case 38 where i + 1 < codes.count && codes[i + 1] == 5: i += 2
            case 38 where i + 1 < codes.count && codes[i + 1] == 2: i += 4
            default: break
            }
            i += 1
        }
    }

    /// Codex shows its model and effort under its message box: "GPT-6.1-Sol xhigh · ~/project".
    static func codexModelLine(_ text: String) -> (model: String, effort: String?)? {
        let lines = cleanEscapes(text).components(separatedBy: "\n").map { stripTrailing($0) }
        // The last few lines with something on them (the screen may end in blank rows).
        let bottom = Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8))
        guard let input = bottom.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("›") }),
              input + 1 < bottom.count else { return nil }
        let line = bottom[input + 1].trimmingCharacters(in: .whitespaces)
        guard let dot = line.range(of: " · ") else { return nil }
        let words = line[..<dot.lowerBound].split(separator: " ").map(String.init)
        guard let last = words.last, !words.isEmpty else { return nil }
        // The effort is a lowercase word after the model's name ("xhigh", "max"); a name alone has none.
        if words.count >= 2, last.allSatisfy({ $0.isLowercase && $0.isLetter }) {
            return (words.dropLast().joined(separator: " "), last)
        }
        return (words.joined(separator: " "), nil)
    }

    // MARK: Sliders

    /// Words spaced apart on one line ("low     medium     high"), with their columns.
    private static func spacedTokens(_ line: String) -> [(text: String, start: Int, end: Int)] {
        var tokens: [(String, Int, Int)] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == " " { index += 1; continue }
            var end = index
            // A token runs until two spaces in a row.
            while end < characters.count, !(characters[end] == " " && (end + 1 >= characters.count || characters[end + 1] == " ")) {
                end += 1
            }
            let text = String(characters[index..<end]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { tokens.append((text, index, end)) }
            index = end
        }
        return tokens
    }

    /// Claude Code's effort: "low     medium     high     xhigh      max" with "─────▲─────" above it and
    /// "←/→ to adjust" under it. The options sit side by side; ◀ ▶ move between them.
    static func sliderPrompt(_ lines: [String]) -> AttentionPrompt? {
        guard let hintIndex = lines.indices.reversed().prefix(14).first(where: {
            lines[$0].contains("←/→") || lines[$0].contains("← →") || (lines[$0].contains("◂") && lines[$0].contains("▸"))
        }) else { return nil }
        let ruleAndMarkers = CharacterSet(charactersIn: "─━═-▲▼●◆│ ")
        for index in stride(from: hintIndex - 1, through: max(1, hintIndex - 8), by: -1) {
            let tokens = spacedTokens(lines[index])
            let words = tokens.filter { !isHint($0.text) && !$0.text.contains(" ") && $0.text.count <= 14 }
            guard words.count >= 3 else { continue }
            var markerColumn: Int?
            var markerLine = index - 1
            for neighbour in [index - 1, index + 1] where neighbour >= 0 && neighbour < lines.count && neighbour != hintIndex {
                if let column = Array(lines[neighbour]).firstIndex(where: { "▲▼◆◉".contains($0) }) {
                    markerColumn = column
                    markerLine = neighbour
                    break
                }
            }
            guard let markerColumn else { continue }
            func distance(_ token: (text: String, start: Int, end: Int)) -> Int {
                if markerColumn >= token.start && markerColumn < token.end { return 0 }
                return min(abs(markerColumn - token.start), abs(markerColumn - (token.end - 1)))
            }
            let selected = words.indices.min { distance(words[$0]) < distance(words[$1]) } ?? 0
            let options = words.enumerated().map { AttentionOption(index: $0.offset + 1, label: $0.element.text) }
            // Other words on the marker's line ("Ultracode  off") and lines under the slider are its footer.
            var footer: [String] = []
            let markerExtras = spacedTokens(lines[markerLine]).map(\.text)
                .filter { !$0.unicodeScalars.allSatisfy { ruleAndMarkers.contains($0) } }
            if !markerExtras.isEmpty { footer.append(markerExtras.joined(separator: " ")) }
            // Lines between the slider and its hint (none when the marker sits on the hint line itself).
            let below = max(index, markerLine) + 1
            if below < hintIndex {
                for line in lines[below..<hintIndex] {
                    let text = stripBox(line).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { footer.append(text) }
                }
            }
            var actions = keyActions(stripBox(lines[hintIndex]).trimmingCharacters(in: .whitespaces))
            for token in tokens where isHint(token.text) {
                for action in keyActions(token.text) where !actions.contains(action) { actions.append(action) }
            }
            let (question, context) = questionAndContext(lines, above: min(index, markerLine))
            let signature = stableHash("slider|" + question + "|" + options.map(\.label).joined(separator: "|"))
            return AttentionPrompt(signature: signature, kind: .choice, question: question, context: context, options: options,
                                   selectedIndex: selected + 1, hint: stripBox(lines[hintIndex]).trimmingCharacters(in: .whitespaces),
                                   keyActions: actions, horizontal: true, footer: footer.isEmpty ? nil : footer.joined(separator: "\n"))
        }
        return nil
    }

    // MARK: Surveys

    /// "1: Bad    2: Fine   3: Good   0: Dismiss".
    private static let surveyRegex = try! NSRegularExpression(pattern: #"(\d)\s*:\s+(\S(?:.*?\S)?)(?=\s{2,}\d\s*:|\s*$)"#)

    /// "How is Claude doing this session? (optional)" over a row of digit answers. Nothing waits on it.
    static func surveyPrompt(_ lines: [String]) -> AttentionPrompt? {
        let candidates = lines.indices.reversed().filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.prefix(8)
        for index in candidates {
            let text = stripBox(lines[index]).trimmingCharacters(in: .whitespaces)
            guard let first = text.first, first.isNumber else { continue }
            let ns = text as NSString
            let matches = surveyRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard matches.count >= 2 else { continue }
            guard let above = lines[..<index].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            let question = stripBox(lines[above]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "●○◉•* ")).trimmingCharacters(in: .whitespaces)
            guard question.contains("?") || question.lowercased().contains("(optional)") else { return nil }
            let options = matches.enumerated().map { offset, match in
                AttentionOption(index: offset + 1, label: ns.substring(with: match.range(at: 2)),
                                keys: [ns.substring(with: match.range(at: 1))])
            }
            let signature = stableHash("survey|" + question + "|" + options.map(\.label).joined(separator: "|"))
            return AttentionPrompt(signature: signature, kind: .yesNo, question: question, context: nil, options: options,
                                   selectedIndex: 1, hint: nil, optional: true)
        }
        return nil
    }

    // MARK: y/n

    private static let yesNoRegex = try! NSRegularExpression(pattern: #"[\(\[]\s*([yY])\s*/\s*([nN])\s*[\)\]]\s*:?\s*$"#)

    static func yesNoPrompt(_ lines: [String]) -> AttentionPrompt? {
        guard let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let line = stripBox(lines[lastIndex]).trimmingTrailingWhitespace()
        let ns = line as NSString
        guard yesNoRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { return nil }
        let question = line.trimmingCharacters(in: .whitespaces)
        let options = [
            AttentionOption(index: 1, label: "Yes", keys: ["y", "Enter"]),
            AttentionOption(index: 2, label: "No", keys: ["n", "Enter"]),
        ]
        return AttentionPrompt(signature: stableHash("yn|" + question), kind: .yesNo, question: question, context: nil,
                               options: options, selectedIndex: 1, hint: nil)
    }

    // MARK: Press a key

    /// "Press Enter to continue…", "Press any key to continue": a screen waiting for one key.
    static func pressPrompt(_ lines: [String]) -> AttentionPrompt? {
        let tail = lines.suffix(6).map { stripBox($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let line = tail.last(where: { text in
            let lower = text.lowercased()
            return (lower.contains("press enter") || lower.contains("press return") || lower.contains("press any key"))
                && !workingPatterns.contains(where: lower.contains)
        }) else { return nil }
        let lower = line.lowercased()
        let label = lower.contains("retry") ? "Retry" : (lower.contains("exit") ? "Exit" : "Continue")
        let keys = lower.contains("any key") ? ["Enter"] : ["Enter"]
        let above = tail.filter { $0 != line }.last
        return AttentionPrompt(signature: stableHash("press|" + line), kind: .yesNo, question: above ?? line,
                               context: above == nil ? nil : line,
                               options: [AttentionOption(index: 1, label: label, keys: keys)], selectedIndex: 1, hint: line,
                               keyActions: keyActions(line))
    }

    // MARK: The message box

    /// What's typed in the agent's message box ("❯ …" or "› …" right under a rule), if anything. Placeholder hints
    /// (dim or grey text such as 'Try "…"') don't count. Pass the capture with colour codes when there is one.
    static func inputDraft(plain: String, styled: String? = nil) -> String? {
        let lines = cleanEscapes(plain).components(separatedBy: "\n").map { stripTrailing($0) }
        // The last "❯"/"›" line among the bottom few: Claude Code's sits between two rules, Codex's has none.
        let bottom = lines.indices.reversed().filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.prefix(8)
        guard let index = bottom.first(where: { i in
            let text = lines[i].trimmingCharacters(in: .whitespaces)
            return text == "❯" || text.hasPrefix("❯ ") || text == "›" || text.hasPrefix("› ")
        }) else { return nil }
        var draft = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
        // A draft's further lines, up to the rule under Claude Code's box (Codex's next line is its status).
        if lines[index].contains("❯"), index + 1 < lines.count,
           let ruleBelow = lines[(index + 1)...].prefix(6).firstIndex(where: { isRule($0) }) {
            for next in (index + 1)..<ruleBelow {
                let text = lines[next].trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { draft += " " + text }
            }
        }
        draft = draft.trimmingCharacters(in: .whitespaces)
        guard !draft.isEmpty, !draft.hasPrefix("Try \"") else { return nil }
        // Placeholder hints are dim or grey: look at the styled line.
        if let styled {
            let styledLines = styled.components(separatedBy: "\n")
            if index < styledLines.count, isFaint(after: styledLines[index]) { return nil }
        }
        return draft
    }

    /// Whether the text after the prompt marker starts out dim (SGR 2) or grey.
    private static func isFaint(after line: String) -> Bool {
        guard let marker = line.range(of: "❯") ?? line.range(of: "›") else { return false }
        var rest = line[marker.upperBound...]
        var codes: [String] = []
        while let first = rest.first, first == " " || first == "\u{1B}" {
            if first == " " { rest = rest.dropFirst(); continue }
            guard let end = rest.firstIndex(where: { $0.isLetter }) else { break }
            codes.append(String(rest[rest.index(rest.startIndex, offsetBy: 1)..<end]))
            rest = rest[rest.index(after: end)...]
        }
        for code in codes {
            let parts = code.trimmingCharacters(in: CharacterSet(charactersIn: "[")).split(separator: ";").map(String.init)
            if parts.contains("2") || parts.contains("90") { return true }
            if let index = parts.firstIndex(of: "38"), index + 2 < parts.count, parts[index + 1] == "5", let color = Int(parts[index + 2]),
               color == 8 || (232...250).contains(color) { return true }
        }
        return false
    }

    // MARK: The "/" menu

    private static let slashItem = try! NSRegularExpression(pattern: #"^\s*(?:[❯›>]\s+)?(/[A-Za-z0-9][\w:.\-]*)(?:\s{2,}(.*))?$"#)

    /// Claude Code's "/" menu on screen: each command and its description (wrapped lines joined).
    static func slashMenu(_ text: String) -> [(String, String)] {
        let lines = cleanEscapes(text).components(separatedBy: "\n").map { stripTrailing($0) }
        var items: [(String, String)] = []
        var descriptionColumn: Int?
        for line in lines {
            let ns = line as NSString
            if let match = slashItem.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let command = ns.substring(with: match.range(at: 1))
                let description = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
                if match.range(at: 2).location != NSNotFound {
                    descriptionColumn = (ns.substring(to: match.range(at: 2).location) as String).count
                }
                // The input line itself ("❯ /") has no command name; one without a description is the typed text.
                if !description.isEmpty || descriptionColumn != nil { items.append((command, description)) }
            } else if let column = descriptionColumn, !items.isEmpty, let text = textColumn(line), text == column {
                items[items.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                descriptionColumn = nil
            }
        }
        return items
    }

    // MARK: Text helpers

    static func stripBox(_ line: String) -> String {
        var text = line
        let edges = CharacterSet(charactersIn: "│┃║|")
        text = text.trimmingCharacters(in: .whitespaces)
        if let first = text.unicodeScalars.first, edges.contains(first) { text.removeFirst() }
        if let last = text.unicodeScalars.last, edges.contains(last) { text.removeLast() }
        return text
    }

    static func isRule(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let ruleChars = CharacterSet(charactersIn: "─━═-–—_╌╍┄┅┈┉╭╮╰╯┌┐└┘╔╗╚╝▔▁")
        if trimmed.unicodeScalars.allSatisfy({ ruleChars.contains($0) }) { return true }
        // A border with a label in it ("▔▔▔▔▔▔▔▔ tmux focus-events off …", "──── Title ────").
        let lead = trimmed.unicodeScalars.prefix { ruleChars.contains($0) && $0 != "-" && $0 != "_" }
        return lead.count >= 8
    }

    static func isBoxEdge(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") || trimmed.hasPrefix("┌") || trimmed.hasPrefix("└")
    }

    static func stripTrailing(_ line: String) -> String { line.trimmingTrailingWhitespace() }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }
        guard let minimum = indents.min(), minimum > 0 else { return lines }
        return lines.map { $0.count >= minimum ? String($0.dropFirst(minimum)) : $0.trimmingCharacters(in: .whitespaces) }
    }

    /// FNV-1a, stable across launches (Swift's hashValue is seeded per process).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            if self[previous] == " " || self[previous] == "\t" || self[previous] == "\u{00A0}" {
                end = previous
            } else {
                break
            }
        }
        return String(self[..<end])
    }
}
