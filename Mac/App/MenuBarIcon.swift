import AppKit
import SwiftUI

/// The menu bar icon: the Starlight blob in colour, as on the app icon, with the agents' logos on its orbit (up to
/// four) and the orange badge while a session needs you. A template image would be flattened to one colour, so it
/// isn't one. It holds a picture for a light menu bar and one for a dark one, and draws whichever the menu bar is
/// drawing with at that moment: the menu bar follows the desktop picture as well as Dark Mode, so its appearance isn't
/// always the app's.
enum MenuBarIcon {
    /// The ball's diameter, the same with the orbit or without it, so the icon doesn't jump when the logos arrive:
    /// about as tall as the system's own icons in the menu bar.
    static let ball: CGFloat = 14
    static let height: CGFloat = 18
    /// The width with the orbit (the scene's square is slightly wider than its drawing).
    static let orbitWidth: CGFloat = 27

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(attention: Bool, logos: [TerminalLogo] = []) -> NSImage {
        let marks = logos.prefix(4).map(\.mark)
        let key = "\(attention) \(marks)"
        if let image = cache[key] { return image }
        let arts = marks.map { TerminalArt(ansi: $0) }
        // The calm face that reads at this size: its eyes look straight out (the resting face looks up and away, two
        // dashes at 14 points). Below 40 points the renderer leaves out its thinking dots.
        let mood: BlobMood = attention ? .attention : .working
        let onLight = picture(mood: mood, palette: .starlight(for: .light), logos: arts)
        let onDark = picture(mood: mood, palette: .starlight, logos: arts)
        let image = NSImage(size: onLight.size, flipped: false) { rect in
            // The appearance the menu bar draws this image with, now (the drawing handler runs at every draw).
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? onDark : onLight).draw(in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = attention ? "Agent Hub: a session needs you" : "Agent Hub"
        cache[key] = image
        return image
    }

    /// The icon for one kind of menu bar, at 1× and 2×: Starlight's sphere is the same on both, the orbit and the
    /// badge are inked for the background (`BlobPalette.starlight(for:)`).
    @MainActor
    static func picture(mood: BlobMood, palette: BlobPalette, logos: [TerminalArt]) -> NSImage {
        let orbit = !logos.isEmpty
        // The ball is 2r of the renderer's box: 130 of 250 units inside the orbit, 130 of 184 without it.
        let side = ball * (orbit ? BlobRenderer.orbitBox : BlobRenderer.plainBox) / (2 * BlobRenderer.r)
        let size = CGSize(width: orbit ? orbitWidth : height, height: height)
        let scene = Canvas { context, canvas in
            var square = context
            square.translateBy(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2)
            BlobRenderer.draw(square, size: CGSize(width: side, height: side), mood: mood, time: 0, palette: palette,
                              logos: logos, shadow: false)
        }
        .frame(width: size.width, height: size.height)
        let image = NSImage(size: size)
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: scene)
            renderer.scale = scale
            renderer.isOpaque = false
            guard let bitmap = renderer.cgImage else { continue }
            let representation = NSBitmapImageRep(cgImage: bitmap)
            representation.size = size
            image.addRepresentation(representation)
        }
        return image
    }
}
