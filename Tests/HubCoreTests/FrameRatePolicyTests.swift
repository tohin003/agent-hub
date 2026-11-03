import CoreGraphics
import Foundation
import Testing

/// The frame rate following the link and the motion, and the refinement of a still screen.
@Suite("Frame rate and refinement")
struct FrameRatePolicyTests {
    let start = ContinuousClock.now

    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    // `refineNow` is mutating, and `#expect` runs a bare call on a constant copy, so its answer is compared with `== true`.

    /// The rate a policy settles on for a steady bitrate and motion (past both waits).
    func settled(_ policy: inout FrameRatePolicy, bitrate: Int, used: Double) -> Int {
        _ = policy.update(bitrate: bitrate, used: used, now: at(0))
        return policy.update(bitrate: bitrate, used: used, now: at(5_000))
    }

    @Test func theRateFollowsTheBitrateAndTheMotion() {
        for (bitrate, used, rate) in [(15_000_000, 0.1, 60), (8_000_000, 0.9, 60), (4_000_000, 0.1, 45), (4_000_000, 0.9, 30),
                                      (2_000_000, 0.1, 30), (2_000_000, 0.9, 20), (500_000, 0.9, 20)] {
            var policy = FrameRatePolicy(maximum: 60)
            #expect(settled(&policy, bitrate: bitrate, used: used) == rate, "\(bitrate) bit/s, \(used) used")
        }
    }

    /// A ProMotion display: 120 when the link carries it, 60 from 6 to 12 Mbit/s.
    @Test func aProMotionMacRunsAt120() {
        var fast = FrameRatePolicy(maximum: 120)
        #expect(settled(&fast, bitrate: 20_000_000, used: 0.5) == 120)
        var middle = FrameRatePolicy(maximum: 120)
        #expect(settled(&middle, bitrate: 8_000_000, used: 0.5) == 60)
        // What the phone asked for caps it too.
        var asked = FrameRatePolicy(maximum: 45)
        #expect(settled(&asked, bitrate: 20_000_000, used: 0.1) == 45)
    }

    /// Down after half a second, up after two, and a 10% band at each boundary.
    @Test func itTakesItsTime() {
        var policy = FrameRatePolicy(maximum: 60)
        #expect(policy.update(bitrate: 8_000_000, used: 0.2, now: at(0)) == 60)
        #expect(policy.update(bitrate: 5_600_000, used: 0.2, now: at(100)) == 60, "inside the band under 6 Mbit/s")
        #expect(policy.update(bitrate: 5_300_000, used: 0.2, now: at(200)) == 60, "under it, but not for long yet")
        #expect(policy.update(bitrate: 5_300_000, used: 0.2, now: at(600)) == 60, "400 ms under it: not yet")
        #expect(policy.update(bitrate: 5_300_000, used: 0.2, now: at(800)) == 45, "lower after half a second")
        #expect(policy.update(bitrate: 6_300_000, used: 0.2, now: at(900)) == 45, "inside the band over 6 Mbit/s")
        #expect(policy.update(bitrate: 6_700_000, used: 0.2, now: at(1_000)) == 45)
        #expect(policy.update(bitrate: 6_700_000, used: 0.2, now: at(2_900)) == 45, "not two seconds yet")
        #expect(policy.update(bitrate: 6_700_000, used: 0.2, now: at(3_100)) == 60, "higher after two seconds")
    }

    /// A link wavering across a boundary every 300 ms changes the rate at most once in 20 s.
    @Test func itDoesntFlap() {
        var policy = FrameRatePolicy(maximum: 60)
        var rates: [Int] = []
        for step in 0..<66 {
            let bitrate = step.isMultiple(of: 2) ? 5_200_000 : 6_800_000
            rates.append(policy.update(bitrate: bitrate, used: step % 4 < 2 ? 0.3 : 0.7, now: at(step * 300)))
        }
        let changes = zip(rates, rates.dropFirst()).filter { $0 != $1 }.count
        #expect(changes <= 1, "\(rates)")
    }

