import Foundation
import Testing

/// The pieces that wire the UDP transport into the apps: the phone's sound playout, `VideoPacing` for phones on UDP,
/// sessions that carry only sound, the hub noticing a quiet phone, and the small messages beside the picture.
@Suite("Media wiring")
struct MediaWiringTests {
    // MARK: Sound playout

    static func frame(_ sequence: UInt32, copy: Bool = false) -> ReceivedAudioFrame {
        ReceivedAudioFrame(sequence: sequence, timestamp: UInt64(sequence) * 10_000, duration: 10_000,
                           data: Data([UInt8(truncatingIfNeeded: sequence)]), fromRedundancy: copy)
    }

    static func data(_ sequence: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: sequence)]) }

    @Test func framesInOrderPlayAtOnce() {
        var playout = AudioPlayout()
        let steps = playout.add([Self.frame(7), Self.frame(8), Self.frame(9)], now: 0)
        #expect(steps == [.decode(Self.data(7), timestamp: 70_000), .decode(Self.data(8), timestamp: 80_000),
                          .decode(Self.data(9), timestamp: 90_000)])
        #expect(playout.nextDeadline == nil)
    }

    @Test func aLateFrameWithinTheHoldStillPlaysInItsPlace() {
        var playout = AudioPlayout(hold: 20_000)
        let first = playout.add([Self.frame(1)], now: 0)
        #expect(first == [.decode(Self.data(1), timestamp: 10_000)])
        // 3 comes before 2: wait for 2.
        let early = playout.add([Self.frame(3)], now: 10_000)
        #expect(early.isEmpty)
        #expect(playout.nextDeadline == 30_000)
        let late = playout.add([Self.frame(2)], now: 15_000)
        #expect(late == [.decode(Self.data(2), timestamp: 20_000), .decode(Self.data(3), timestamp: 30_000)])
        #expect(playout.stats.recovered == 0 && playout.stats.concealed == 0)
    }

    @Test func aLostFrameIsRebuiltFromItsSuccessorAfterTheHold() {
        var playout = AudioPlayout(hold: 20_000)
        _ = playout.add([Self.frame(1)], now: 0)
        let early = playout.add([Self.frame(3)], now: 10_000)
        #expect(early.isEmpty)
        let waiting = playout.expire(now: 29_000)
        #expect(waiting.isEmpty)
        let rebuilt = playout.expire(now: 30_000)
        // The rebuilt frame keeps its own place in time: its successor's, less a frame.
        #expect(rebuilt == [.recover(next: Self.data(3), timestamp: 20_000), .decode(Self.data(3), timestamp: 30_000)])
        #expect(playout.stats.recovered == 1)
    }

    @Test func twoLostFramesInARowAreConcealedThenRebuilt() {
        var playout = AudioPlayout(hold: 20_000)
        _ = playout.add([Self.frame(1)], now: 0)
        _ = playout.add([Self.frame(4)], now: 30_000)
        // 2 has no successor here (3 is lost too): concealed; 3 is rebuilt from 4; then 4 plays.
        let steps = playout.expire(now: 50_000)
        #expect(steps == [.conceal(timestamp: 20_000), .recover(next: Self.data(4), timestamp: 30_000),
                          .decode(Self.data(4), timestamp: 40_000)])
        #expect(playout.stats.concealed == 1 && playout.stats.recovered == 1 && playout.stats.decoded == 2)
    }

    @Test func aLongGapIsSkippedNotConcealedFrameByFrame() {
        var playout = AudioPlayout(hold: 20_000, longestConcealment: 10)
        _ = playout.add([Self.frame(1)], now: 0)
        // Half a second missing (a stall): playback goes on from the next frame it has.
        let steps = playout.add([Self.frame(52)], now: 520_000)
        #expect(steps == [.decode(Self.data(52), timestamp: 520_000)])
        #expect(playout.stats.skipped == 50)
    }

    @Test func framesOlderThanThePlayheadAreDropped() {
        var playout = AudioPlayout(hold: 20_000)
        _ = playout.add([Self.frame(5), Self.frame(6)], now: 0)
        let stale = playout.add([Self.frame(4, copy: true), Self.frame(6, copy: true)], now: 10_000)
        #expect(stale.isEmpty)
        #expect(playout.stats.late == 2)
    }

    /// Real Opus at 5% random loss and no copies: every lost frame is rebuilt or concealed, so the sound has no holes,
    /// and voice at a modest bitrate comes back mostly from in-band FEC.
    @Test func opusWithLossLeavesNoHoles() throws {
        let encoder = try OpusAudioEncoder(channels: 2, bitrate: 40_000, expectedLossPercent: 10)
        try encoder.setSignal(.voice)
        let decoder = try OpusAudioDecoder(channels: 2)
        var playout = AudioPlayout(hold: 20_000)
        var random = SeededGenerator(seed: 5)
        let total = 600
        var samples = 0
        var lost = 0
        var now: Int64 = 0
        // Every step's capture time, in order: the buffer on the phone needs them gap-free too.
        var timestamps: [UInt64?] = []
        for index in 0..<total {
            // A voice-like tone that glides, so the codec has something to predict.
            var pcm = [Float](repeating: 0, count: OpusFormat.frameSamples * 2)
            for sample in 0..<OpusFormat.frameSamples {
                let t = Double(index * OpusFormat.frameSamples + sample) / 48_000
                let value = Float(0.3 * sin(2 * .pi * (180 + 40 * sin(t * 3)) * t))
                pcm[sample * 2] = value
                pcm[sample * 2 + 1] = value
            }
            let packets = try pcm.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
            now += 10_000
            for packet in packets {
                // The last frame always arrives: with nothing after it, a lost last frame has nothing to rebuild from.
                if index < total - 1, Double.random(in: 0..<1, using: &random) < 0.05 {
                    lost += 1
                    continue
                }
                let frame = ReceivedAudioFrame(sequence: UInt32(index), timestamp: UInt64(now), duration: 10_000,
                                               data: packet, fromRedundancy: false)
                for step in playout.add([frame], now: now) + playout.expire(now: now) {
                    switch step {
                    case .decode(let data, let timestamp):
                        samples += try decoder.decode(data).count / 2
                        timestamps.append(timestamp)
                    case .recover(let next, let timestamp):
                        samples += try decoder.recover(lostBefore: next).count / 2
                        timestamps.append(timestamp)
                    case .conceal(let timestamp):
                        samples += try decoder.conceal().count / 2
                        timestamps.append(timestamp)
                    }
                }
            }
        }
        for step in playout.expire(now: now + 100_000) {
            if case .decode(let data, let timestamp) = step {
                samples += try decoder.decode(data).count / 2
                timestamps.append(timestamp)
            }
        }
        let played = playout.stats.decoded + playout.stats.recovered + playout.stats.concealed
        reportMetric("Opus playout at 5% loss: \(lost) of \(total) lost, \(playout.stats.recovered) rebuilt from FEC or PLC "
            + "with the next frame, \(playout.stats.concealed) concealed, \(played) of \(total) frames played")
        #expect(lost > 15)
        #expect(played == total)
        #expect(samples == total * OpusFormat.frameSamples)
        #expect(playout.stats.recovered + playout.stats.concealed == lost)
        // Each step 10 ms after the one before, lost frames included.
        let expected = (1...total).map { UInt64($0) * 10_000 }
        #expect(timestamps.compactMap { $0 } == expected)
    }

    // MARK: VideoPacing on UDP

    static let keyframe = VideoPacing.Frame(flags: [.keyframe, .refresh], sequence: 1, ltrToken: 11)

    static func delta(_ sequence: UInt32) -> VideoPacing.Frame {
        VideoPacing.Frame(flags: [], sequence: sequence, ltrToken: 10 + sequence)
    }

    static func refresh(_ sequence: UInt32) -> VideoPacing.Frame {
        VideoPacing.Frame(flags: [.refresh], sequence: sequence, ltrToken: 10 + sequence)
    }

    @Test func aRefusalOnUDPWaitsForARefreshWithoutCuttingTheBitrate() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        var offered = 0
        let take: () -> Bool = { offered += 1; return true }
        let refuse: () -> Bool = { offered += 1; return false }
        // (Swift Testing's `#expect` can't take a mutating call: each answer goes in a local first.)
        pace.produced(Self.keyframe)
        let first = pace.admit(Self.keyframe, to: phone, now: start, send: take)
        pace.produced(Self.delta(2))
        let second = pace.admit(Self.delta(2), to: phone, now: start, send: take)
        #expect(first && second)
        // The transport refuses frame 3 (its window is full).
        pace.produced(Self.delta(3))
        let third = pace.admit(Self.delta(3), to: phone, now: start, send: refuse)
        #expect(!third)
        #expect(pace.waiting(phone) == .refresh)
        #expect(pace.bitrate == 6_000_000)
        let change = pace.takeBitrateChange(now: start)
        #expect(change == nil)
        // Deltas aren't even offered while it waits; a refresh frame is.
        pace.produced(Self.delta(4))
        let fourth = pace.admit(Self.delta(4), to: phone, now: start, send: take)
        #expect(!fourth)
        #expect(offered == 3)
        pace.produced(Self.refresh(5))
        let fifth = pace.admit(Self.refresh(5), to: phone, now: start, send: take)
        #expect(fifth)
        #expect(pace.waiting(phone) == VideoPacing.Waiting.none)
    }

    @Test func switchingWaysStartsFromARefreshFrame() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        let taken = pace.admit(Self.keyframe, to: phone, now: start) { true }
        #expect(taken)
        pace.resume(phone, now: start)
        #expect(pace.waiting(phone) == .refresh)
        // A phone still waiting for its first keyframe keeps waiting for that.
        let newcomer = UUID()
        pace.join(newcomer, now: start)
        pace.resume(newcomer, now: start)
        #expect(pace.waiting(newcomer) == .keyframe)
    }

    /// A keyframe that takes two seconds to cross a slow path isn't given up on after the usual half second.
    @Test func aSlowKeyframeGetsItsDeliveryTimeAsGrace() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 1_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        let taken = pace.admit(Self.keyframe, to: phone, now: start, delivery: .seconds(2)) { true }
        #expect(taken)
        // The phone decoded nothing yet and asks for a refresh, a second in: still within the grace.
        let early = ScreenFeedback(sequence: 0, refresh: true)
        _ = pace.feedback(early, from: phone, now: start + .seconds(1))
        #expect(pace.waiting(phone) == VideoPacing.Waiting.none)
        // Past it, the keyframe evidently didn't make it: start over from another.
        _ = pace.feedback(early, from: phone, now: start + .seconds(3))
        #expect(pace.waiting(phone) == .keyframe)
    }

    /// A refresh lost on the way (frames given up after it went): another refresh at once, not a keyframe later.
    @Test func aLossAfterARefreshAsksForAnotherRefresh() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        _ = pace.admit(Self.keyframe, to: phone, now: start) { true }
        _ = pace.feedback(ScreenFeedback(sequence: 1, ltrTokens: [11]), from: phone, now: start)
        // A hiccup: frame 2 is given up; the phone asks for a refresh, which goes out as frame 3.
        _ = pace.feedback(ScreenFeedback(sequence: 1, refresh: true, lost: 1), from: phone, now: start)
        #expect(pace.waiting(phone) == .refresh)
        pace.produced(Self.refresh(3))
        let sent = pace.admit(Self.refresh(3), to: phone, now: start) { true }
        #expect(sent)
        // Still asking, nothing newer lost: frame 3 is on its way, wait for it.
        _ = pace.feedback(ScreenFeedback(sequence: 1, refresh: true, lost: 1), from: phone, now: start + .milliseconds(50))
        #expect(pace.waiting(phone) == VideoPacing.Waiting.none)
        // Another frame given up after it went (frame 3 itself, in the hiccup): another refresh, well within the grace.
        _ = pace.feedback(ScreenFeedback(sequence: 1, refresh: true, lost: 2), from: phone, now: start + .milliseconds(100))
        #expect(pace.waiting(phone) == .refresh)
    }

    /// A phone on UDP that has shown nothing yet asks in every feedback: a keyframe still on its way (its delivery
    /// time and a little) is waited for, not followed by another each time it asks; past that it's presumed lost.
    @Test func askingWithNothingDecodedWaitsForTheKeyframeOnItsWay() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        _ = pace.admit(Self.keyframe, to: phone, now: start, delivery: .milliseconds(100)) { true }
        for step in 1...10 {
            let asking = ScreenFeedback(sequence: nil, refresh: true, lost: step)
            _ = pace.feedback(asking, from: phone, now: start + .milliseconds(17 * step))
        }
        #expect(pace.waiting(phone) == VideoPacing.Waiting.none)
        // Well past its delivery time with still nothing decoded: lost on the way, another keyframe.
        _ = pace.feedback(ScreenFeedback(sequence: nil, refresh: true, lost: 10), from: phone, now: start + .milliseconds(250))
        #expect(pace.waiting(phone) == .keyframe)
    }

    /// Its first keyframe lost and a frame refused since, a phone on UDP waits for a refresh but has shown nothing:
    /// it gets a keyframe at once (once the lost one is past its delivery time), not after a refresh's 500 ms wait.
    @Test func nothingDecodedTurnsAWaitForARefreshIntoAKeyframe() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        _ = pace.admit(Self.keyframe, to: phone, now: start, delivery: .milliseconds(100)) { true }
        pace.produced(Self.delta(2))
        _ = pace.admit(Self.delta(2), to: phone, now: start + .milliseconds(20)) { false }
        #expect(pace.waiting(phone) == .refresh)
        // The keyframe may still land: wait.
        _ = pace.feedback(ScreenFeedback(sequence: nil, refresh: true, lost: 1), from: phone, now: start + .milliseconds(150))
        #expect(pace.waiting(phone) == .refresh)
        // Past its delivery time and still nothing shown: a keyframe, asked for at once.
        _ = pace.feedback(ScreenFeedback(sequence: nil, refresh: true, lost: 2), from: phone, now: start + .milliseconds(300))
        #expect(pace.waiting(phone) == .keyframe)
        let request = pace.nextRequest(now: start + .milliseconds(300), hasRoom: { _ in true })
        #expect(request == .keyframe)
    }

    @Test func aRefreshIsAskedForOnlyWhenTheSessionHasRoom() {
        let start = ContinuousClock.now
        let phone = UUID()
        var pace = VideoPacing(target: 6_000_000, now: start)
        pace.join(phone, now: start)
        pace.produced(Self.keyframe)
        _ = pace.admit(Self.keyframe, to: phone, now: start) { true }
        _ = pace.feedback(ScreenFeedback(sequence: 1, ltrTokens: [11]), from: phone, now: start)
        pace.produced(Self.delta(2))
        _ = pace.admit(Self.delta(2), to: phone, now: start) { false }
        let later = start + .seconds(2)
        let full = pace.nextRequest(now: later, hasRoom: { _ in false })
        let room = pace.nextRequest(now: later, hasRoom: { _ in true })
        #expect(full == nil)
        #expect(room == .refresh)
    }

    // MARK: Sessions

    /// Runs a sender and a receiver against each other over a perfect link for a while (simulated time).
    static func run(_ sender: MediaSender, _ receiver: MediaReceiver, from start: Int64, for duration: Int64,
                    phoneTalks: Bool = true) -> [SenderEvent] {
        var events: [SenderEvent] = []
        var now = start
        while now < start + duration {
            let out = sender.poll(now: now)
            events += out.events
            for datagram in out.datagrams { _ = receiver.receive(datagram, now: now + 5_000) }
            if phoneTalks {
                for datagram in receiver.poll(now: now).datagrams { events += sender.receive(datagram, now: now + 5_000) }
            }
            now += 1_000
        }
        return events
    }

    static func pair(video: Bool) throws -> (MediaSender, MediaReceiver) {
        let (sessionID, key) = TransportKeys.generate()
        let keys = try #require(TransportKeys(sessionID: sessionID, sessionKey: key))
        let sender = MediaSender(keys: keys, profile: .profile(for: .direct))
        var settings = MediaReceiver.Settings()
        settings.wantsVideo = video
        let receiver = MediaReceiver(keys: keys, network: .wifi, settings: settings)
        let hello = try #require(receiver.hello(now: 0))
        _ = sender.receive(hello, now: 1_000)
        return (sender, receiver)
    }

    @Test func aSessionForSoundAloneNeverProbes() throws {
        let (sound, soundPhone) = try Self.pair(video: false)
        #expect(!sound.carriesVideo)
        _ = Self.run(sound, soundPhone, from: 1_000, for: 6_000_000)
        #expect(soundPhone.stats.probePackets == 0)
        // The same with pictures probes at the start.
        let (picture, picturePhone) = try Self.pair(video: true)
        _ = Self.run(picture, picturePhone, from: 1_000, for: 2_000_000)
        #expect(picturePhone.stats.probePackets > 0)
    }

    @Test func theHubNoticesAQuietPhoneOnce() throws {
        let (sender, receiver) = try Self.pair(video: true)
        let talking = Self.run(sender, receiver, from: 1_000, for: 1_000_000)
        #expect(!talking.contains(.silent))
        // The phone stops: 3 s later, one `.silent`.
        let quiet = Self.run(sender, receiver, from: 1_001_000, for: 2_900_000, phoneTalks: false)
        #expect(!quiet.contains(.silent))
        let gone = Self.run(sender, receiver, from: 3_901_000, for: 2_000_000, phoneTalks: false)
        #expect(gone.filter { $0 == .silent }.count == 1)
        // It talks again, then goes quiet again: reported again.
        _ = Self.run(sender, receiver, from: 5_901_000, for: 100_000)
        let again = Self.run(sender, receiver, from: 6_001_000, for: 3_100_000, phoneTalks: false)
        #expect(again.filter { $0 == .silent }.count == 1)
    }

    // MARK: Rate control on a still screen

    /// The encoder trickles 0.4 Mbit/s (a still screen) when a keyframe's burst shows as overuse: the estimate steps
    /// down once per spell, however long it lasts, not to a fraction of the trickle. A sender filling its target gets
    /// the usual cut, to below what gets through.
    @Test func aStillScreensBurstStepsTheEstimateDownOncePerSpell() {
        var aimd = AimdRateControl(start: 5_000_000, min: 300_000, max: 10_000_000)
        aimd.roundTrip = 30_000
        var now: Int64 = 1_000_000
        for _ in 0..<40 {
            _ = aimd.update(usage: .overusing, throughput: 400_000, now: now, applicationLimited: true)
            now += 25_000
        }
        #expect(abs(aimd.current - 4_250_000) < 1)
        // The spell ends; the next one gets one more step.
        _ = aimd.update(usage: .normal, throughput: 400_000, now: now, applicationLimited: true)
        _ = aimd.update(usage: .overusing, throughput: 400_000, now: now + 25_000, applicationLimited: true)
        #expect(abs(aimd.current - 4_250_000 * AimdRateControl.beta) < 1)
        // Busy (not application-limited): the first overuse cuts to below what gets through.
        _ = aimd.update(usage: .normal, throughput: 2_000_000, now: now + 50_000)
        _ = aimd.update(usage: .overusing, throughput: 2_000_000, now: now + 75_000)
        #expect(abs(aimd.current - 1_700_000) < 1)
    }

    // MARK: Messages beside the picture

    @Test func feedbackAndPointerRoundTrip() throws {
        let feedback = ScreenFeedback(sequence: 812, ltrTokens: [70_001, 70_002, 70_003], refresh: true,
                                      receivedBytes: 48_000, intervalMs: 16.9, decodeMs: 2.4)
        let message = try #require(AppMessage.feedback(feedback))
        #expect(message.channel == MediaChannel.feedback)
        #expect(message.data.count < 250)
        #expect(message.screenFeedback == feedback)
        #expect(message.pointerPosition == nil)
        let position = CursorPositionMessage(displayID: 4, x: 0.25, y: 0.75, visible: true, shapeID: 9)
        let pointer = AppMessage.pointer(position)
        #expect(pointer.pointerPosition == position)
        #expect(pointer.screenFeedback == nil)
    }
}
