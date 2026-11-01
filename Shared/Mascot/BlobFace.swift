import CoreGraphics
import Foundation

// The blob's face, ported from bloub (face.ts, expressions.ts, math.ts and engine.ts's `Look`) by way of Pebble
// Remote's Swift port (AvatarFace.swift, AvatarLook.swift).
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
//
// Two capsule eyes painted on a sphere, not laid flat: each eye takes the sphere's tangent frame for the head's
// orientation, projected orthographically, which gives the face its volume. Expressions move four levers: the head's
// orientation, the eyes' spacing, their proportions, and each eye's own tilt.

/// Head orientation in degrees: yaw right, pitch up, roll.
nonisolated struct BlobGaze: Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var roll: Double

    static func lerp(_ a: BlobGaze, _ b: BlobGaze, _ t: Double) -> BlobGaze {
        BlobGaze(yaw: a.yaw + (b.yaw - a.yaw) * t, pitch: a.pitch + (b.pitch - a.pitch) * t,
                 roll: a.roll + (b.roll - a.roll) * t)
    }
}

/// One eye: width and height in ball radii, openness (1 open), tilt in degrees (top to the right).
nonisolated struct BlobEyeShape: Equatable, Sendable {
    var w: Double
    var h: Double
    var open: Double = 1
    var tilt: Double = 0

    static func lerp(_ a: BlobEyeShape, _ b: BlobEyeShape, _ t: Double) -> BlobEyeShape {
        BlobEyeShape(w: a.w + (b.w - a.w) * t, h: a.h + (b.h - a.h) * t, open: a.open + (b.open - a.open) * t,
                     tilt: a.tilt + (b.tilt - a.tilt) * t)
    }
}

/// A face: where the head looks, how far apart the eyes sit (half the split, degrees on the sphere), and the two eyes
/// (inner, outer).
nonisolated struct BlobExpression: Equatable, Sendable {
    var gaze: BlobGaze
    var split: Double
    var inner: BlobEyeShape
    var outer: BlobEyeShape

    static func lerp(_ a: BlobExpression, _ b: BlobExpression, _ t: Double) -> BlobExpression {
        BlobExpression(gaze: .lerp(a.gaze, b.gaze, t), split: a.split + (b.split - a.split) * t,
                       inner: .lerp(a.inner, b.inner, t), outer: .lerp(a.outer, b.outer, t))
    }

    /// Both eyes alike, their tilts mirrored (expressions.ts `pair`).
    private static func pair(_ w: Double, _ h: Double, tilt: Double = 0, open: Double = 1) -> (BlobEyeShape, BlobEyeShape) {
        (BlobEyeShape(w: w, h: h, open: open, tilt: tilt), BlobEyeShape(w: w, h: h, open: open, tilt: -tilt))
    }

    private init(gaze: BlobGaze, split: Double, eyes: (BlobEyeShape, BlobEyeShape)) {
        self.init(gaze: gaze, split: split, inner: eyes.0, outer: eyes.1)
    }

    init(gaze: BlobGaze, split: Double, inner: BlobEyeShape, outer: BlobEyeShape) {
        self.gaze = gaze
        self.split = split
        self.inner = inner
        self.outer = outer
    }

    // face.ts
    static let eyeSplit = 15.46
    static let eyeWidth = 0.186
    static let eyeHeight = 0.412
    static let restGaze = BlobGaze(yaw: 28.49, pitch: 28.62, roll: -13)

    // expressions.ts
    /// The resting face, measured frame by frame on bloub's reference video: looking up and to the right, head leaning.
    static let neutre = BlobExpression(
        gaze: restGaze, split: eyeSplit,
        inner: BlobEyeShape(w: eyeWidth, h: eyeHeight), outer: BlobEyeShape(w: eyeWidth, h: eyeHeight))
    static let attentif = BlobExpression(gaze: BlobGaze(yaw: 4, pitch: 5, roll: -4), split: 16, eyes: pair(0.21, 0.44))
    /// The tops of the eyes lean apart, the gaze drops.
    static let triste = BlobExpression(
        gaze: BlobGaze(yaw: 3, pitch: -13, roll: 0), split: 16, eyes: pair(0.22, 0.4, tilt: -28))

    // Agent Hub's own, in the same envelope (expressions.ts: widths 0.8 to 2.7 times neutral, heights 0.3 to 1.5).
    /// Asleep: bloub's "somnolent" (lids half down, through `open`, the same vertical squash as a blink) with the lids
    /// nearly shut and the eyes a little wider, so they read as closed rather than as dots.
    static let endormi = BlobExpression(
        gaze: BlobGaze(yaw: 6, pitch: -9, roll: -3), split: 16, eyes: pair(0.24, 0.42, open: 0.2))
    /// Working: eyes on the work, a little below straight ahead; the reading saccades move this gaze (BlobPose).
    static let affaire = BlobExpression(gaze: BlobGaze(yaw: 0, pitch: -6, roll: -5), split: 16, eyes: pair(0.2, 0.42))
    /// Thinking it over: up and to the side, head leaning, one eye a touch narrower (between bloub's "curieux" and
    /// "neutre").
    static let pensif = BlobExpression(
        gaze: BlobGaze(yaw: 20, pitch: 21, roll: -14), split: 16,
        inner: BlobEyeShape(w: 0.21, h: 0.43, tilt: -6), outer: BlobEyeShape(w: 0.19, h: 0.36, tilt: -6))
    /// Delighted: big bright eyes on you, tops leaning apart (bloub's "excite", turned to face the person). Capsules
    /// can't curve into a smile, and bloub's squints ("heureux") read as smug on a sphere.
    static let ravi = BlobExpression(gaze: BlobGaze(yaw: 4, pitch: 4, roll: -4), split: 19, eyes: pair(0.38, 0.52, tilt: -8))
    /// Needs you: the round eyes of bloub's "notify" state (states.ts, there looking away from the badge), turned toward
    /// the person instead, so the blob asks them.
    static let appel = BlobExpression(
        gaze: BlobGaze(yaw: -9, pitch: 3, roll: -8), split: 18.5, eyes: pair(0.42, 0.45))
}

