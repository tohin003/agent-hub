import CoreGraphics
import Foundation
import SwiftUI

// The blob's body, ported from the open-source avatar engine bloub (github.com/jeremy-prt/bloub: skins.ts "cercle",
// shape.ts), by way of Pebble Remote's Swift port (PebbleDesign/Avatar/AvatarShape.swift).
//
// bloub is MIT-licensed:
//   MIT License. Copyright (c) 2026 Jérémy Perret.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
//   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or substantial portions of
//   the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
//   THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.
// The same notice covers BlobFace.swift, BlobPose.swift, BlobRenderer.swift and BlobView.swift, which port face.ts,
// expressions.ts, states.ts and engine.ts.

/// Coordinates follow the engine: y down, centred on the ball, whose resting radius is `scale` = 65 units (bloub's
/// `new BotEngine(65, ...)`). The renderer fits a box of these units to the view.
nonisolated enum BlobShape {
    static let samples = 64
    static let scale: Double = 65

    static let angles: [Double] = (0..<samples).map { Double($0) / Double(samples) * 2 * .pi }

    /// bloub's "cercle" (skins.ts `SHAPES[0]`): every radius 1, the reference near-perfect circle the engine's other
    /// shapes are measured against.
    static let circleRadii = [Double](repeating: 1, count: samples)

    /// The profile's radius in any direction, between the two nearest samples (`radiusAtAngle`).
    static func radius(at angle: Double, radii: [Double] = circleRadii) -> Double {
        let n = Double(radii.count)
        var unit = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        if unit < 0 { unit += 1 }
        let t = unit * n
        let i = Int(t.rounded(.down)) % radii.count
        let j = (i + 1) % radii.count
        let f = t - t.rounded(.down)
        return radii[i] + (radii[j] - radii[i]) * f
    }

    /// The body's points: the profile, squashed in screen space, scaled and offset (`toPoints`).
    static func points(radii: [Double] = circleRadii, sx: Double = 1, sy: Double = 1, cx: Double = 0, cy: Double = 0)
        -> [CGPoint]
    {
        var out: [CGPoint] = []
        out.reserveCapacity(radii.count)
        for (r, a) in zip(radii, angles) {
            out.append(CGPoint(x: (r * cos(a) * sx + cx) * scale, y: (r * sin(a) * sy + cy) * scale))
        }
        return out
    }

    /// A closed Catmull-Rom curve through the points (`closedPath`, tension 1/6): smooth to the pixel at any size.
    static func closedPath(_ pts: [CGPoint], tension: Double = 1.0 / 6) -> Path {
        var path = Path()
        let n = pts.count
        guard n >= 3 else { return path }
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension, y: p1.y + (p2.y - p0.y) * tension)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension, y: p2.y - (p3.y - p1.y) * tension)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// A capsule (stadium) centred on the origin: the exact shape of the eyes (`capsulePath`).
    static func capsule(width: Double, height: Double) -> Path {
        let w = max(width, 0.01), h = max(height, 0.01)
        let r = min(w, h) / 2
        return Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: r, style: .circular)
    }
}
