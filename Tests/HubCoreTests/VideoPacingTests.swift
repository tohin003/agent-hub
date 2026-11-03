import Foundation
import Testing

/// Who gets which video frame on a slow or busy link, when the encoder is asked for a refresh or a keyframe, and the
/// bitrate: `VideoPacing` played through the cases the hub meets.
@Suite("Video pacing")
struct VideoPacingTests {
    let start = ContinuousClock.now
    let phone = UUID()

    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    // `admit` is mutating, and `#expect` runs a bare call on a constant copy, so its answer is compared with `== true`.

    static func keyframe(_ sequence: UInt32, token: UInt32 = 0) -> VideoPacing.Frame {
        .init(flags: [.keyframe, .refresh], sequence: sequence, ltrToken: token)
    }

    static func delta(_ sequence: UInt32, token: UInt32 = 0) -> VideoPacing.Frame {
        .init(flags: [], sequence: sequence, ltrToken: token)
    }

    static func refresh(_ sequence: UInt32, token: UInt32 = 0) -> VideoPacing.Frame {
        .init(flags: .refresh, sequence: sequence, ltrToken: token)
    }

    /// A pacing with one phone that took a keyframe (token 1) and is in step.
    func inStep(bitrate: Int = 8_000_000) -> VideoPacing {
        var pacing = VideoPacing(target: bitrate, now: start)
        pacing.join(phone, now: start)
        pacing.produced(Self.keyframe(1, token: 1))
        _ = pacing.admit(Self.keyframe(1, token: 1), to: phone, backlog: 0, keyframeBacklog: 0, now: start)
        return pacing
    }

    @Test func theBacklogAllowedIs35MillisecondsOfTheBitrate() {
        #expect(VideoPacing(target: 8_000_000, now: start).cap == 35_000)
        #expect(VideoPacing(target: 1_000_000, now: start).cap == 16 * 1024, "never below 16 KB")
    }

