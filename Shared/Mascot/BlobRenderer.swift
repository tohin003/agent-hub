import SwiftUI

// Draws the blob, ported from bloub's engine.ts (`sample`: the body, the eyes on their sphere, the badge in its notch)
// and Pebble Remote's AvatarRenderer.swift (the cues), lit as a glossy Starlight sphere for Agent Hub.
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

/// One frame of the blob: everything the renderer needs, as a value, so a still icon and the live view draw alike.
nonisolated struct BlobFrame: Sendable {
    struct CueLayer: Sendable {
        var cue: BlobCue
        var opacity: Double
    }

    var pose: BlobPose
    /// The face to draw (already blended between poses).
    var face: BlobExpression
    /// The movement inside the pose (already blended).
    var motion: BlobMotion
    /// Seconds into the animation: drives blinks, drift and breath.
    var seconds: Double
    /// A still frame: no motion, no drift, eyes open (Reduce Motion, or `animated: false`).
    var still: Bool
    /// A blink forced by a pose change: lid openness, 1 when there is none.
    var lid = 1.0
    /// The badge's scale: 0 hidden, 1 shown (a little more while it pops in).
    var badge = 0.0
    /// Seconds since the badge settled, for its pulse; nil while it pops in, or when it shouldn't pulse.
    var badgePulse: Double?
    /// The cues, crossfading between poses.
    var cues: [CueLayer] = []
    /// Where something outside the pose leads the eyes (a finger), already caught up to this instant.
    var look = BlobLook.none
    /// How much of the resting drift the pose keeps.
    var wander = 1.0
    /// The agents' orbit: how far it has turned (radians) and how lit it is.
    var orbitPhase = 0.0
    var orbitLight = 1.0
    /// A soft-body squish from a touch: positive flatter (pressed), negative taller (springing back).
    var squish = 0.0

    /// The frame `seconds` into a pose held since time 0, with no blending: what icons and previews draw.
    static func steady(_ pose: BlobPose, seconds: Double, still: Bool) -> BlobFrame {
        let t = still ? 0 : seconds
        let visual = BlobVisual.of(pose)
        return BlobFrame(
            pose: pose, face: BlobVisual.face(pose, at: t, still: still),
            motion: BlobMotion.of(pose, seconds: t, reduced: still), seconds: t, still: still,
            // The pulse's ring starts out faded, so a still frame at time 0 shows a clean badge.
            badge: visual.badge ? 1 : 0, badgePulse: visual.badge && !still ? t + 1.6 : nil,
            cues: visual.cue == .none ? [] : [CueLayer(cue: visual.cue, opacity: 1)], wander: visual.wander,
            orbitPhase: t * visual.orbitSpeed, orbitLight: visual.orbitLight)
    }
}

