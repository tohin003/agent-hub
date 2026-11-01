import SwiftUI

// The live blob, ported from Pebble Remote's PebbleAvatar.swift and bloub's engine.ts (`setState`: blending from
// where the face was, a blink masking each change; `setLook`).
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

/// Agent Hub's mascot: a glossy Starlight sphere with bloub's face, alive in each mood.
///
/// - `mood` comes from a real state (an agent working, one needing you); changing it blends the face and the movement
///   over 0.45 s, masked by a blink.
/// - `animated`: animate the blobs the person is looking at; with `false`, or under Reduce Motion, it is a still frame.
/// - `logos`: the agents' own logos (read off their CLIs by the hub), up to four, flown on a tilted orbit around it.
///   Without logos there is no orbit.
/// - Decorative for VoiceOver: the words next to it carry the meaning.
///
/// Size it with `.frame(width:height:)`; it keeps a square aspect. Below 40 points it keeps to the essentials (no cues,
/// no catchlights, no badge pulse) so list rows stay crisp and cheap.
public struct BlobView: View {
    let pose: BlobPose
    let animated: Bool
    let logos: [BlobLogoArt]
    let look: CGVector?
    let pressed: Bool
    let jiggles: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var timeline = BlobTimeline()

    public init(mood: BlobMood = .idle, animated: Bool = true, logos: [TerminalLogo] = []) {
        self.init(pose: BlobPose(mood), animated: animated, logos: logos)
    }

    /// For `BlobTouchView`: a pose a finger brings, where the eyes look (x right, y down, each -1...1), whether a finger
    /// presses the blob, and a count that jiggles it each time it changes.
    init(pose: BlobPose, animated: Bool, logos: [TerminalLogo], look: CGVector? = nil, pressed: Bool = false,
         jiggles: Int = 0) {
        self.pose = pose
        self.animated = animated
        self.logos = logos.prefix(4).map { BlobLogoCache.shared.art(for: $0) }
        self.look = look
        self.pressed = pressed
        self.jiggles = jiggles
    }

    private var still: Bool { !animated || reduceMotion }

