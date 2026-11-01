import SwiftUI

/// An agent's logo on a terminal-dark tile: the logo the hub read from the CLI's own screen, or the account's
/// initial until the hub has seen it.
struct CLILogoTile: View {
    var logo: TerminalLogo?
    var fallback: String
    var size: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let art = logo.map { TerminalArt(ansi: $0.mark) }
        Canvas { context, canvasSize in
            if let art, art.columns > 0 {
                let narrow = art.rows.count == 1 && art.columns <= 3
                let inset = canvasSize.width * (narrow ? 0.2 : 0.16)
                let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)
                TerminalArtRenderer.draw(art, in: context, rect: rect, defaultForeground: .white)
            } else {
                let text = Text(fallback)
                    .font(.system(size: canvasSize.height * 0.46, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                context.draw(text, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), anchor: .center)
            }
        }
        .frame(width: size, height: size)
        .background(tileBackground, in: .rect(cornerRadius: size * 0.26))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.26)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// A terminal's black, which every CLI's logo is drawn to read on.
    private var tileBackground: Color {
        Color(red: 0.07, green: 0.07, blue: 0.08)
    }
}

/// A CLI's whole logo at a larger size (an empty conversation shows the agent's own logo).
struct TerminalArtView: View {
    var art: TerminalArt
    var foreground: Color = .white

    var body: some View {
        Canvas { context, size in
            TerminalArtRenderer.draw(art, in: context, rect: CGRect(origin: .zero, size: size), defaultForeground: foreground)
        }
        .aspectRatio(Double(max(art.columns, 1)) / (Double(max(art.rows.count, 1)) * 2), contentMode: .fit)
        .accessibilityHidden(true)
    }
}
