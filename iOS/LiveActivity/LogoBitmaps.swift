import SwiftUI
import UIKit

/// The agents' logos as tiny pictures for the Live Activity (it can carry only 4 KB): each logo's terminal art drawn
/// into a few pixels, kept as raw RGB.
@MainActor
enum LogoBitmaps {
    static func make(_ logos: [TerminalLogo], pixels: Int = 12) -> [Data] {
        logos.prefix(4).compactMap { logo in
            let art = TerminalArt(ansi: logo.mark)
            let renderer = ImageRenderer(content: Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(art.background ?? Color(red: 0.1, green: 0.1, blue: 0.12)))
                TerminalArtRenderer.draw(art, in: context, rect: rect.insetBy(dx: size.width * 0.06, dy: size.height * 0.06),
                                         defaultForeground: .white)
            }.frame(width: CGFloat(pixels), height: CGFloat(pixels)))
            renderer.scale = 1
            guard let image = renderer.cgImage else { return nil }
            return rgb(image, pixels: pixels)
        }
    }

    /// Raw RGB, row by row.
    private static func rgb(_ image: CGImage, pixels: Int) -> Data? {
        var rgba = [UInt8](repeating: 0, count: pixels * pixels * 4)
        guard let context = CGContext(data: &rgba, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        var out = Data(capacity: pixels * pixels * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            out.append(contentsOf: rgba[index..<index + 3])
        }
        return out
    }
}
