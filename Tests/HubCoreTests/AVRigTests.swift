import Foundation
import Synchronization
import Testing

/// The step-2 rig, as far as it could be made safe: the hub's code against the phone's over real UDP sockets on this
/// Mac, in real time, the picture and the sound each on a session of its own as the apps run them.
///
/// - **Hub side:** the hardware `VideoEncoder` at 60 fps into the real `UDPServerSession` (`HubHarness`, as
///   `ScreenService` sends); a tone "captured" in real time, stamped through `SampleClock` with the encoder's
///   look-ahead and sent as Opus in 10 ms frames over a second session (as `AudioStreamer` does).
/// - **Phone side:** the real `UDPMediaClient`s; frames decoded by the hardware `VideoDecoder` (`PhoneHarness`); sound
///   through `AudioPlayout` and the Opus decoder into `PlayoutController`, with an output that takes sound in real
///   time at the controller's rate (as `SoundOutput` and its varispeed do); `MacClock` fed by the sessions' `.clock`
///   events; `MediaSync` holding the picture in lip-sync.
///
/// Both ends run on this Mac's host clock, so every delay has a true value to check the phone's estimates against.
/// Standing in: the screen and sound capture (a moving picture and a tone: a test process has no Screen Recording
/// permission, and asking would put a prompt on the person's screen), the display (12.5 ms after decoding, a 120 Hz
/// refresh and a half) and the audio device (an output on a timer, so nothing is heard, with the latency of the
/// phone's speaker or of AirPods).
@Suite("A/V rig over real UDP", .serialized)
struct AVRigTests {
    static let displayMs = 12.5

    static func run(lipSync: Bool, outputLatencyMs: Double, seconds: Double) async throws -> RigRecorder.Summary {
        let sync = MediaSync()
        sync.lipSync = lipSync
        let clock = MacClock()
        let recorder = RigRecorder()
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        // 3 ms each way on both sessions.
        let videoRelay = LossyRelay(toHub: LossyRelay.Link(delay: 3_000), toPhone: LossyRelay.Link(delay: 3_000))
        let videoPort = try await videoRelay.start(hubPort: port)
        defer { videoRelay.stop() }
        let soundRelay = LossyRelay(toHub: LossyRelay.Link(delay: 3_000), toPhone: LossyRelay.Link(delay: 3_000))
        let soundPort = try await soundRelay.start(hubPort: port)
        defer { soundRelay.stop() }

        let (videoID, videoKey) = TransportKeys.generate()
        let videoKeys = try #require(TransportKeys(sessionID: videoID, sessionKey: videoKey))
        let videoSession = server.makeSession(keys: videoKeys, profile: .profile(for: .direct))
        let videoClient = UDPMediaClient(host: "127.0.0.1", port: videoPort, keys: videoKeys, network: .wifi)
        defer { videoClient.close() }
        let hub = try HubHarness(session: videoSession)
        let phone = PhoneHarness(client: videoClient)
        phone.onDecoded = { captured, decodedAt in
            recorder.picture(captured: captured, decodedAt: decodedAt, clock: clock, sync: sync)
        }
        videoSession.setEventHandler { hub.handle($0) }
        videoClient.setHandlers(onEvent: { event in
            if case .clock(let offset) = event { clock.transport(offset: offset) }
            phone.handle(event)
        }, onFailure: { _ in phone.failed() })

        let (soundID, soundKey) = TransportKeys.generate()
        let soundKeys = try #require(TransportKeys(sessionID: soundID, sessionKey: soundKey))
        let soundSession = server.makeSession(keys: soundKeys, profile: .profile(for: .direct))
        let soundClient = UDPMediaClient(host: "127.0.0.1", port: soundPort, keys: soundKeys, network: .wifi, video: false)
        defer { soundClient.close() }
        let soundHub = try RigSoundHub(session: soundSession)
        let soundPhone = try RigSoundPhone(clock: clock, sync: sync, recorder: recorder, outputLatencyMs: outputLatencyMs)
        soundClient.setHandlers(onEvent: { soundPhone.handle($0) }, onFailure: { _ in })

        try await videoClient.connect(timeout: 2)
        try await soundClient.connect(timeout: 2)
        phone.startFeedback()
        hub.start()
        soundPhone.start()
        soundHub.start()
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        soundHub.stop()
        hub.stop()
        let sound = soundPhone.stop()
        phone.stop()
        return recorder.summary(after: 3, sound: sound)
    }

