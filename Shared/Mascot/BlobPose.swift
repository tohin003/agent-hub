import Foundation

// The blob's poses and their movement, ported from Pebble Remote's AvatarPose.swift and AvatarMotion.swift (Pebble's
// companion table and avatarMotion.ts), with faces from bloub (expressions.ts, states.ts).
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

/// What the blob shows: one pose per mood (Pebble's poses: idle, working/thinking, question, finished, sleepy,
/// problem), plus the two a finger brings (`hover`, `tap`, as the Mac companion answers its pointer).
nonisolated enum BlobPose: String, Sendable, Hashable, CaseIterable {
    case idle, working, attention, happy, sleeping, problem
    /// A finger held on the resting blob: attentive, leaning in.
    case hover
    /// Just tapped: happy for a moment, with a little hop.
    case tap

    init(_ mood: BlobMood) {
        switch mood {
        case .idle: self = .idle
        case .working: self = .working
        case .attention: self = .attention
        case .happy: self = .happy
        case .sleeping: self = .sleeping
        case .problem: self = .problem
        }
    }
}

/// A small sign drawn beside the blob (Avatar.vue's `.avatar-cues`).
nonisolated enum BlobCue: Equatable, Sendable {
    case none, thought, celebrate, sleep, sigh
}

/// How a pose looks: its face, whether the "needs you" badge shows, its cue, and how the agents orbit.
nonisolated struct BlobVisual: Sendable {
    var badge: Bool
    var cue: BlobCue
    /// Radians a second.
    var orbitSpeed: Double
    /// 1 lit, lower for a dimmed orbit (asleep).
    var orbitLight: Double
    /// How much of the resting drift stays (busy eyes hold their targets).
    var wander: Double

    static func of(_ pose: BlobPose) -> BlobVisual {
        switch pose {
        case .idle: BlobVisual(badge: false, cue: .none, orbitSpeed: 0.3, orbitLight: 1, wander: 1)
        case .working: BlobVisual(badge: false, cue: .thought, orbitSpeed: 1.05, orbitLight: 1, wander: 0.3)
        case .attention: BlobVisual(badge: true, cue: .none, orbitSpeed: 0.2, orbitLight: 1, wander: 0.6)
        case .happy: BlobVisual(badge: false, cue: .celebrate, orbitSpeed: 0.62, orbitLight: 1, wander: 0.6)
        case .sleeping: BlobVisual(badge: false, cue: .sleep, orbitSpeed: 0, orbitLight: 0.45, wander: 0.4)
        case .problem: BlobVisual(badge: false, cue: .sigh, orbitSpeed: 0.1, orbitLight: 0.8, wander: 0.6)
        case .hover: BlobVisual(badge: false, cue: .none, orbitSpeed: 0.3, orbitLight: 1, wander: 0.1)
        case .tap: BlobVisual(badge: false, cue: .none, orbitSpeed: 0.3, orbitLight: 1, wander: 0.6)
        }
    }

    /// The face `t` seconds into the pose. Most poses hold one expression; working reads (saccades along three lines)
    /// then looks up to think, and sleeping's lids drift.
    static func face(_ pose: BlobPose, at t: Double, still: Bool) -> BlobExpression {
        switch pose {
        case .idle: return .neutre
        case .working: return still ? .affaire : workingFace(at: t)
        case .attention: return .appel
        case .happy: return .ravi
        case .sleeping:
            var face = BlobExpression.endormi
            if !still {
                // The lids drift, slowly, as in a doze.
                let open = 0.19 + 0.07 * cos(t / 7 * 2 * .pi)
                face.inner.open = open
                face.outer.open = open
            }
            return face
        case .problem: return .triste
        case .hover: return .attentif
        case .tap: return .ravi
        }
    }

    // Working: twelve fixations (three lines of four, left to right, each line a little lower), then a spell of
    // thinking (up and to the side), around again.
    static let fixation = 0.42
    static let fixations = 12
    static let saccade = 0.09
    static let thinking = 2.9
    static let thinkMorph = 0.45
    static var workingCycle: Double { Double(fixations) * fixation + thinking }

    private static func readingTarget(_ i: Int) -> (yaw: Double, pitch: Double) {
        let column = Double(i % 4), line = Double((i / 4) % 3)
        return (-16 + 10.5 * column, 1 - 3.5 * line)
    }

    static func workingFace(at t: Double) -> BlobExpression {
        let local = max(0, t).truncatingRemainder(dividingBy: workingCycle)
        let readEnd = Double(fixations) * fixation
        let gaze: (yaw: Double, pitch: Double)
        if local < readEnd {
            let i = min(Int(local / fixation), fixations - 1)
            let from = readingTarget(max(i - 1, 0)), to = readingTarget(i)
            let k = BlobFace.easeOutCubic((local - Double(i) * fixation) / saccade)
            gaze = (from.yaw + (to.yaw - from.yaw) * k, from.pitch + (to.pitch - from.pitch) * k)
        } else {
            // Hold the last fixation while the thought comes in, then (unseen, fully thinking) the first one, so the
            // next cycle starts where this one hands over.
            gaze = local < readEnd + thinkMorph ? readingTarget(fixations - 1) : readingTarget(0)
        }
        var reading = BlobExpression.affaire
        reading.gaze.yaw += gaze.yaw
        reading.gaze.pitch += gaze.pitch
        let into = BlobFace.easeInOutCubic((local - readEnd) / thinkMorph)
        let out = BlobFace.easeInOutCubic((workingCycle - local) / thinkMorph)
        let think = local < readEnd ? 0 : min(into, out)
        return .lerp(reading, .pensif, think)
    }
}