    public var body: some View {
        Group {
            if still {
                canvas(at: .now)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    canvas(at: context.date)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear { timeline.begin(pose) }
        .onChange(of: pose) { old, new in
            timeline.change(from: old, to: new, at: .now)
        }
        .onChange(of: look) { _, new in
            timeline.look(to: new.map(BlobLook.toward) ?? .none, at: .now)
        }
        .onChange(of: pressed) { _, new in
            timeline.press(new, at: .now)
        }
        .onChange(of: jiggles) {
            timeline.jiggle(at: .now)
        }
    }

    private func canvas(at date: Date) -> some View {
        let frame = timeline.frame(pose: pose, at: date, still: still)
        let palette = BlobPalette.starlight(for: colorScheme)
        let logos = logos
        return Canvas { context, size in
            BlobRenderer.draw(context, size: size, frame: frame, palette: palette, logos: logos, shadow: true)
        }
    }
}

/// When the blob's last changes happened, so each frame can blend from where it was. A pure function of time apart
/// from these dated changes (bloub's rule: external state comes in through dated setters, never read while sampling).
nonisolated struct BlobTimeline {
    /// The clock starts at a random point, so blobs side by side (list rows) don't blink and bob in unison.
    var start = Date(timeIntervalSinceNow: -Double.random(in: 0..<300))
    var pose: BlobPose?
    var changedAt = Date.distantPast
    var from = Snapshot()
    var blinkAt = Date.distantPast
    var badgeSince = Date.distantPast
    var badgeLeftAt = Date.distantPast
    var orbit = OrbitClock()
    var lookFrom = BlobLook.none
    var lookTo = BlobLook.none
    var lookChangedAt = Date.distantPast
    var squishFrom = 0.0
    var squishTo = 0.0
    var squishChangedAt = Date.distantPast

    /// How long a change of mood takes (the engine's `SHAPE_MORPH`).
    static let morph = 0.45
    /// How long a forced blink takes.
    static let blink = 0.2

    /// What a change blends from: the frame as it was.
    struct Snapshot {
        var face = BlobExpression.neutre
        var motion = BlobMotion()
        var cue = BlobCue.none
        var wander = 1.0
        var orbitLight = 1.0
    }

    /// The orbit's turn, continuous across changes of speed: the speed eases to the new one over `ramp`.
    struct OrbitClock {
        var base = 0.0
        var fromSpeed = BlobVisual.of(.idle).orbitSpeed
        var toSpeed = BlobVisual.of(.idle).orbitSpeed
        var changedAt = 0.0
        static let ramp = 1.2

        func phase(at seconds: Double) -> Double {
            let tau = max(0, seconds - changedAt)
            let ramp = Self.ramp
            if tau < ramp {
                return base + fromSpeed * tau + (toSpeed - fromSpeed) * tau * tau / (2 * ramp)
            }
            return base + fromSpeed * ramp + (toSpeed - fromSpeed) * ramp / 2 + toSpeed * (tau - ramp)
        }

        func speed(at seconds: Double) -> Double {
            let k = min(max((seconds - changedAt) / Self.ramp, 0), 1)
            return fromSpeed + (toSpeed - fromSpeed) * k
        }

        mutating func change(to speed: Double, at seconds: Double) {
            base = phase(at: seconds)
            fromSpeed = self.speed(at: seconds)
            toSpeed = speed
            changedAt = seconds
        }
    }

    func seconds(at date: Date) -> Double { max(0, date.timeIntervalSince(start)) }

    mutating func begin(_ pose: BlobPose) {
        guard self.pose == nil else { return }
        self.pose = pose
        let speed = BlobVisual.of(pose).orbitSpeed
        orbit = OrbitClock(base: 0, fromSpeed: speed, toSpeed: speed, changedAt: 0)
    }

    mutating func change(from old: BlobPose, to new: BlobPose, at now: Date) {
        let shown = frame(pose: pose ?? old, at: now, still: false)
        from = Snapshot(face: shown.face, motion: shown.motion,
                        cue: shown.cues.max { $0.opacity < $1.opacity }?.cue ?? .none, wander: shown.wander,
                        orbitLight: shown.orbitLight)
        changedAt = now
        // In bloub's reference video every change of shape is masked by a blink.
        blinkAt = now
        let wasBadge = BlobVisual.of(pose ?? old).badge, isBadge = BlobVisual.of(new).badge
        if isBadge && !wasBadge { badgeSince = now }
        if wasBadge && !isBadge { badgeLeftAt = now }
        orbit.change(to: BlobVisual.of(new).orbitSpeed, at: seconds(at: now))
        pose = new
    }

    /// The eyes take a new direction, catching up from where they look now (engine.ts `setLook`).
    mutating func look(to new: BlobLook, at now: Date) {
        lookFrom = look(at: now)
        lookTo = new
        lookChangedAt = now
    }

    /// A finger presses the blob (it gives, as a soft thing does) or lets go (it springs back with a wobble).
    mutating func press(_ down: Bool, at now: Date) {
        squishFrom = squish(at: now)
        squishTo = down ? 1 : 0
        squishChangedAt = now
    }

    /// A tap: a quick squish that wobbles out.
    mutating func jiggle(at now: Date) {
        squishFrom = max(squish(at: now), 0) + 0.75
        squishTo = 0
        squishChangedAt = now
    }

    /// Where the eyes look at `now`, the catch-up included (engine.ts `lookAtTime`).
    func look(at now: Date) -> BlobLook {
        let k = now.timeIntervalSince(lookChangedAt) / BlobLook.morph
        guard k < 1 else { return lookTo }
        return .lerp(lookFrom, lookTo, BlobFace.easeOutQuint(k))
    }

    /// A damped spring toward `squishTo`, starting from `squishFrom` (bouncy: a jelly, not a cushion).
    func squish(at now: Date) -> Double {
        let tau = now.timeIntervalSince(squishChangedAt)
        guard tau >= 0, tau < 3 else { return squishTo }
        let omega = 2 * Double.pi / 0.34, zeta = 0.3
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * tau)
        return squishTo + (squishFrom - squishTo) * decay * (cos(damped * tau) + zeta * omega / damped * sin(damped * tau))
    }

    func frame(pose requested: BlobPose, at now: Date, still: Bool) -> BlobFrame {
        if still { return .steady(requested, seconds: 0, still: true) }
        // `onChange` lands after the first frame of a new pose: until then keep drawing the pose on screen, so the
        // change blends from it instead of flashing the new face for a frame.
        let pose = self.pose ?? requested
        let seconds = seconds(at: now)
        let visual = BlobVisual.of(pose)
        let k = min(max(now.timeIntervalSince(changedAt) / Self.morph, 0), 1)
        let ease = BlobFace.easeOutQuint(k)

        var frame = BlobFrame.steady(pose, seconds: seconds, still: false)
        if k < 1 {
            frame.face = .lerp(from.face, frame.face, ease)
            frame.motion = .lerp(from.motion, frame.motion, ease)
            frame.wander = from.wander + (visual.wander - from.wander) * ease
            frame.orbitLight = from.orbitLight + (visual.orbitLight - from.orbitLight) * ease
            frame.cues = [BlobFrame.CueLayer(cue: from.cue, opacity: 1 - ease),
                          BlobFrame.CueLayer(cue: visual.cue, opacity: ease)].filter { $0.cue != .none }
        }
        let blink = now.timeIntervalSince(blinkAt) / Self.blink
        if blink >= 0, blink < 1 { frame.lid = abs(blink * 2 - 1) }

        // The badge pops in (to 114 % and back, as bloub's notify state), pulses once settled, and shrinks away.
        if visual.badge {
            let age = now.timeIntervalSince(badgeSince)
            if age < 0.45 {
                let p = max(age, 0) / 0.45
                frame.badge = BlobFace.easeOutCubic(age / 0.2) * (1 + 0.14 * sin(p * .pi) * (1 - p * 0.35))
                frame.badgePulse = nil
            } else {
                frame.badge = 1
                frame.badgePulse = badgeSince == .distantPast ? seconds : age - 0.45
            }
        } else {
            let gone = now.timeIntervalSince(badgeLeftAt) / 0.25
            if gone >= 0, gone < 1 {
                frame.badge = 1 - gone * gone * gone
            }
        }
        frame.look = look(at: now)
        // Before `begin` (the first frame) the steady phase, which `begin` continues.
        if self.pose != nil { frame.orbitPhase = orbit.phase(at: seconds) }
        frame.squish = squish(at: now)
        return frame
    }
}