    /// Each mode with the phone's speaker and with AirPods' delay: the sound is never ahead of the picture; lip-sync
    /// holds the picture so the sound trails it by about 20 ms; lowest delay never holds it. The sound plays without a
    /// gap, and the phone's view of the Mac's clock (from the sessions) is within a millisecond of the truth.
    @Test(.timeLimit(.minutes(2)), arguments: [(false, 8.0), (true, 8.0), (false, 180.0), (true, 180.0)])
    func pictureAndSoundInStep(lipSync: Bool, outputLatencyMs: Double) async throws {
        let summary = try await Self.run(lipSync: lipSync, outputLatencyMs: outputLatencyMs, seconds: 10)
        reportMetric(String(format: "A/V rig over real UDP, %@, output %.0f ms: picture %.1f ms to the glass (held %.1f), "
            + "sound %.1f ms to the ear; the sound trails by %.1f ms (p5 %.1f, p95 %.1f); %d pictures; sound %d gaps, "
            + "%d underruns, %.0f ms skipped, buffer %.1f ms, rate %.4f–%.4f; the phone's clock off by %.2f ms "
            + "(picture) and %.2f ms (sound), its picture and sound delays by %+.2f and %+.2f ms",
            lipSync ? "lip-sync" : "lowest delay", outputLatencyMs, summary.picture, summary.hold, summary.sound,
            summary.offset, summary.offsetLow, summary.offsetHigh, summary.pictures, summary.soundStats.gaps,
            summary.soundStats.underruns, summary.soundStats.skippedMs, summary.soundStats.targetMs,
            summary.soundStats.lowestRate, summary.soundStats.highestRate, summary.pictureClockError,
            summary.soundClockError, summary.pictureEstimateError, summary.soundEstimateError))
        #expect(summary.pictures > 300)
        #expect(summary.soundStats.gaps <= 1, "gap-free, short of a scheduling hiccup on a busy Mac")
        #expect(summary.offset >= 0, "the sound isn't ahead of the picture")
        #expect(summary.offsetLow >= -5)
        #expect(abs(summary.pictureClockError) < 1)
        #expect(abs(summary.soundClockError) < 1)
        if lipSync {
            #expect(summary.offset <= SyncRule.maxTrailMs)
            if outputLatencyMs > 100 { #expect(abs(summary.offset - SyncRule.lipSyncTrailMs) < 8) }
        } else {
            #expect(summary.hold == 0, "lowest delay never holds the picture")
        }
    }
}

/// What the rig measured; each picture as it's shown, with the sound's delay at that moment.
final class RigRecorder: @unchecked Sendable {
    struct Sample {
        var time: Double
        /// True capture → glass, ms (the hold included), and the phone's estimate of it.
        var picture: Double
        var pictureEstimate: Double
        var hold: Double
        var sound: Double?
        var soundEstimate: Double?
    }

    struct SoundStats {
        var gaps = 0
        var underruns = 0
        var skippedMs = 0.0
        var targetMs = 0.0
        var lowestRate = 1.0
        var highestRate = 1.0
        /// The phone's arrival estimates (through `MacClock`) less the truth, ms.
        var clockErrors: [Double] = []
    }

