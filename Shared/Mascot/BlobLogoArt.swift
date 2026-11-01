import Foundation
import SwiftUI

/// An agent's logo, ready to fly around the blob at any size: its terminal art (as `TerminalArtRenderer` draws it,
/// block characters as exact cells, Braille as dots) merged into one path per colour, built once. Codex's mark alone
/// is some 4,000 Braille dots; drawn cell by cell at 30 frames a second that is 4,000 fills a frame, merged it is one.
/// Merging also removes the hairline seams between neighbouring cells of one colour.
nonisolated struct BlobLogoArt: Sendable {
    struct Fill: Sendable {
        var color: Color
        /// In cell units: a cell is 1 wide and 2 tall, the art's top-left at the origin.
        var path: Path
    }

    struct Glyph: Sendable {
        var text: String
        var color: Color
        var bold: Bool
        /// The cell's centre, in cell units.
        var center: CGPoint
    }

    /// The terminal background the art was drawn on, if it paints its own (OpenCode).
    var background: Color?
    /// The art's size in cell units (columns by rows x 2).
    var size: CGSize
    /// Backgrounds first, then foregrounds.
    var fills: [Fill]
    /// Plain characters (a symbol like `>_`), drawn as text.
    var glyphs: [Glyph]

    /// Quadrants per block character: top-left, top-right, bottom-left, bottom-right (as `TerminalArtRenderer`).
    private static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        "█": (true, true, true, true), "▀": (true, true, false, false), "▄": (false, false, true, true),
        "▌": (true, false, true, false), "▐": (false, true, false, true), "▖": (false, false, true, false),
        "▗": (false, false, false, true), "▘": (true, false, false, false), "▝": (false, true, false, false),
        "▙": (true, false, true, true), "▚": (true, false, false, true), "▛": (true, true, true, false),
        "▜": (true, true, false, true), "▞": (false, true, true, false), "▟": (false, true, true, true),
    ]

    init(_ art: TerminalArt, defaultForeground: Color = .white) {
        background = art.background
        size = CGSize(width: Double(art.columns), height: Double(art.rows.count) * 2)
        var backgrounds: [Color] = [], backgroundPaths: [Path] = []
        var foregrounds: [Color] = [], foregroundPaths: [Path] = []
        func add(_ rect: CGRect, _ color: Color, to colors: inout [Color], _ paths: inout [Path]) {
            if let index = colors.firstIndex(of: color) {
                paths[index].addRect(rect)
            } else {
                colors.append(color)
                paths.append(Path(rect))
            }
        }
        func addDot(_ center: CGPoint, radius: Double, _ color: Color) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if let index = foregrounds.firstIndex(of: color) {
                foregroundPaths[index].addEllipse(in: rect)
            } else {
                foregrounds.append(color)
                foregroundPaths.append(Path(ellipseIn: rect))
            }
        }
        // A whisker of overlap between cells of different colours, so no background shows through their seam.
        let bleed = 0.03
        var glyphs: [Glyph] = []
        for (rowIndex, row) in art.rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let x = Double(columnIndex), y = Double(rowIndex) * 2
                if let color = cell.background {
                    add(CGRect(x: x, y: y, width: 1, height: 2).insetBy(dx: -bleed, dy: -bleed), color,
                        to: &backgrounds, &backgroundPaths)
                }
                let foreground = cell.foreground ?? defaultForeground
                if let quads = Self.quadrants[cell.character] {
                    let parts = [(quads.0, 0.0, 0.0), (quads.1, 0.5, 0.0), (quads.2, 0.0, 1.0), (quads.3, 0.5, 1.0)]
                    for (on, dx, dy) in parts where on {
                        add(CGRect(x: x + dx, y: y + dy, width: 0.5, height: 1).insetBy(dx: -bleed, dy: -bleed),
                            foreground, to: &foregrounds, &foregroundPaths)
                    }
                } else if let scalar = cell.character.unicodeScalars.first, (0x2800...0x28FF).contains(scalar.value) {
                    // Braille: a 2 x 4 grid of dots, from the character's bits.
                    let bits = scalar.value - 0x2800
                    let dots: [(UInt32, Int, Int)] = [(0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x40, 0, 3),
                                                      (0x08, 1, 0), (0x10, 1, 1), (0x20, 1, 2), (0x80, 1, 3)]
                    for (bit, column, dotRow) in dots where bits & bit != 0 {
                        addDot(CGPoint(x: x + 0.5 * (Double(column) + 0.5), y: y + 0.5 * (Double(dotRow) + 0.5)),
                               radius: 0.21, foreground)
                    }
                } else if cell.character != " " {
                    glyphs.append(Glyph(text: String(cell.character), color: foreground, bold: cell.bold,
                                        center: CGPoint(x: x + 0.5, y: y + 1)))
                }
            }
        }
        fills = zip(backgrounds, backgroundPaths).map { Fill(color: $0, path: $1) }
            + zip(foregrounds, foregroundPaths).map { Fill(color: $0, path: $1) }
        self.glyphs = glyphs
    }

    /// Draws the art centred in `rect`, as large as fits with its cells' 1:2 shape.
    func draw(in context: GraphicsContext, rect: CGRect) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let k = min(rect.width / size.width, rect.height / size.height)
        let origin = CGPoint(x: rect.midX - size.width * k / 2, y: rect.midY - size.height * k / 2)
        var art = context
        art.translateBy(x: origin.x, y: origin.y)
        art.scaleBy(x: k, y: k)
        for fill in fills {
            art.fill(fill.path, with: .color(fill.color))
        }
        for glyph in glyphs {
            let text = Text(glyph.text)
                .font(.system(size: 2 * k * 0.92, weight: glyph.bold ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(glyph.color)
            context.draw(text, at: CGPoint(x: origin.x + glyph.center.x * k, y: origin.y + glyph.center.y * k),
                         anchor: .center)
        }
    }
}

/// The logos already built, by their mark's lines (a view's init runs on every update of its parent).
nonisolated final class BlobLogoCache: @unchecked Sendable {
    static let shared = BlobLogoCache()

    private let lock = NSLock()
    private var arts: [[String]: BlobLogoArt] = [:]

    func art(for logo: TerminalLogo) -> BlobLogoArt {
        lock.lock()
        defer { lock.unlock() }
        if let art = arts[logo.mark] { return art }
        if arts.count > 24 { arts.removeAll() }
        let art = BlobLogoArt(TerminalArt(ansi: logo.mark))
        arts[logo.mark] = art
        return art
    }
}