    @Test func aNewPhoneStartsAtAKeyframe() {
        var pacing = VideoPacing(target: 8_000_000, now: start)
        pacing.join(phone, now: start)
        #expect(pacing.waiting(phone) == .keyframe)
        #expect(pacing.holding, "nobody takes a frame yet")
        #expect(pacing.nextRequest(now: start, backlog: { _ in 0 }) == nil, "a new stream starts with a keyframe anyway")
        pacing.produced(Self.delta(7))
        #expect(pacing.admit(Self.delta(7), to: phone, backlog: 0, keyframeBacklog: 0, now: start) == false,
                "a delta frame is no use")
        #expect(pacing.admit(Self.refresh(8), to: phone, backlog: 0, keyframeBacklog: 0, now: start) == false,
                "nor a refresh: it has nothing to refer to")
        pacing.produced(Self.keyframe(9))
        #expect(pacing.admit(Self.keyframe(9), to: phone, backlog: 0, keyframeBacklog: 0, now: start) == true)
        #expect(pacing.waiting(phone) == VideoPacing.Waiting.none)
        #expect(!pacing.holding)
        #expect(pacing.admit(Self.delta(10), to: phone, backlog: 20_000, keyframeBacklog: 0, now: start) == true)
        // A phone joining a running stream gets a keyframe made for it.
        let second = UUID()
        pacing.join(second, now: at(10))
        #expect(pacing.nextRequest(now: at(10), backlog: { _ in 0 }) == .keyframe)
        pacing.produced(Self.keyframe(11))
        #expect(pacing.admit(Self.keyframe(11), to: second, backlog: 0, keyframeBacklog: 0, now: at(20)) == true)
    }

    @Test func aFrameThatDoesNotFitIsSkippedUntilARefresh() {
        var pacing = inStep()
        #expect(pacing.admit(Self.delta(2), to: phone, backlog: 40_000, keyframeBacklog: 0, now: at(10)) == false)
        #expect(pacing.waiting(phone) == .refresh)
        #expect(pacing.bitrate == 5_600_000, "a skip cuts the bitrate by 30%")
        #expect(pacing.takeBitrateChange(now: at(10)) == 5_600_000)
        #expect(pacing.holding, "nothing to encode for anyone until the refresh")
        #expect(pacing.admit(Self.delta(3), to: phone, backlog: 0, keyframeBacklog: 0, now: at(20)) == false,
                "the frames after a gap don't decode")
        // No room yet: no refresh asked for.
        #expect(pacing.nextRequest(now: at(20), backlog: { _ in 40_000 }) == nil)
        // Room, but nothing acknowledged yet: the refresh would be a keyframe, so it waits for the acknowledgement.
        #expect(pacing.nextRequest(now: at(30), backlog: { _ in 0 }) == nil)
        let acknowledged = pacing.feedback(ScreenFeedback(sequence: 1, ltrTokens: [1]), from: phone, now: at(40))
        #expect(acknowledged == [1])
        #expect(pacing.nextRequest(now: at(40), backlog: { _ in 0 }) == .refresh)
        #expect(pacing.nextRequest(now: at(45), backlog: { _ in 0 }) == nil, "asked once, until a frame answers")
        pacing.produced(Self.refresh(4))
        #expect(pacing.admit(Self.refresh(4), to: phone, backlog: 0, keyframeBacklog: 0, now: at(50)) == true)
        #expect(pacing.waiting(phone) == VideoPacing.Waiting.none && !pacing.holding)
    }

    @Test func aRefreshWithoutAnAcknowledgementIsAskedForAfterHalfASecond() {
        var pacing = inStep()
        _ = pacing.admit(Self.delta(2), to: phone, backlog: 40_000, keyframeBacklog: 0, now: at(10))
        #expect(pacing.nextRequest(now: at(400), backlog: { _ in 0 }) == nil)
        #expect(pacing.nextRequest(now: at(510), backlog: { _ in 0 }) == .refresh)
    }

    @Test func aKeyframeStillGoingOutIsNotASlowLink() {
        var pacing = inStep()
        // 60 KB on its way, 50 KB of which is the keyframe: the skip doesn't cut the bitrate.
        #expect(pacing.admit(Self.delta(2), to: phone, backlog: 60_000, keyframeBacklog: 50_000, now: at(10)) == false)
        #expect(pacing.waiting(phone) == .refresh)
        #expect(pacing.bitrate == 8_000_000)
        #expect(pacing.takeBitrateChange(now: at(10)) == nil)
    }

    @Test func thePhoneAsksForARefresh() {
        var pacing = inStep()
        _ = pacing.feedback(ScreenFeedback(sequence: 5, refresh: true), from: phone, now: at(10))
        #expect(pacing.waiting(phone) == .refresh)
        #expect(pacing.admit(Self.delta(6), to: phone, backlog: 0, keyframeBacklog: 0, now: at(20)) == false)
        pacing.produced(Self.refresh(7))
        #expect(pacing.admit(Self.refresh(7), to: phone, backlog: 0, keyframeBacklog: 0, now: at(30)) == true)
        // Feedback written before the refresh arrived: it's on its way, so nothing changes.
        _ = pacing.feedback(ScreenFeedback(sequence: 6, refresh: true), from: phone, now: at(60))
        #expect(pacing.waiting(phone) == VideoPacing.Waiting.none)
        // Still asking well after it should have shown: the refresh didn't work, so start over at a keyframe.
        _ = pacing.feedback(ScreenFeedback(sequence: 6, refresh: true), from: phone, now: at(600))
        #expect(pacing.waiting(phone) == .keyframe)
        #expect(pacing.nextRequest(now: at(600), backlog: { _ in 0 }) == .keyframe)
    }

    @Test func aPhoneWithNothingDecodedNeedsAKeyframe() {
        var pacing = inStep()
        _ = pacing.feedback(ScreenFeedback(sequence: nil, refresh: true), from: phone, now: at(10))
        #expect(pacing.waiting(phone) == .keyframe)
    }

    @Test func acknowledgementsNeedEveryPhone() {
        var pacing = inStep()
        let other = UUID()
        pacing.join(other, now: at(5))
        pacing.produced(Self.keyframe(2, token: 2))
        for viewer in [phone, other] {
            let admitted = pacing.admit(Self.keyframe(2, token: 2), to: viewer, backlog: 0, keyframeBacklog: 0, now: at(10))
            #expect(admitted)
        }
        pacing.produced(Self.delta(3, token: 3))
        #expect(pacing.feedback(ScreenFeedback(sequence: 1, ltrTokens: [1]), from: phone, now: at(20)).isEmpty,
                "a token from before the keyframe means nothing now")
        #expect(pacing.feedback(ScreenFeedback(sequence: 2, ltrTokens: [2]), from: phone, now: at(20)).isEmpty,
                "one phone of two")
        #expect(pacing.feedback(ScreenFeedback(sequence: 2, ltrTokens: [2]), from: other, now: at(25)) == [2])
        #expect(pacing.feedback(ScreenFeedback(sequence: 3, ltrTokens: [3]), from: phone, now: at(30)).isEmpty)
        #expect(pacing.leave(other) == [3], "the phone left was the one still missing")
    }

    @Test func aPhoneWaitingForAKeyframeDoesNotHoldBackTheOthers() {
        var pacing = inStep()
        pacing.produced(Self.delta(2, token: 2))
        let newcomer = UUID()
        pacing.join(newcomer, now: at(10))
        #expect(!pacing.holding, "the first phone still takes frames")
        #expect(pacing.feedback(ScreenFeedback(sequence: 2, ltrTokens: [2]), from: phone, now: at(20)) == [2])
        #expect(pacing.nextRequest(now: at(20), backlog: { _ in 0 }) == .keyframe)
    }

    @Test func requestsAreAskedAgainIfNothingAnswers() {
        // A new stream's first frame is the keyframe; if none came within a second, it's asked for.
        var pacing = VideoPacing(target: 8_000_000, now: start)
        pacing.join(phone, now: start)
        #expect(pacing.nextRequest(now: start, backlog: { _ in 0 }) == nil)
        #expect(pacing.nextRequest(now: at(900), backlog: { _ in 0 }) == nil)
        #expect(pacing.nextRequest(now: at(1000), backlog: { _ in 0 }) == .keyframe)
        #expect(pacing.nextRequest(now: at(1500), backlog: { _ in 0 }) == nil)
        #expect(pacing.nextRequest(now: at(2000), backlog: { _ in 0 }) == .keyframe)
    }

    @Test func theBitrateComesBackInSteps() {
        var pacing = inStep(bitrate: 4_000_000)
        for step in 1...7 {
            pacing.produced(Self.refresh(UInt32(step * 2)))
            _ = pacing.admit(Self.refresh(UInt32(step * 2)), to: phone, backlog: 0, keyframeBacklog: 0, now: at(step))
            _ = pacing.admit(Self.delta(UInt32(step * 2 + 1)), to: phone, backlog: 99_999, keyframeBacklog: 0, now: at(step))
        }
        #expect(pacing.bitrate == VideoPacing.lowestBitrate, "cut 30% a skip, down to 0.5 Mbit/s: \(pacing.bitrate)")
        _ = pacing.takeBitrateChange(now: at(10))
        #expect(pacing.takeBitrateChange(now: at(1_900)) == nil, "not yet two calm seconds")
        #expect(pacing.takeBitrateChange(now: at(2_010)) == 550_000)
        #expect(pacing.takeBitrateChange(now: at(3_000)) == nil)
        #expect(pacing.takeBitrateChange(now: at(4_010)) == 605_000)
        var later = 4_010
        while pacing.bitrate < pacing.target {
            later += 2_000
            _ = pacing.takeBitrateChange(now: at(later))
        }
        #expect(pacing.bitrate == 4_000_000, "up to the bitrate asked for, never past it")
        pacing.setTarget(3_000_000)
        #expect(pacing.bitrate == 3_000_000 && pacing.takeBitrateChange(now: at(later + 1)) == 3_000_000)
    }

    @Test func aDefaultBitrateFollowsTheSize() {
        #expect(VideoPacing.defaultBitrate(width: 1920, height: 1248, fps: 60) == 7_188_480)
        #expect(VideoPacing.defaultBitrate(width: 64, height: 64, fps: 1) == VideoPacing.lowestBitrate)
    }
}