    struct Summary {
        var pictures = 0
        var picture = 0.0
        var hold = 0.0
        var sound = 0.0
        var offset = 0.0
        var offsetLow = 0.0
        var offsetHigh = 0.0
        var pictureClockError = 0.0
        var soundClockError = 0.0
        var pictureEstimateError = 0.0
        var soundEstimateError = 0.0
        var soundStats = SoundStats()
    }

    private let lock = NSLock()
    private let started = TransportClock.now()
    private var soundTrue: Double?
    private var soundEstimate: Double?
    private var samples: [Sample] = []
    private var pictureClockErrors: [Double] = []

    /// The sound's delay now: true, and as the phone estimates it.
    func sound(trueMs: Double, estimateMs: Double?) {
        lock.withLock {
            soundTrue = trueMs
            soundEstimate = estimateMs
        }
    }

    /// A decoded picture, as `VideoFeed` takes it: its delay to the glass through the phone's clock estimate goes to
    /// the sync rule, which answers the hold.
    func picture(captured: Int64, decodedAt: Int64, clock: MacClock, sync: MediaSync) {
        guard let estimated = clock.milliseconds(since: captured, now: decodedAt) else { return }
        let toGlass = estimated + AVRigTests.displayMs
        sync.pictureShown(delayMs: toGlass, now: decodedAt)
        let hold = sync.pictureHold(now: decodedAt)
        let truth = Double(decodedAt - captured) / 1000 + AVRigTests.displayMs + hold
        lock.withLock {
            pictureClockErrors.append(estimated - Double(decodedAt - captured) / 1000)
            samples.append(Sample(time: Double(decodedAt - started) / 1e6, picture: truth, pictureEstimate: toGlass + hold,
                                  hold: hold, sound: soundTrue, soundEstimate: soundEstimate))
        }
    }

    func summary(after settle: Double, sound: SoundStats) -> Summary {
        lock.withLock {
            let settled = samples.filter { $0.time >= settle && $0.sound != nil }
            var summary = Summary()
            summary.pictures = settled.count
            summary.soundStats = sound
            guard !settled.isEmpty else { return summary }
            let offsets = settled.compactMap { sample in sample.sound.map { $0 - sample.picture } }
            summary.picture = Self.percentile(settled.map(\.picture), 0.5)
            summary.hold = Self.percentile(settled.map(\.hold), 0.5)
            summary.sound = Self.percentile(settled.compactMap(\.sound), 0.5)
            summary.offset = Self.percentile(offsets, 0.5)
            summary.offsetLow = Self.percentile(offsets, 0.05)
            summary.offsetHigh = Self.percentile(offsets, 0.95)
            summary.pictureClockError = Self.percentile(pictureClockErrors, 0.5)
            summary.soundClockError = Self.percentile(sound.clockErrors, 0.5)
            summary.pictureEstimateError = Self.percentile(settled.map { $0.pictureEstimate - $0.picture }, 0.5)
            summary.soundEstimateError = Self.percentile(settled.compactMap { sample in
                sample.soundEstimate.flatMap { estimate in sample.sound.map { estimate - $0 } }
            }, 0.5)
            return summary
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }
}

/// The Mac's sound as `AudioStreamer` sends it over UDP: "captured" in real time (a tone), stamped through
/// `SampleClock` with the encoder's look-ahead, and sent as Opus in 10 ms frames once each is complete.
final class RigSoundHub: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.rig.hub.sound", qos: .userInteractive)
    private let session: UDPServerSession
    private let encoder: OpusAudioEncoder
    private var clock: SampleClock
    private var started: Int64?
    private var captured = 0
    private var packets = 0
    private var timer: DispatchSourceTimer?

