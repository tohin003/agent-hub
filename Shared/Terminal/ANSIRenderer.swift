import SwiftUI

/// Turns terminal lines with ANSI colour codes (SGR) into styled text. Other escape sequences are dropped.
nonisolated enum ANSIRenderer {
    struct Style: Equatable {
        var foreground: Color?
        var background: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
        var strike = false
    }

    /// With `columns`, every line is padded to that width and every row is kept, so a live terminal keeps the same
    /// size from one frame to the next. Without it (scrollback), trailing blank lines are dropped.
    static func render(lines: [String], columns: Int? = nil) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var rows = lines
        if columns == nil {
            while let last = rows.last, strip(last).trimmingCharacters(in: .whitespaces).isEmpty, rows.count > 1 {
                rows.removeLast()
            }
        }
        for (index, line) in rows.enumerated() {
            appendLine(line, style: &style, to: &result)
            if let columns {
                let visible = strip(line).count
                if visible < columns { result.append(AttributedString(String(repeating: " ", count: columns - visible))) }
            }
            if index < rows.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }

    static func appendLine(_ line: String, style: inout Style, to result: inout AttributedString) {
        let scalars = Array(line.unicodeScalars)
        var text = String.UnicodeScalarView()
        var i = 0
        func flush() {
            guard !text.isEmpty else { return }
            var run = AttributedString(String(text))
            apply(style, to: &run)
            result.append(run)
            text = String.UnicodeScalarView()
        }
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{1B}" {
                flush()
                i += 1
                guard i < scalars.count else { break }
                if scalars[i] == "[" {
                    i += 1
                    var params = ""
                    while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                        params.unicodeScalars.append(scalars[i])
                        i += 1
                    }
                    if i < scalars.count, scalars[i] == "m" { applySGR(params, to: &style) }
                    i += 1
                } else if scalars[i] == "]" {
                    // OSC: skip to BEL or ESC \.
                    while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1B}" { i += 1 }
                    i += 1
                } else {
                    i += 1
                }
                continue
            }
            text.append(scalar)
            i += 1
        }
        flush()
    }

    private static func apply(_ style: Style, to run: inout AttributedString) {
        var foreground = style.foreground
        var background = style.background
        if style.inverse {
            swap(&foreground, &background)
            #if os(iOS)
            foreground = foreground ?? Color(uiColor: .systemBackground)
            #else
            foreground = foreground ?? Color(nsColor: .textBackgroundColor)
            #endif
            background = background ?? Color.primary
        }
        // SwiftUI's attributes by name: on the Mac, AppKit's (NSColor, NSUnderlineStyle) share these names.
        if let foreground { run.swiftUI.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground }
        else if style.dim { run.swiftUI.foregroundColor = Color.secondary }
        if let background { run.swiftUI.backgroundColor = background }
        if style.bold { run.inlinePresentationIntent = .stronglyEmphasized }
        if style.italic { run.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized) }
        if style.underline { run.swiftUI.underlineStyle = .single }
        if style.strike { run.swiftUI.strikethroughStyle = .single }
    }

    static func applySGR(_ params: String, to style: inout Style) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strike = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strike = false
            case 30...37: style.foreground = basic(code - 30, bright: false)
            case 90...97: style.foreground = basic(code - 90, bright: true)
            case 39: style.foreground = nil
            case 40...47: style.background = basic(code - 40, bright: false)
            case 100...107: style.background = basic(code - 100, bright: true)
            case 49: style.background = nil
            case 38, 48:
                var color: Color?
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    color = palette256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    color = Color(red: Double(codes[i + 2]) / 255, green: Double(codes[i + 3]) / 255, blue: Double(codes[i + 4]) / 255)
                    i += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default:
                break
            }
            i += 1
        }
    }

    /// The 16 basic colours, tuned to read on both light and dark backgrounds.
    static func basic(_ index: Int, bright: Bool) -> Color {
        let normal: [(Double, Double, Double)] = [
            (0.20, 0.20, 0.22), (0.80, 0.25, 0.22), (0.20, 0.62, 0.30), (0.75, 0.60, 0.10),
            (0.25, 0.45, 0.85), (0.70, 0.35, 0.75), (0.15, 0.62, 0.68), (0.72, 0.72, 0.74),
        ]
        let light: [(Double, Double, Double)] = [
            (0.45, 0.45, 0.48), (0.95, 0.40, 0.36), (0.35, 0.78, 0.42), (0.92, 0.78, 0.30),
            (0.45, 0.62, 0.98), (0.85, 0.55, 0.90), (0.35, 0.80, 0.85), (0.93, 0.93, 0.95),
        ]
        let c = (bright ? light : normal)[max(0, min(7, index))]
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static func palette256(_ value: Int) -> Color {
        switch value {
        case 0..<8: return basic(value, bright: false)
        case 8..<16: return basic(value - 8, bright: true)
        case 16..<232:
            let v = value - 16
            let steps = [0.0, 0.37, 0.53, 0.69, 0.84, 1.0]
            return Color(red: steps[v / 36], green: steps[(v / 6) % 6], blue: steps[v % 6])
        default:
            let gray = (Double(max(232, min(255, value)) - 232) * 10 + 8) / 255
            return Color(white: gray)
        }
    }

    static func strip(_ text: String) -> String {
        var result = AttributedString()
        var style = Style()
        appendLine(text, style: &style, to: &result)
        return String(result.characters)
    }
}
