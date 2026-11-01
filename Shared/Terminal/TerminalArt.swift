import SwiftUI

/// A small piece of terminal art: a grid of cells with their characters and colours.
nonisolated struct TerminalArt: Sendable {
    struct Cell: Sendable {
        var character: Character
        var foreground: Color?
        var background: Color?
        var bold: Bool
    }

    let rows: [[Cell]]
    let columns: Int
    /// The terminal background the art was drawn on (OpenCode paints its own).
    let background: Color?

    init(ansi lines: [String], background: Color? = nil) {
        var rows: [[Cell]] = []
        var style = ANSIRenderer.Style()
        for line in lines {
            var row: [Cell] = []
            let scalars = Array(line.unicodeScalars)
            var i = 0
            while i < scalars.count {
                if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                    var params = ""
                    i += 2
                    while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                        params.unicodeScalars.append(scalars[i])
                        i += 1
                    }
                    if i < scalars.count, scalars[i] == "m" { ANSIRenderer.applySGR(params, to: &style) }
                    i += 1
                    continue
                }
                row.append(Cell(character: Character(scalars[i]), foreground: style.foreground, background: style.background,
                                bold: style.bold))
                i += 1
            }
            // Trailing plain spaces don't count towards the width.
            while let last = row.last, last.character == " ", last.background == nil { row.removeLast() }
            rows.append(row)
        }
        self.rows = rows
        columns = rows.map(\.count).max() ?? 0
        self.background = background
    }
}

/// Draws terminal art: block characters (▀ ▄ █ ▌ ▐ and the quadrants) as exact filled cells, other characters as
/// monospaced text, each cell twice as tall as it is wide, like a terminal.
nonisolated enum TerminalArtRenderer {
    /// Quadrants per block character: top-left, top-right, bottom-left, bottom-right.
    private static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        "█": (true, true, true, true), "▀": (true, true, false, false), "▄": (false, false, true, true),
        "▌": (true, false, true, false), "▐": (false, true, false, true), "▖": (false, false, true, false),
        "▗": (false, false, false, true), "▘": (true, false, false, false), "▝": (false, true, false, false),
        "▙": (true, false, true, true), "▚": (true, false, false, true), "▛": (true, true, true, false),
        "▜": (true, true, false, true), "▞": (false, true, true, false), "▟": (false, true, true, true),
    ]

    static func draw(_ art: TerminalArt, in context: GraphicsContext, rect: CGRect, defaultForeground: Color) {
        let rowCount = art.rows.count
        guard art.columns > 0, rowCount > 0 else { return }
        let cellWidth = min(rect.width / Double(art.columns), rect.height / (Double(rowCount) * 2))
        let cellHeight = cellWidth * 2
        let size = CGSize(width: cellWidth * Double(art.columns), height: cellHeight * Double(rowCount))
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let bleed = max(0.2, cellWidth * 0.02)

        // Backgrounds first, all of them, so no cell's background is drawn over a neighbour's block.
        for (rowIndex, row) in art.rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                guard let background = cell.background else { continue }
                let cellRect = CGRect(x: origin.x + Double(columnIndex) * cellWidth, y: origin.y + Double(rowIndex) * cellHeight,
                                      width: cellWidth, height: cellHeight)
                context.fill(Path(cellRect.insetBy(dx: -bleed, dy: -bleed)), with: .color(background))
            }
        }
        for (rowIndex, row) in art.rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let x = origin.x + Double(columnIndex) * cellWidth
                let y = origin.y + Double(rowIndex) * cellHeight
                let foreground = cell.foreground ?? defaultForeground
                if let quads = quadrants[cell.character] {
                    let halfW = cellWidth / 2, halfH = cellHeight / 2
                    let parts = [(quads.0, 0.0, 0.0), (quads.1, halfW, 0.0), (quads.2, 0.0, halfH), (quads.3, halfW, halfH)]
                    for (on, dx, dy) in parts where on {
                        let piece = CGRect(x: x + dx, y: y + dy, width: halfW, height: halfH).insetBy(dx: -bleed, dy: -bleed)
                        context.fill(Path(piece), with: .color(foreground))
                    }
                } else if let scalar = cell.character.unicodeScalars.first, (0x2800...0x28FF).contains(scalar.value) {
                    // Braille: a 2 × 4 grid of dots, from the character's bits.
                    let bits = scalar.value - 0x2800
                    let dots: [(UInt32, Int, Int)] = [(0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x40, 0, 3),
                                                      (0x08, 1, 0), (0x10, 1, 1), (0x20, 1, 2), (0x80, 1, 3)]
                    let dotW = cellWidth / 2, dotH = cellHeight / 4
                    let radius = min(dotW, dotH) * 0.42
                    for (bit, column, row) in dots where bits & bit != 0 {
                        let center = CGPoint(x: x + dotW * (Double(column) + 0.5), y: y + dotH * (Double(row) + 0.5))
                        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2,
                                                            height: radius * 2)), with: .color(foreground))
                    }
                } else if cell.character != " " {
                    let text = Text(String(cell.character))
                        .font(.system(size: cellHeight * 0.92, weight: cell.bold ? .bold : .semibold, design: .monospaced))
                        .foregroundStyle(foreground)
                    context.draw(text, at: CGPoint(x: x + cellWidth / 2, y: y + cellHeight / 2), anchor: .center)
                }
            }
        }
    }
}