    init(session: UDPServerSession) throws {
        self.session = session
        encoder = try OpusAudioEncoder(channels: 2)
        try encoder.configure(profile: .profile(for: .direct), plan: session.snapshot.plan)
        clock = SampleClock(sampleRate: 48_000, leadingFrames: encoder.lookahead)
    }

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Every 10 ms of sound captured by now, in order.
    private func tick() {
        let now = TransportClock.now()
        let started = self.started ?? now
        self.started = started
        while Int64(Double(captured + OpusFormat.frameSamples) / 48_000 * 1e6) <= now - started {
            let capture = started + Int64(Double(captured) / 48_000 * 1e6)
            clock.input(frames: OpusFormat.frameSamples, captureTime: capture)
            var pcm = [Float](repeating: 0, count: OpusFormat.frameSamples * 2)
            for sample in 0..<OpusFormat.frameSamples {
                let t = Double(captured + sample) / 48_000
                let value = Float(0.25 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 660 * t))
                pcm[sample * 2] = value
                pcm[sample * 2 + 1] = value
            }
            captured += OpusFormat.frameSamples
            guard let encoded = try? pcm.withUnsafeBufferPointer({ try encoder.encode(interleaved: $0) }) else { continue }
            for packet in encoded {
                let stamp = clock.captureTime(ofDecodedSample: packets * OpusFormat.frameSamples) ?? capture
                session.sendAudio(packet, timestamp: UInt64(max(stamp, 0)), duration: OpusFormat.frameDuration)
                packets += 1
            }
        }
    }
}