nonisolated enum BlobRenderer {
    static let r = BlobShape.scale
    /// The square box, in engine units, fitted to the view: the ball and its cues, or the ball inside the agents' orbit.
    static let plainBox = 184.0
    static let orbitBox = 250.0
    /// Below this side (points) the blob keeps to the essentials, so 26-point list rows stay crisp and cheap: no cues,
    /// no catchlights, no badge pulse, no orbit wobble.
    static let fineDetail = 40.0

    /// Draws the blob filling `size` (a square works best) as it looks `time` seconds into `mood`: the API for still
    /// frames (app icons, the menu bar). `logos`: the agents' own logos (as their CLIs draw them) to fly on a tilted
    /// orbit around the blob, up to four; without them there is no orbit.
    static func draw(_ context: GraphicsContext, size: CGSize, mood: BlobMood, time: Double, palette: BlobPalette,
                     logos: [TerminalArt] = [], shadow: Bool = true) {
        draw(context, size: size, frame: .steady(BlobPose(mood), seconds: time, still: false), palette: palette,
             logos: logos.prefix(4).map { BlobLogoArt($0) }, shadow: shadow)
    }

    static func draw(_ context: GraphicsContext, size: CGSize, frame: BlobFrame, palette: BlobPalette,
                     logos: [BlobLogoArt], shadow: Bool) {
        let side = min(size.width, size.height)
        guard side > 0 else { return }
        let fine = side >= fineDetail
        let box = logos.isEmpty ? plainBox : orbitBox
        var ctx = context
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: side / box, y: side / box)
        // The orbit and its logos weigh low (they ring the ball's lower half): lift the scene to balance it.
        if !logos.isEmpty { ctx.translateBy(x: 0, y: -8) }
        let point = box / side

        // Life at rest (engine.ts `sample`): the drift, the blinks, the breath.
        let life = BlobFace.liveliness(frame.still ? 0 : frame.seconds, wander: frame.look.wander * frame.wander)
        let lid = min(frame.still ? 1 : life.lid, frame.lid)
        let offX = frame.still ? 0 : life.driftX, offY = frame.still ? 0 : life.driftY
        let breath = frame.still ? 1 : life.breath

        // The body's movement: the pose's, then the touch's squish, the bottom staying on the ground.
        let motion = frame.motion
        let sx = motion.sx * (1 + 0.065 * frame.squish), sy = motion.sy * (1 - 0.09 * frame.squish)
        let lift = motion.y + r * 0.09 * frame.squish * motion.sy
        let transform = CGAffineTransform(translationX: motion.x, y: lift)
            .rotated(by: motion.tilt * .pi / 180)
            .scaledBy(x: sx, y: sy)
        let body = BlobShape.closedPath(BlobShape.points(sy: breath, cx: offX, cy: offY)).applying(transform)
        let center = CGPoint(x: offX * r, y: offY * r).applying(transform)
        let radius = r * (sx + sy * breath) / 2
        // Small blobs get slightly larger eyes, as small type gets a looser optical size, so they don't thin away.
        let eyes = eyePaths(frame.face, life: life, still: frame.still, lid: lid, offX: offX, offY: offY,
                            look: frame.look, scale: fine ? 1 : 1.15).map { $0.applying(transform) }

        // The badge sits on the outline, in a notch cut from the body (engine.ts `notif`, `notch`).
        var badge: (center: CGPoint, radius: Double)?
        if frame.badge > 0.001 {
            let angle = -42.0 * .pi / 180
            let fit = BlobShape.radius(at: angle) * 1.003
            let spot = CGPoint(x: (cos(angle) * fit + offX) * r, y: (sin(angle) * fit + offY) * r).applying(transform)
            // Larger when small, so a 26-point blob still shows it plainly.
            badge = (spot, 0.15 * r * (fine ? 1 : 1.3) * frame.badge * (sx + sy) / 2)
        }

        if shadow, palette.shaded {
            drawShadow(ctx, x: center.x, lift: motion.y, width: r * sx, palette: palette)
        }
        let orbit = logos.isEmpty ? nil : Orbit(frame: frame, fine: fine)
        if let orbit {
            drawOrbit(ctx, orbit, logos: logos, frame: frame, front: false, palette: palette, point: point)
        }
        drawBody(ctx, body: body, eyes: eyes, center: center, radius: radius, badge: badge, palette: palette,
                 fine: fine)
        if let badge {
            drawBadge(ctx, badge, pulse: fine ? frame.badgePulse : nil, palette: palette)
        }
        if let orbit {
            drawOrbit(ctx, orbit, logos: logos, frame: frame, front: true, palette: palette, point: point)
        }
        if fine {
            for layer in frame.cues where layer.opacity > 0.01 {
                var cues = ctx
                cues.opacity = layer.opacity
                drawCue(layer.cue, motion: motion, palette: palette, in: cues)
            }
        }
    }

    // MARK: - The face

    /// One eye as drawn: its outline, its opacity (fading as it turns past the limb), and how much catchlight it takes
    /// (none once it narrows into a squint or a closing lid).
    struct EyeMark {
        var path: Path
        var alpha: Double
        /// The catchlight: a small dot near the top of the eye, from the key light.
        var glint: Path
        var shine: Double

        func applying(_ transform: CGAffineTransform) -> EyeMark {
            EyeMark(path: path.applying(transform), alpha: alpha, glint: glint.applying(transform), shine: shine)
        }
    }

    /// The two eyes as paths in engine coordinates (engine.ts, "yeux").
    static func eyePaths(_ face: BlobExpression, life: BlobFace.Liveliness, still: Bool, lid: Double, offX: Double,
                         offY: Double, look: BlobLook, scale: Double = 1) -> [EyeMark] {
        // A look replaces the pose's direction as its mix rises; the drift adds after it, and the roll never follows
        // (engine.ts: the head's lean is the character's signature).
        let dYaw = still ? 0 : life.dYaw, dPitch = still ? 0 : life.dPitch, dRoll = still ? 0 : life.dRoll
        let gaze = BlobGaze(
            yaw: face.gaze.yaw + (look.yaw - face.gaze.yaw) * look.mix + dYaw,
            pitch: face.gaze.pitch + (look.pitch - face.gaze.pitch) * look.mix + dPitch,
            roll: face.gaze.roll + dRoll)
        let poses = BlobFace.eyePoses(gaze, scale: r, split: face.split)
        var out: [EyeMark] = []
        for (pose, shape) in [(poses.0, face.inner), (poses.1, face.outer)] where pose.depth > 0.02 {
            let fit = BlobShape.radius(at: atan2(pose.y, pose.x))
            // The eye's own tilt, composed with the sphere's tangent frame (Basis x Rot), so the two eyes can tilt in
            // mirror.
            let phi = shape.tilt * .pi / 180
            let cp = cos(phi), sp = sin(phi)
            let ax = pose.a * cp + pose.c * sp
            let ay = pose.b * cp + pose.d * sp
            let cx = -pose.a * sp + pose.c * cp
            let cy = -pose.b * sp + pose.d * cp
            // The blink is a vertical squash on screen, applied after all that.
            let open = min(lid, shape.open)
            let k = BlobFace.blinkScale(open)
            let matrix = CGAffineTransform(a: ax, b: ay * k, c: cx, d: cy * k,
                                           tx: pose.x * fit + offX * r, ty: pose.y * fit + offY * r)
            let aspect = shape.h * k / max(shape.w, 0.01)
            let shine = min(max((aspect - 0.62) / 0.35, 0), 1) * min(max((open - 0.55) / 0.3, 0), 1)
            // In the eye's own frame: near its top end, a little toward the light.
            let w = shape.w * r * scale, h = shape.h * r * scale
            let dot = min(w, h) * 0.19
            let spot = CGPoint(x: -0.17 * w, y: -h / 2 + min(w, h) * 0.4)
            let glint = Path(ellipseIn: CGRect(x: spot.x - dot, y: spot.y - dot, width: 2 * dot, height: 2 * dot))
            out.append(EyeMark(path: BlobShape.capsule(width: w, height: h).applying(matrix),
                               alpha: min(max(pose.depth / 0.12, 0), 1), glint: glint.applying(matrix), shine: shine))
        }
        return out
    }

    // MARK: - The body

    /// The sphere: a key light from the upper left falling off to a warm core shadow, light bounced back onto the lower
    /// rim, a soft darkening at the limb, the eyes, then the gloss on top (a soft specular and a thin rim light).
    static func drawBody(_ context: GraphicsContext, body: Path, eyes: [EyeMark], center c: CGPoint,
                         radius rho: Double, badge: (center: CGPoint, radius: Double)?, palette: BlobPalette,
                         fine: Bool) {
        var ctx = context
        if let badge {
            // Everything but a ring around the badge (even-odd: the box minus the notch).
            let notch = badge.radius + 0.054 * r
            var mask = Path(CGRect(x: -1000, y: -1000, width: 2000, height: 2000))
            mask.addEllipse(in: CGRect(x: badge.center.x - notch, y: badge.center.y - notch, width: 2 * notch,
                                       height: 2 * notch))
            ctx.clip(to: mask, style: FillStyle(eoFill: true))
        }

        guard palette.shaded else {
            ctx.drawLayer { layer in
                layer.fill(body, with: .color(palette.body))
                if palette.eyesCutOut { layer.blendMode = .destinationOut }
                for eye in eyes {
                    layer.fill(eye.path, with: .color((palette.eyesCutOut ? Color.black : palette.eye).opacity(eye.alpha)))
                }
            }
            return
        }

        func circle(_ center: CGPoint, _ radius: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        func at(_ dx: Double, _ dy: Double) -> CGPoint { CGPoint(x: c.x + dx * rho, y: c.y + dy * rho) }

        // Key light, up and to the left: from the lit pole through the champagne body tone to the shade on the far
        // side (light, halftone, core shadow; the reflected light comes next).
        let lit = at(-0.4, -0.45)
        let reach = 1.6 * rho
        ctx.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.highlight, location: 0),
                .init(color: palette.highlight, location: 0.08),
                .init(color: palette.body, location: 0.3),
                .init(color: palette.shade, location: 0.55),
                .init(color: palette.depth, location: 0.8),
                .init(color: palette.depth, location: 1),
            ]), center: lit, startRadius: 0, endRadius: reach))

        var inside = ctx
        inside.clip(to: body)
        let cover = Path(body.boundingRect.insetBy(dx: -4, dy: -4))
        // The core shadow deepens on the far side, warm: a hint of the champagne's depth.
        inside.fill(cover, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.shadow.opacity(0), location: 0.78),
                .init(color: palette.shadow.opacity(0.13), location: 0.97),
            ]), center: lit, startRadius: 0, endRadius: reach))
        // Light bounced back from the ground onto the lower rim, golden, lifting it out of the core shadow.
        inside.fill(cover, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.glow.opacity(0), location: 0.76),
                .init(color: palette.glow.opacity(0.62), location: 1),
            ]), center: at(-0.1, -0.32), startRadius: 0, endRadius: 1.32 * rho))
        // The limb: a soft darkening right at the silhouette, which rounds the sphere and gives it an edge on light
        // backgrounds.
        inside.fill(cover, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.depth.opacity(0), location: 0.84),
                .init(color: palette.depth.opacity(0.22), location: 0.98),
                .init(color: palette.depth.opacity(0.3), location: 1),
            ]), center: c, startRadius: 0, endRadius: rho))

        // The eyes, painted on the sphere under its gloss, each with a catchlight from the key light when open.
        for eye in eyes {
            inside.fill(eye.path, with: .color(palette.eye.opacity(eye.alpha)))
            if fine, eye.shine > 0.01 {
                inside.fill(eye.glint, with: .color(.white.opacity(0.92 * eye.shine * eye.alpha)))
            }
        }

        // The gloss: a soft sheen where the key light reflects, a brighter, tighter core inside it, and a glint.
        var specular = inside
        specular.translateBy(x: c.x - 0.38 * rho, y: c.y - 0.46 * rho)
        specular.rotate(by: .radians(-0.7))
        specular.scaleBy(x: 1, y: 0.62)
        let sheen = 0.55 * rho
        specular.fill(circle(.zero, sheen), with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.35), location: 0),
                .init(color: .white.opacity(0.14), location: 0.45),
                .init(color: .white.opacity(0), location: 1),
            ]), center: .zero, startRadius: 0, endRadius: sheen))
        let core = 0.16 * rho
        specular.fill(circle(.zero, core), with: .radialGradient(
            Gradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.85), location: 0.55),
                .init(color: .white.opacity(0), location: 1),
            ]), center: .zero, startRadius: 0, endRadius: core))
        if fine {
            let glint = 0.05 * rho
            let spot = CGPoint(x: -0.02 * rho, y: 0)
            specular.fill(circle(spot, glint), with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ]), center: spot, startRadius: 0, endRadius: glint))
        }
        // The rim light: a thin bright crescent hugging the lower right edge, so the blob stands off a dark background.
        inside.fill(cover, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.rim.opacity(0), location: 1.025 / 1.086),
                .init(color: palette.rim.opacity(0.85), location: 1),
            ]), center: at(-0.05, -0.07), startRadius: 0, endRadius: 1.086 * rho))
    }

    /// The contact shadow: a soft ellipse on the ground under the ball, smaller and fainter as the ball rises.
    static func drawShadow(_ context: GraphicsContext, x: Double, lift: Double, width: Double, palette: BlobPalette) {
        let rise = min(max(-lift / 12, 0), 1)
        var shadow = context
        shadow.translateBy(x: x, y: r + 5)
        shadow.scaleBy(x: 1, y: 0.2)
        let reach = width * (0.92 - 0.12 * rise)
        shadow.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: palette.shadow.opacity(0.34 * (1 - 0.4 * rise)), location: 0),
                            .init(color: palette.shadow.opacity(0.16 * (1 - 0.4 * rise)), location: 0.45),
                            .init(color: palette.shadow.opacity(0), location: 1),
                        ]), center: .zero, startRadius: 0, endRadius: reach))
    }

    // MARK: - The badge

    /// The "needs you" badge: a small glossy sphere of its own, with a soft ring pulsing out from it.
    static func drawBadge(_ context: GraphicsContext, _ badge: (center: CGPoint, radius: Double), pulse: Double?,
                          palette: BlobPalette) {
        let c = badge.center, d = badge.radius
        guard d > 0.01 else { return }
        func circle(_ radius: Double) -> Path {
            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        }
        if let pulse {
            // One ring every two seconds, growing and fading.
            let p = (pulse / 2).truncatingRemainder(dividingBy: 1)
            context.stroke(circle(d * (1.15 + 1.1 * p)), with: .color(palette.badge.opacity(0.5 * (1 - p) * (1 - p))),
                           lineWidth: d * (0.32 - 0.2 * p))
        }
        context.fill(circle(d), with: .color(palette.badge))
        guard palette.shaded else { return }
        context.fill(circle(d), with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.55), location: 0),
                .init(color: .white.opacity(0), location: 0.55),
                .init(color: .black.opacity(0), location: 0.7),
                .init(color: .black.opacity(0.16), location: 1),
            ]), center: CGPoint(x: c.x - 0.35 * d, y: c.y - 0.4 * d), startRadius: 0, endRadius: 1.4 * d))
    }

    // MARK: - The orbit

    /// The agents' orbit: a thin ellipse tilted to rise to the right, crossing the ball's lower half like a planet's
    /// ring, its back half hidden behind the ball.
    struct Orbit {
        var center: CGPoint
        var rx = 104.0
        var ry = 30.0
        var tilt: Double
        var phase: Double

        init(frame: BlobFrame, fine: Bool) {
            let wobble = fine && !frame.still ? 0.035 * sin(frame.seconds * 0.41) : 0
            center = CGPoint(x: frame.motion.x, y: frame.motion.y + 16)
            tilt = -0.27 + 0.6 * frame.motion.tilt * .pi / 180 + wobble
            phase = frame.orbitPhase
        }

        func point(_ angle: Double) -> CGPoint {
            let x = rx * cos(angle), y = ry * sin(angle)
            return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
        }

        func arc(from a: Double, to b: Double) -> Path {
            var path = Path()
            let steps = 48
            for i in 0...steps {
                let p = point(a + (b - a) * Double(i) / Double(steps))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        /// Where each logo flies at rest, spaced so that all of them show: those behind the ball stay out at its
        /// sides. Each angle is on the orbit, 0 at its right end, increasing toward the front.
        static func restAngles(_ count: Int) -> [Double] {
            let degrees: [Double] = switch count {
            case 1: [40]
            case 2: [35, 215]
            case 3: [95, 215, 335]
            default: [55, 125, 185, 335]
            }
            return degrees.map { $0 * .pi / 180 }
        }
    }

    static func drawOrbit(_ context: GraphicsContext, _ orbit: Orbit, logos: [BlobLogoArt], frame: BlobFrame,
                          front: Bool, palette: BlobPalette, point: Double) {
        let light = frame.orbitLight
        let width = max(0.9 * point, 1.15)
        let line = front ? orbit.arc(from: 0, to: .pi) : orbit.arc(from: .pi, to: 2 * .pi)
        // Brightest nearest the viewer, faintest behind, the same where the halves meet (along x, depth follows the
        // ends of the orbit closely enough).
        let ends = 0.34 * light, middle = (front ? 0.52 : 0.18) * light
        context.stroke(line, with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.orbit.opacity(ends), location: 0),
                .init(color: palette.orbit.opacity(middle), location: 0.5),
                .init(color: palette.orbit.opacity(ends), location: 1),
            ]), startPoint: orbit.point(.pi), endPoint: orbit.point(0)),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt))

        let angles = Orbit.restAngles(logos.count).map { $0 + orbit.phase }
        let placed = zip(logos, angles)
            .map { (art: $0, angle: $1, depth: sin($1)) }
            .filter { ($0.depth >= 0) == front }
            .sorted { $0.depth < $1.depth }
        for item in placed {
            let near = (item.depth + 1) / 2
            drawTile(context, item.art, at: orbit.point(item.angle), side: 44 * (0.8 + 0.2 * near),
                     veil: 1 - (1 - 0.3 * (1 - near)) * (0.35 + 0.65 * light), shadow: front, point: point)
        }
    }

    /// One agent's logo on a small dark tile, as its terminal shows it, with a hairline glass edge lit from above.
    /// `veil` (0...1) recedes it, farther back or asleep, by misting the logo in the tile's own colour: the tile stays
    /// opaque, so nothing behind it ghosts through on a light background.
    static func drawTile(_ context: GraphicsContext, _ art: BlobLogoArt, at p: CGPoint, side: Double, veil: Double,
                         shadow: Bool, point: Double) {
        let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        let shape = Path(roundedRect: rect, cornerRadius: side * 0.27, style: .continuous)
        if shadow {
            // A soft shadow just below it (a squashed radial gradient, no blur): it floats in front of the ball.
            var shade = context
            shade.translateBy(x: rect.midX, y: rect.maxY - side * 0.12)
            shade.scaleBy(x: 1, y: 0.42)
            let reach = side * 0.62
            shade.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                       with: .radialGradient(
                           Gradient(colors: [.black.opacity(0.3), .black.opacity(0.12), .black.opacity(0)]),
                           center: .zero, startRadius: 0, endRadius: reach))
        }
        let ground = art.background ?? Color(red: 0.09, green: 0.09, blue: 0.1)
        context.fill(shape, with: .color(ground))
        art.draw(in: context, rect: rect.insetBy(dx: side * 0.15, dy: side * 0.15))
        if veil > 0.01 {
            context.fill(shape, with: .color(ground.opacity(min(veil, 1) * 0.85)))
        }
        context.stroke(shape, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.34 * (1 - 0.5 * veil)), .white.opacity(0.1)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)),
                       lineWidth: max(0.7 * point, side * 0.028))
    }

    // MARK: - The cues

    /// The cue beside the blob (Avatar.vue `.avatar-cues`); it stays put while the body moves.
    static func drawCue(_ cue: BlobCue, motion: BlobMotion, palette: BlobPalette, in ctx: GraphicsContext) {
        let ink = palette.cue
        let pulse = [motion.pulse0, motion.pulse1, motion.pulse2]
        switch cue {
        case .none:
            break
        case .thought:
            for i in 1...3 {
                let p = pulse[i - 1]
                let radius = 2.6 + 1.1 * p
                let center = CGPoint(x: -20 + Double(i) * 10, y: -80)
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius,
                                                height: 2 * radius)),
                         with: .color(ink.opacity(0.35 + 0.65 * p)))
            }
        case .celebrate:
            let spots = [CGPoint(x: -60, y: -48), CGPoint(x: 60, y: -50), CGPoint(x: 2, y: -81)]
            var plus = Path()
            plus.move(to: CGPoint(x: -5, y: 0))
            plus.addLine(to: CGPoint(x: 5, y: 0))
            plus.move(to: CGPoint(x: 0, y: -5))
            plus.addLine(to: CGPoint(x: 0, y: 5))
            for (i, spot) in spots.enumerated() {
                var mark = ctx
                mark.translateBy(x: spot.x, y: spot.y)
                mark.rotate(by: .degrees((pulse[i] - 0.5) * 40))
                mark.scaleBy(x: 0.75 + 0.25 * pulse[i], y: 0.75 + 0.25 * pulse[i])
                mark.stroke(plus, with: .color(ink), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            }
        case .sleep:
            var z = Path()
            z.move(to: CGPoint(x: 41, y: -66))
            z.addLine(to: CGPoint(x: 50, y: -66))
            z.addLine(to: CGPoint(x: 41, y: -57))
            z.addLine(to: CGPoint(x: 50, y: -57))
            z.move(to: CGPoint(x: 54, y: -79))
            z.addLine(to: CGPoint(x: 61, y: -79))
            z.addLine(to: CGPoint(x: 54, y: -72))
            z.addLine(to: CGPoint(x: 61, y: -72))
            ctx.stroke(z, with: .color(ink.opacity(0.45 + 0.45 * pulse[0])),
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        case .sigh:
            var drop = Path()
            drop.move(to: CGPoint(x: -62, y: -50))
            drop.addQuadCurve(to: CGPoint(x: -62, y: -37), control: CGPoint(x: -67.5, y: -41.5))
            drop.addQuadCurve(to: CGPoint(x: -62, y: -50), control: CGPoint(x: -56.5, y: -41.5))
            ctx.fill(drop, with: .color(ink.opacity(0.75)))
        }
    }
}