/// One eye placed on the sphere: centre (engine units), tangent frame `a b c d` (SVG matrix order), depth (> 0 is
/// visible).
nonisolated struct BlobEyePose: Sendable {
    var x: Double
    var y: Double
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var depth: Double
}

nonisolated enum BlobFace {
    typealias Vec3 = (x: Double, y: Double, z: Double)

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Turns two orthonormal vectors in their common plane (face.ts `spin`).
    private static func spin(_ u: Vec3, _ v: Vec3, _ angle: Double) -> (Vec3, Vec3) {
        let c = cos(angle), s = sin(angle)
        return (
            (u.x * c + v.x * s, u.y * c + v.y * s, u.z * c + v.z * s),
            (v.x * c - u.x * s, v.y * c - u.y * s, v.z * c - u.z * s)
        )
    }

    /// The head's frame, then both eyes' (face.ts `eyePoses`). Screen frame: x right, y down, z toward the viewer.
    static func eyePoses(_ gaze: BlobGaze, scale: Double, split: Double) -> (BlobEyePose, BlobEyePose) {
        var f: Vec3 = (0, 0, 1), right: Vec3 = (1, 0, 0), down: Vec3 = (0, 1, 0)
        (f, right) = spin(f, right, radians(gaze.yaw))
        (down, f) = spin(down, f, radians(gaze.pitch))
        (right, down) = spin(right, down, radians(gaze.roll))
        func build(_ side: Double) -> BlobEyePose {
            let (ef, er) = spin(f, right, radians(split * side))
            return BlobEyePose(x: ef.x * scale, y: ef.y * scale, a: er.x, b: er.y, c: down.x, d: down.y, depth: ef.z)
        }
        return (build(-1), build(1))
    }

    /// Seamless periodic 1D noise (math.ts `loopNoise`).
    static func loopNoise(_ t: Double, period: Double, seed: Double = 0) -> Double {
        let p = t / period * 2 * .pi
        return 0.55 * sin(p + seed) + 0.3 * sin(2 * p + seed * 1.7 + 1.1) + 0.15 * sin(3 * p + seed * 2.3 + 2.4)
    }

    /// Deterministic PRNG (mulberry32, math.ts `createRng`): the same sequence every time.
    struct Mulberry32 {
        var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// The blink calendar, drawn once (face.ts `BLINKS`): 1.9 to 4.6 s apart, sometimes a double blink.
    static let blinks: [Double] = {
        var rng = Mulberry32(seed: 0x5eed)
        var out: [Double] = []
        var t = 1.4
        while t < 900 {
            out.append(t)
            t += 1.9 + rng.next() * 2.7
            if rng.next() < 0.18 {
                out.append(t)
                t += 0.24
            }
        }
        return out
    }()

    static let blinkDuration = 0.18
    /// The calendar's length; later times wrap so the blob keeps blinking (face.ts stops after 15 minutes).
    static let blinkPeriod = 900.0

    /// Eye openness at time `t`: 1 open, 0 shut (fast close, slightly slower reopen).
    static func blinkLid(_ t: Double) -> Double {
        guard t.isFinite, t >= 0 else { return 1 }
        let local = t.truncatingRemainder(dividingBy: blinkPeriod)
        // The last blink starting at or before `local`.
        var lo = 0, hi = blinks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blinks[mid] <= local { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return 1 }
        let k = (local - blinks[lo - 1]) / blinkDuration
        guard k >= 0, k <= 1 else { return 1 }
        return k < 0.45 ? 1 - k / 0.45 : (k - 0.45) / 0.55
    }

    /// Life at rest (face.ts `liveliness`): slow gaze drift, blinks, a breath. A pure function of time.
    struct Liveliness {
        var dYaw: Double
        var dPitch: Double
        var dRoll: Double
        var lid: Double
        var driftX: Double
        var driftY: Double
        /// Vertical scale of the body: 1 ± a little.
        var breath: Double
    }

    /// `breath` is the depth of the breath: bloub's own (0.005) reads as stillness on a perfect sphere, so the blob
    /// breathes a little deeper, at the same slow 3.4 s.
    static func liveliness(_ t: Double, wander: Double = 1, blink: Bool = true, breath: Double = 0.011) -> Liveliness {
        Liveliness(
            dYaw: (loopNoise(t, period: 11.3, seed: 0.4) * 5.5 + loopNoise(t, period: 3.7, seed: 2.1) * 1.6) * wander,
            dPitch: (loopNoise(t, period: 9.1, seed: 1.3) * 4.2 + loopNoise(t, period: 4.3, seed: 0.7) * 1.3) * wander,
            dRoll: loopNoise(t, period: 13.7, seed: 3.2) * 2.2 * wander,
            lid: blink ? blinkLid(t) : 1,
            driftX: loopNoise(t, period: 7.9, seed: 1.9) * 0.006,
            driftY: loopNoise(t, period: 5.3, seed: 0.3) * 0.007,
            breath: 1 + sin(t / 3.4 * 2 * .pi) * breath
        )
    }

    /// A blink squashes the eye vertically on screen, never to nothing (face.ts `blinkScale`).
    static func blinkScale(_ lid: Double) -> Double { 0.06 + 0.94 * min(max(lid, 0), 1) }

    /// The ease-out the engine measured on its reference video (math.ts `easeOutQuint`).
    static func easeOutQuint(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 5)
    }

    static func easeOutCubic(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    static func easeInOutCubic(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
}

/// Where the eyes look when something outside the mood leads them: a finger on the blob (bloub's engine.ts `Look`; the
/// mapping is Pebble's companionPointer.ts `lookFor`).
///
/// `yaw` and `pitch` replace the mood's own direction as `mix` rises, so the eyes keep each expression's shape while the
/// finger decides where they point; the head's roll never follows. `wander` is what stays of the resting drift, so the
/// blob holds the finger's direction instead of seeming to search for it.
nonisolated struct BlobLook: Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var mix: Double
    var wander: Double

    /// The mood's own direction, with all of its drift.
    static let none = BlobLook(yaw: 0, pitch: 0, mix: 0, wander: 1)
    /// How long the eyes take to catch up with a new direction (engine.ts `LOOK_MORPH`).
    static let morph = 0.24
    /// Steps per half axis (companionPointer.ts `GAZE_STEPS`): 17 positions, so a trembling finger doesn't shake the eyes.
    static let steps = 8.0

    /// Toward a direction in screen terms, x right and y down, each in -1...1.
    static func toward(_ direction: CGVector) -> BlobLook {
        BlobLook(yaw: quantize(direction.dx) * 40, pitch: -quantize(direction.dy) * 30, mix: 0.8, wander: 0.1)
    }

    static func quantize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let q = (min(max(value, -1), 1) * steps).rounded() / steps
        return q == 0 ? 0 : q
    }

    static func lerp(_ a: BlobLook, _ b: BlobLook, _ t: Double) -> BlobLook {
        BlobLook(yaw: a.yaw + (b.yaw - a.yaw) * t, pitch: a.pitch + (b.pitch - a.pitch) * t,
                 mix: a.mix + (b.mix - a.mix) * t, wander: a.wander + (b.wander - a.wander) * t)
    }
}