/// The phone's sound over UDP as `OpusPlayback` and `SoundOutput` play it, with an output that takes sound in real
/// time at the controller's rate in place of a speaker.
final class RigSoundPhone: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.rig.sound", qos: .userInteractive)
    private let clock: MacClock
    private let sync: MediaSync
    private let recorder: RigRecorder
    private let outputLatencyMs: Double
    private let decoder: OpusAudioDecoder
    private var playout = AudioPlayout()
    private var controller = PlayoutController(settings: .forPath(bufferMs: PathProfile.profile(for: .direct).audioBufferMs))
    private var level = 0.0
    private var filling: [Double] = []
    private var smoothed: Double?
    private var rate = 1.0
    private var soundDelay: Double?
    private var trueDelay: Double?
    private var arrivals: [(at: Int64, ms: Double)] = []
    private var syncChecked: Int64?
    private var lastTake: Int64?
    private var timer: DispatchSourceTimer?
    private var stats = RigRecorder.SoundStats()
    private var inGap = false
    private var dryAt: Int64?

    init(clock: MacClock, sync: MediaSync, recorder: RigRecorder, outputLatencyMs: Double) throws {
        self.clock = clock
        self.sync = sync
        self.recorder = recorder
        self.outputLatencyMs = outputLatencyMs
        decoder = try OpusAudioDecoder(channels: 2)
    }

    /// From the session's queue.
    func handle(_ event: ReceiverEvent) {
        switch event {
        case .audio(let frames):
            queue.async { self.add(frames) }
        case .clock(let offset):
            clock.transport(offset: offset)
        default:
            break
        }
    }

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() -> RigRecorder.SoundStats {
        queue.sync {
            timer?.cancel()
            timer = nil
            stats.underruns = controller.stats.underruns
            stats.skippedMs = controller.stats.skippedMs
            stats.targetMs = controller.targetMs
            stats.lowestRate = controller.stats.lowestRate
            stats.highestRate = controller.stats.highestRate
            return stats
        }
    }

    private func add(_ frames: [ReceivedAudioFrame]) {
        let now = TransportClock.now()
        play(playout.add(frames, now: now), now: now)
    }

    /// Every 5 ms: frames waited for long enough, then the output takes what the time passed asks at the rate.
    private func tick() {
        let now = TransportClock.now()
        play(playout.expire(now: now), now: now)
        if let lastTake, controller.playing {
            let take = Double(now - lastTake) / 1000 * rate
            if level + 1e-9 >= take {
                level -= take
                inGap = false
            } else {
                if !inGap { stats.gaps += 1 }
                inGap = true
                level = 0
            }
        }
        lastTake = now
        // As `SoundOutput.checkDry`: dry for a tick's length is a stall.
        if controller.playing, level <= 0 {
            if let since = dryAt, now - since >= 15_000 {
                controller.ranDry()
                smoothed = nil
                dryAt = nil
            } else if dryAt == nil {
                dryAt = now
            }
        } else {
            dryAt = nil
        }
        steer(waiting: nil, now: now)
    }

    private func play(_ steps: [AudioPlayout.Step], now: Int64) {
        for step in steps {
            var timestamp: UInt64?
            switch step {
            case .decode(let packet, let time):
                _ = try? decoder.decode(packet)
                timestamp = time
            case .recover(let next, let time):
                _ = try? decoder.recover(lostBefore: next)
                timestamp = time
            case .conceal(let time):
                _ = try? decoder.conceal()
                timestamp = time
            }
            enqueue(captureTime: timestamp.flatMap { Int64(exactly: $0) }, frameMs: 10, now: now)
        }
    }

    /// As `SoundOutput.add`.
    private func enqueue(captureTime: Int64?, frameMs: Double, now: Int64) {
        let arrival = captureTime.flatMap { clock.milliseconds(since: $0, now: now) }
        let trueArrival = captureTime.map { Double(now - $0) / 1000 }
        if syncChecked.map({ now - $0 >= 100_000 }) ?? true {
            syncChecked = now
            arrivals.removeAll { now - $0.at > controller.settings.jitterWindow }
            if let floor = sync.soundFloor(now: now),
               let mean = arrivals.isEmpty ? arrival : arrivals.reduce(0, { $0 + $1.ms }) / Double(arrivals.count) {
                controller.syncFloorMs = SyncRule.bufferFloor(soundFloor: floor, meanArrivalMs: mean,
                                                              outputLatencyMs: outputLatencyMs)
            } else {
                controller.syncFloorMs = 0
            }
        }
        let waiting = level + filling.reduce(0, +)
        guard controller.admit(transit: captureTime.map { now - $0 }, queuedMs: waiting, frameMs: frameMs, now: now) else {
            return
        }
        if let arrival {
            arrivals.append((now, arrival))
            if let trueArrival { stats.clockErrors.append(arrival - trueArrival) }
        }
        if controller.playing {
            measure(arrival: arrival, trueArrival: trueArrival, waiting: waiting, now: now)
            steer(waiting: waiting, now: now)
            level += frameMs
        } else {
            filling.append(frameMs)
            if controller.shouldStart(queuedMs: level + filling.reduce(0, +) - frameMs) {
                var excess = controller.startExcess(queuedMs: level + filling.reduce(0, +) - frameMs)
                while excess > 0, filling.count > 1, filling[0] <= excess { excess -= filling.removeFirst() }
                measure(arrival: arrival, trueArrival: trueArrival, waiting: level + filling.reduce(0, +) - frameMs, now: now)
                level += filling.reduce(0, +)
                filling = []
            }
            steer(waiting: nil, now: now)
        }
    }

    private func measure(arrival: Double?, trueArrival: Double?, waiting: Double, now: Int64) {
        if let arrival {
            let measured = arrival + waiting + outputLatencyMs
            let value = soundDelay.map { $0 + (measured - $0) * 0.1 } ?? measured
            soundDelay = value
            sync.soundPlaying(delayMs: value, now: now)
        }
        if let trueArrival {
            let measured = trueArrival + waiting + outputLatencyMs
            trueDelay = trueDelay.map { $0 + (measured - $0) * 0.1 } ?? measured
        }
        if let trueDelay { recorder.sound(trueMs: trueDelay, estimateMs: soundDelay) }
    }

    private func steer(waiting: Double?, now: Int64) {
        if let waiting { smoothed = smoothed.map { $0 + (waiting - $0) * 0.15 } ?? waiting }
        rate = controller.update(queuedMs: smoothed ?? controller.targetMs, now: now)
    }
}