    @Test func busyHasABand() {
        var policy = FrameRatePolicy(maximum: 60)
        #expect(settled(&policy, bitrate: 4_000_000, used: 0.5) == 45)
        _ = policy.update(bitrate: 4_000_000, used: 0.7, now: at(6_000))
        #expect(policy.update(bitrate: 4_000_000, used: 0.5, now: at(7_000)) == 30, "still busy between the marks")
        _ = policy.update(bitrate: 4_000_000, used: 0.3, now: at(8_000))
        #expect(policy.update(bitrate: 4_000_000, used: 0.3, now: at(10_500)) == 45)
    }

    /// The display's highest refresh rate is the most the stream runs at: 120 on ProMotion; this MacBook Air's 60 Hz.
    @Test @MainActor func theDisplaysRefreshRateIsTheMost() {
        #expect(FrameRatePolicy.displayMaximum(reported: 60) == 60)
        #expect(FrameRatePolicy.displayMaximum(reported: 120) == 120)
        #expect(FrameRatePolicy.displayMaximum(reported: 240) == 120)
        #expect(FrameRatePolicy.displayMaximum(reported: 24) == 30)
        #expect(FrameRatePolicy.displayMaximum(reported: 0) == 60, "a display that doesn't say")
        let reported = FrameRatePolicy.reportedMaximum(of: CGMainDisplayID())
        print("frame rate: the main display refreshes at up to \(reported) Hz")
        #expect([60, 120].contains(FrameRatePolicy.displayMaximum(reported: reported)), "\(reported)")
    }

    // MARK: Refinement

    /// A frame of a 60 fps stream coming out of the encoder.
    func encoded(_ trigger: inout RefinementTrigger, _ bytes: Int, pass: Bool = false, at milliseconds: Int, bitrate: Int) {
        trigger.encoded(bytes: bytes, pass: pass, at: at(milliseconds), bitrate: bitrate, frameInterval: 1.0 / 60)
    }

    /// Milliseconds from the start to an instant, rounded up.
    func milliseconds(_ instant: ContinuousClock.Instant) -> Int { Int(((instant - start) / .milliseconds(1)).rounded(.up)) }

    /// Makes the passes as they fall due, each coming out at these sizes; returns when they went.
    func passes(_ trigger: inout RefinementTrigger, from first: Int, sizes: [Int], bitrate: Int) -> [Int] {
        var made: [Int] = []
        var now = first
        for bytes in sizes {
            guard trigger.refineNow(at: at(now), bitrate: bitrate) else { break }
            made.append(now)
            encoded(&trigger, bytes, pass: true, at: now, bitrate: bitrate)
            guard let next = trigger.nextPass() else { break }
            now = milliseconds(next)
        }
        return made
    }

    /// A scroll on a slow link, then a still screen: five passes, the first 150 ms after the last change, each next one
    /// 100 ms after the last or once the link has carried it, with the sizes this Mac's encoder makes at 1.5 Mbit/s.
    @Test func aStillScreenOnASlowLinkIsRefined() {
        var trigger = RefinementTrigger()
        let bitrate = 1_500_000
        for frame in 0..<10 {
            trigger.changed(at: at(frame * 33))
            encoded(&trigger, 2_800, at: frame * 33, bitrate: bitrate)   // 90% of its share
        }
        let last = 9 * 33
        #expect(trigger.nextPass() == at(last + 150))
        #expect(trigger.refineNow(at: at(last + 100), bitrate: bitrate) == false, "not before it's due")
        let made = passes(&trigger, from: last + 150, sizes: [219, 810, 23_000, 37_000, 43_000], bitrate: bitrate)
        #expect(made.map { $0 - last } == [150, 250, 350, 473, 671], "\(made)")
        #expect(trigger.nextPass() == nil, "five passes, no more")
        #expect(trigger.refineNow(at: at(last + 2_000), bitrate: bitrate) == false)
    }

    /// A big change on a slow link: the first pass waits until the link has carried it, so it doesn't queue behind it,
    /// and a blinking cursor meanwhile doesn't bring it forward.
    @Test func theFirstPassWaitsForABigFrame() {
        var trigger = RefinementTrigger()
        trigger.changed(at: at(0))
        encoded(&trigger, 86_000, at: 0, bitrate: 1_500_000)   // a zoom's switch at 1.5 Mbit/s: 459 ms on the link
        trigger.changed(at: at(200))
        encoded(&trigger, 300, at: 200, bitrate: 1_500_000)
        let due = trigger.nextPass()
        #expect(due.map { abs(($0 - at(0)) / .milliseconds(1) - 460.27) < 0.01 } == true, "\(String(describing: due))")
        #expect(trigger.refineNow(at: at(400), bitrate: 1_500_000) == false)
        #expect(trigger.refineNow(at: at(461), bitrate: 1_500_000) == true)
    }