/// Movement inside a pose (Pebble's avatarMotion.ts). The mood chooses the pose; time only supplies movement within
/// it. Cue pulses run at 0.5 Hz and body sway stays at or under 0.5 Hz, far under three luminance changes a second.
/// Reduce Motion gives the same still frame at every time. Units are the engine's (the ball's radius is 65); `tilt`
/// is in degrees; `sx` and `sy` squash the body around its centre.
nonisolated struct BlobMotion: Equatable, Sendable {
    static let cueHertz = 0.5

    var x = 0.0
    var y = 0.0
    var tilt = 0.0
    var sx = 1.0
    var sy = 1.0
    /// Three cue elements pulsing in turn, each 0...1.
    var pulse0 = 0.6
    var pulse1 = 0.6
    var pulse2 = 0.6

    static func lerp(_ a: BlobMotion, _ b: BlobMotion, _ t: Double) -> BlobMotion {
        func mix(_ u: Double, _ v: Double) -> Double { u + (v - u) * t }
        return BlobMotion(x: mix(a.x, b.x), y: mix(a.y, b.y), tilt: mix(a.tilt, b.tilt), sx: mix(a.sx, b.sx),
                          sy: mix(a.sy, b.sy), pulse0: mix(a.pulse0, b.pulse0), pulse1: mix(a.pulse1, b.pulse1),
                          pulse2: mix(a.pulse2, b.pulse2))
    }

    static func of(_ pose: BlobPose, seconds: Double, reduced: Bool) -> BlobMotion {
        let t = reduced || !seconds.isFinite ? 0 : seconds
        func wave(_ hz: Double, _ offset: Double = 0) -> Double { sin(2 * .pi * hz * t + offset) }
        var m = BlobMotion()
        switch pose {
        case .working:
            m.tilt = 6 * wave(0.27)
            m.y = -3 * (1 + wave(0.37))
            // Squash and stretch with the bob: a little taller rising, a little rounder falling.
            let rising = wave(0.37, .pi / 2)
            m.sy = 1 + 0.014 * rising
            m.sx = 1 - 0.009 * rising
        case .attention:
            m.tilt = 5
            m.y = -2 * wave(0.32)
            // Every 3 s a small hop to call you: a crouch, a hop, a soft landing.
            let local = t.truncatingRemainder(dividingBy: 3)
            if local < 0.12 {
                squash(&m, 0.035 * sin(.pi * local / 0.12))
            } else if local < 0.52 {
                let p = (local - 0.12) / 0.4
                m.y -= 5 * sin(.pi * p)
                squash(&m, -0.022 * sin(.pi * p))
            } else if local < 0.68 {
                squash(&m, 0.04 * sin(.pi * (local - 0.52) / 0.16))
            }
        case .happy:
            // At the top of a hop at time 0, so a still frame (an icon) shows it in the air, not squashed.
            let w = wave(0.25, .pi / 2)
            m.y = -6 * abs(w)
            m.tilt = 5 * w
            // Round on landing, a touch taller in flight.
            let contact = max(0, 1 - abs(w) / 0.2)
            squash(&m, 0.05 * contact * contact - 0.016 * sqrt(max(0, 1 - w * w)) * (1 - contact))
        case .sleeping:
            m.tilt = 12 + 2 * wave(0.16)
            // Slow, deep sleep breaths on top of the resting one.
            let breath = wave(0.18)
            m.sy = 0.972 + 0.012 * breath
            m.sx = 1 + 0.006 * breath
        case .problem:
            m.tilt = -7
            m.y = 2
            m.sy = 0.985
            m.sx = 1.01
        case .tap:
            m.y = -3
        case .hover:
            m.tilt = 3
        case .idle:
            break
        }
        if reduced {
            m = BlobMotion()
            m.tilt = pose == .sleeping ? 8 : 0
        } else {
            let p = { (i: Double) in 0.5 + 0.5 * wave(cueHertz, -i * 2.1) }
            m.pulse0 = p(0)
            m.pulse1 = p(1)
            m.pulse2 = p(2)
        }
        return m
    }

    /// Squash (positive: rounder and lower, the bottom staying on the ground) or stretch (negative).
    private static func squash(_ m: inout BlobMotion, _ amount: Double) {
        m.sy *= 1 - amount
        m.sx *= 1 + amount * 0.7
        m.y += BlobShape.scale * amount
    }
}