    @Test func smallChangesNeedNoRefinement() {
        var trigger = RefinementTrigger()
        // A blinking cursor: a few hundred bytes a frame.
        trigger.changed(at: at(0))
        encoded(&trigger, 300, at: 0, bitrate: 2_000_000)
        #expect(trigger.refineNow(at: at(150), bitrate: 2_000_000) == false)
        #expect(trigger.nextPass() == nil)
    }

    /// On a fast link the picture is sharp already unless its frames hit their share.
    @Test func aFastLinkRefinesOnlyStarvedFrames() {
        var sharp = RefinementTrigger()
        sharp.changed(at: at(0))
        encoded(&sharp, 14_000, at: 0, bitrate: 8_000_000)   // 84% at 8 Mbit/s and 60 fps
        #expect(sharp.refineNow(at: at(150), bitrate: 8_000_000) == false)
        var starved = RefinementTrigger()
        starved.changed(at: at(0))
        encoded(&starved, 16_000, at: 0, bitrate: 8_000_000)
        #expect(starved.refineNow(at: at(150), bitrate: 8_000_000) == true)
    }

    /// A small change during a big one's passes puts them off without starting them over: they still stop at five. After
    /// them a small change alone isn't refined; a big one is, and gets five again even during an earlier motion's.
    @Test func smallChangesPutThePassesOff() {
        var trigger = RefinementTrigger()
        let bitrate = 2_000_000
        trigger.changed(at: at(0))
        encoded(&trigger, 4_000, at: 0, bitrate: bitrate)   // 96% of its share
        #expect(passes(&trigger, from: 150, sizes: [500], bitrate: bitrate) == [150])
        // A blinking cursor during the passes: the next waits 150 ms for it.
        trigger.changed(at: at(200))
        encoded(&trigger, 200, at: 200, bitrate: bitrate)
        #expect(trigger.nextPass() == at(350))
        #expect(passes(&trigger, from: 350, sizes: Array(repeating: 500, count: 9), bitrate: bitrate) == [350, 450, 550, 650])
        #expect(trigger.nextPass() == nil, "five in all")
        // After them, a blinking cursor alone isn't refined.
        trigger.changed(at: at(3_000))
        encoded(&trigger, 200, at: 3_000, bitrate: bitrate)
        #expect(trigger.refineNow(at: at(3_150), bitrate: bitrate) == false)
        // A big change is.
        trigger.changed(at: at(5_000))
        encoded(&trigger, 3_000, at: 5_000, bitrate: bitrate)   // 72%
        #expect(passes(&trigger, from: 5_150, sizes: [500, 500], bitrate: bitrate) == [5_150, 5_250])
        #expect(trigger.done == 2)
        // And another during its passes starts them over.
        trigger.changed(at: at(5_300))
        encoded(&trigger, 3_000, at: 5_300, bitrate: bitrate)
        #expect(trigger.done == 0, "new motion: five passes again")
    }

    /// A screen that keeps changing a little (a spinner every 100 ms) gets no passes while it does: its frames refine the
    /// picture themselves.
    @Test func aSpinnerPutsThePassesOffUntilItStops() {
        var trigger = RefinementTrigger()
        let bitrate = 1_500_000
        trigger.changed(at: at(0))
        encoded(&trigger, 60_000, at: 0, bitrate: bitrate)
        for tick in 1...20 {
            #expect(trigger.refineNow(at: at(tick * 100 - 1), bitrate: bitrate) == false)
            trigger.changed(at: at(tick * 100))
            encoded(&trigger, 400, at: tick * 100, bitrate: bitrate)
        }
        #expect(trigger.nextPass() == at(2_150))
        #expect(trigger.refineNow(at: at(2_150), bitrate: bitrate) == true)
    }
}
