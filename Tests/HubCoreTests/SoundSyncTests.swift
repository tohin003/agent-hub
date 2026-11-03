import Accelerate
import AVFAudio
import Foundation
import Testing

/// Plan step 2, the Mac's sound in step with its picture, measured: the phone's estimate of the Mac's clock under
/// jitter; the adaptive buffer (convergence and clock drift without drops, a stall, the time-stretch bounds, and
/// AVAudioUnitVarispeed itself); the sync rule in both modes with a speaker's and AirPods' latency; AAC-ELD through
/// the encoder and decoder with its capture times; and how long capture to decoded takes with each codec.
@Suite("Sound in step with the picture")
struct SoundSyncTests {
    // MARK: The Mac's clock

    /// One way on a jittery Wi-Fi link, µs: a base, a little exponential jitter, and in one case in ten a hiccup.
    static func oneWay(base: Int64, _ random: inout SeededGenerator) -> Int64 {
        var jitter = -log(1 - random.unit()) * 2_000
        if random.chance(0.1) { jitter += 20_000 + random.unit() * 40_000 }
        return base + Int64(jitter)
    }

    /// `mac.clock` exchanges over a link whose way there (4 ms at best) is slower than the way back (2 ms), with a
    /// 20–60 ms hiccup in one exchange in ten: the tightest exchange of the last 30 s keeps the Mac's clock within a
    /// couple of ms, where the latest exchange alone would be off by tens.
    @Test func macClockHoldsUnderJitter() {
        let clock = MacClock()
        var random = SeededGenerator(seed: 21)
        // The Mac's host clock reads this much more than the phone's; only its low 32 bits travel.
        let macAhead: Int64 = 7_654_321_987
        var phone: Int64 = 5_000_000
        var errors: [Double] = []
        var latestErrors: [Double] = []
        for exchange in 0..<60 {
            let up = Self.oneWay(base: 4_000, &random)
            let down = Self.oneWay(base: 2_000, &random)
            clock.exchange(sent: phone, hostTime: phone + up + macAhead, received: phone + up + down)
            phone += up + down
            // A moment the Mac captured 50 ms ago, seen from the phone now.
            if exchange >= 2, let measured = clock.milliseconds(since: phone - 50_000 + macAhead, now: phone) {
                errors.append(abs(measured - 50))
                latestErrors.append(abs(Double(down - up) / 2_000))
            }
            phone += exchange < 5 ? 300_000 : 5_000_000
        }
        let sorted = errors.sorted()
        let latest = latestErrors.sorted()
        reportMetric(String(format: "Mac clock from mac.clock exchanges under Wi-Fi jitter (4/2 ms each way, 10%% hiccups "
            + "of 20–60 ms): error median %.2f ms, worst %.2f ms; the latest exchange alone: median %.2f ms, worst %.1f ms",
            sorted[sorted.count / 2], sorted.last ?? 0, latest[latest.count / 2], latest.last ?? 0))
        #expect(errors.count == 58)
        #expect((sorted.last ?? 99) <= 3, "within 3 ms throughout")
        #expect(sorted[sorted.count / 2] <= 2)
        #expect((latest.last ?? 0) >= 10, "the hiccups would show without the filter")
    }

    @Test func theUDPSessionsEstimateComesFirstWhileFresh() {
        let clock = MacClock()
        clock.use(hub: "mac-a")
        // Asked at 0, answered at 10 ms, the Mac said 1 ms: its moment is taken as the 5 ms midpoint.
        clock.exchange(sent: 0, hostTime: 1_000, received: 10_000)
        #expect(clock.offset(now: 20_000) == 4_000)
        #expect(clock.exchangeRoundTrip(now: 20_000) == 10_000)
        clock.transport(offset: 3_900, now: 20_000)
        #expect(clock.offset(now: 21_000) == 3_900)
        #expect(clock.exchangeRoundTrip(now: 21_000) == nil)
        // The session stopped: back to the exchanges, until they're 30 s old.
        #expect(clock.offset(now: 20_000 + MacClock.transportFresh + 1) == 4_000)
        #expect(clock.offset(now: 10_000 + MacClock.window + 1) == nil)
        clock.use(hub: "mac-a")
        #expect(clock.offset(now: 21_000) == 3_900, "the same Mac keeps what's known")
        clock.use(hub: "mac-b")
        #expect(clock.offset(now: 21_000) == nil, "another Mac's clock is another clock")
    }

    // MARK: The buffer

    /// Wi-Fi at home: 6 ms at best, up to 8 ms of jitter on top, and one frame in a hundred up to 8 ms later still.
    static func homeTransit(_ index: Int, _ random: inout SeededGenerator) -> Double {
        var transit = 6 + random.unit() * 8
        if random.chance(0.01) { transit += random.unit() * 8 }
        return transit
    }

    /// Two minutes at home with the Mac's clock running 500 ppm fast, then slow (ten times a typical crystal's error):
    /// the buffer settles at 20 ms and stays within a few ms of it with the rate never past 2%, and not one frame is
    /// skipped or gap heard.
    @Test(arguments: [500.0, -500.0])
    func theBufferSettlesWithoutDrops(driftPPM: Double) {
        var run = SoundRun(seconds: 120, floorMs: 20, transit: Self.homeTransit)
        run.driftPPM = driftPPM
        let result = run.run()
        let steady = Array(result.levels.suffix(6000))
        let mean = steady.reduce(0, +) / Double(steady.count)
        let rates = Array(result.rates.suffix(3000))
        let meanRate = rates.reduce(0, +) / Double(rates.count)
        reportMetric(String(format: "Sound buffer at home, Mac clock %+.0f ppm, 120 s: target %.1f ms (jitter %.1f ms), "
            + "level over the last minute %.1f ms (%.1f–%.1f), rate %.4f–%.4f (mean %.5f), steepest change %.4f/s, "
            + "%d gaps, %d underruns, %.0f ms skipped, playing after %.0f ms",
            driftPPM, result.targetMs, result.jitterMs, mean, steady.min() ?? 0, steady.max() ?? 0, result.lowestRate,
            result.highestRate, meanRate, result.steepestSlew, result.gaps, result.underruns, result.skippedMs,
            (result.started ?? 0) * 1000) + (result.gapNotes.isEmpty ? "" : "; gaps: " + result.gapNotes.joined(separator: " | ")))
        #expect(result.targetMs >= 20 && result.targetMs <= 40, "20–40 ms at home")
        #expect(abs(mean - result.targetMs) < 3)
        #expect(result.gaps == 0)
        #expect(result.underruns == 0)
        #expect(result.skippedMs == 0)
        #expect(result.lowestRate >= 0.98 && result.highestRate <= 1.02)
        #expect(result.steepestSlew <= 0.0201)
        // The drift is what the rate makes up: a Mac 500 ppm fast needs 1.0005 on average.
        #expect(abs(meanRate - (1 + driftPPM / 1e6)) < 0.0003)
    }

    /// Paths with more jitter hold more: a peer relay's floor and a DERP server's, with the jitter measured on top.
    @Test func relaysHoldMore() {
        var relay = SoundRun(seconds: 30, floorMs: PlayoutController.Settings.forPath(bufferMs: 50).floorMs) { _, random in
            25 + random.unit() * 30
        }
        relay.seed = 3
        let derp = SoundRun(seconds: 30, floorMs: PlayoutController.Settings.forPath(bufferMs: 100).floorMs) { _, random in
            60 + random.unit() * 40
        }
        let relayResult = relay.run()
        let derpResult = derp.run()
        reportMetric(String(format: "Sound buffer on a peer relay (25–55 ms transit): target %.1f ms, %d gaps; through DERP "
            + "(60–100 ms): target %.1f ms, %d gaps", relayResult.targetMs, relayResult.gaps, derpResult.targetMs,
            derpResult.gaps))
        #expect(relayResult.targetMs >= 37 && relayResult.targetMs <= 45)
        #expect(derpResult.targetMs >= 90)
        #expect(relayResult.gaps == 0 && derpResult.gaps == 0)
    }

    /// The link stalls for 300 ms: the buffer runs dry once, fills again from fresh sound (the burst the stall held
    /// up is skipped, not played late), and is back at its level within a second, with no more gaps.
    @Test func aStallIsSkippedNotPlayedLate() {
        var run = SoundRun(seconds: 60, floorMs: 20, transit: Self.homeTransit)
        run.stall = SoundRun.Stall(firstFrame: 3_000, lastFrame: 3_029, heldUntilMs: 30_300)
        let result = run.run()
        let after = Array(result.levels.suffix(1000))
        let mean = after.reduce(0, +) / Double(after.count)
        reportMetric(String(format: "A 300 ms stall: %d underrun, %d gap, %.0f ms of late sound skipped (%d frames held up "
            + "kept out of the jitter), playing again %.0f ms after it began, level afterwards %.1f ms (target %.1f)",
            result.underruns, result.gaps, result.skippedMs, result.stalledFrames, result.resumedAfterStallMs ?? -1, mean,
            result.targetMs))
        #expect(result.underruns == 1)
        #expect(result.gaps == 1)
        #expect(result.skippedMs >= 250 && result.skippedMs <= 300)
        #expect((result.resumedAfterStallMs ?? 999) < 360)
        #expect(abs(mean - result.targetMs) < 3)
        #expect(result.targetMs < 30, "the stall didn't count as jitter")
    }

    /// The time-stretch bounds: far over the target the rate climbs at 2% a second to 1.02 and stays there; far under,
    /// to 0.98; within the deadband it comes back to 1.
    @Test func theRateStaysWithinTwoPercent() {
        var controller = PlayoutController(settings: .init(floorMs: 50))
        let admitted = controller.admit(transit: 5_000, queuedMs: 0, frameMs: 10, now: 0)
        #expect(admitted)
        let started = controller.shouldStart(queuedMs: 50)
        #expect(started)
        var rates: [Double] = []
        var now: Int64 = 0
        // 3 s 200 ms over the 50 ms target, 3 s with nothing waiting, 3 s at the target.
        for level in [250.0, 0, 50] {
            for _ in 0..<150 {
                now += 20_000
                rates.append(controller.update(queuedMs: level, now: now))
            }
        }
        let steepest = zip(rates, rates.dropFirst()).map { abs($1 - $0) / 0.02 }.max() ?? 0
        reportMetric(String(format: "Time-stretch: the rate reaches %.4f over the target and %.4f under it, changing at most "
            + "%.4f a second; back to %.4f at the target", rates[149], rates[299], steepest, rates.last ?? 0))
        #expect(rates.allSatisfy { $0 >= 0.98 - 1e-9 && $0 <= 1.02 + 1e-9 })
        #expect(abs(rates[149] - 1.02) < 1e-9)
        #expect(abs(rates[299] - 0.98) < 1e-9)
        #expect(abs((rates.last ?? 0) - 1) < 1e-9)
        #expect(steepest <= 0.02 + 1e-9)
    }

    /// AVAudioUnitVarispeed, as the phone runs it, at 2% fast and 2% slow: two seconds of a 1 kHz tone come out 2%
    /// shorter or longer at a pitch 2% higher or lower, with no gap anywhere.
    @Test(arguments: [1.02, 0.98])
    func varispeedStretchesWithoutGaps(rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        try engine.start()
        defer { engine.stop() }
        varispeed.rate = Float(rate)
        let input = 96_000
        let tone = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input)))
        tone.frameLength = AVAudioFrameCount(input)
        let channels = try #require(tone.floatChannelData)
        for frame in 0..<input {
            let sample = Float(0.5 * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        player.scheduleBuffer(tone)
        player.play()
        let out = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480))
        var heard: [Float] = []
        while heard.count < Int(Double(input) / rate) + 9_600 {
            guard try engine.renderOffline(480, to: out) == .success, let left = out.floatChannelData?[0] else { break }
            heard += UnsafeBufferPointer(start: left, count: Int(out.frameLength))
        }
        let first = try #require(heard.firstIndex { abs($0) > 0.05 })
        let last = try #require(heard.lastIndex { abs($0) > 0.05 })
        let seconds = Double(last - first) / 48_000
        let middle = Array(heard[(first + 4_800)..<(last - 4_800)])
        let rises = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let pitch = Double(rises) / (Double(middle.count) / 48_000)
        // A gap: 2 ms or more without a sample above a tenth of the tone's level (a 1 kHz tone passes 0.05 every 0.5 ms).
        var quiet = 0
        var gaps = 0
        for sample in heard[first...last] {
            if abs(sample) < 0.05 {
                quiet += 1
                if quiet == 96 { gaps += 1 }
            } else {
                quiet = 0
            }
        }
        reportMetric(String(format: "AVAudioUnitVarispeed at %.2f: 2 s of 1 kHz lasts %.4f s (expected %.4f) at %.1f Hz, "
            + "%d gaps", rate, seconds, 2 / rate, pitch, gaps))
        #expect(abs(seconds - 2 / rate) < 0.01)
        #expect(abs(pitch - 1_000 * rate) < 3)
        #expect(gaps == 0)
    }

    // MARK: The sync rule

    /// The picture: 40–50 ms from the Mac's capture to the phone's glass.
    static func pictureDelay(_ random: inout SeededGenerator) -> Double { 40 + random.unit() * 10 }

    /// Each mode with the phone's speaker (8 ms out) and with AirPods (180 ms, a typical Bluetooth delay):
    /// - lowest delay never holds the picture; the sound is never ahead of it, trailing it by a few ms on the
    ///   speaker and by its whole Bluetooth delay on AirPods;
    /// - lip-sync holds the picture just enough that the sound trails it by about 20 ms, within the 0–40 ms the rule
    ///   allows, on either.
    @Test(arguments: [(false, 8.0), (false, 180.0), (true, 8.0), (true, 180.0)])
    func theSyncRule(lipSync: Bool, outputLatencyMs: Double) {
        let sync = MediaSync()
        sync.lipSync = lipSync
        var run = SoundRun(seconds: 20, floorMs: 20, transit: Self.homeTransit)
        run.sync = sync
        run.outputLatency = { _ in outputLatencyMs }
        run.pictureDelay = Self.pictureDelay
        let result = run.run()
        let settled = result.syncSamples.filter { $0.time >= 10 }
        let offsets = settled.map { $0.sound - $0.picture }.sorted()
        let holds = settled.map(\.hold)
        let meanOffset = offsets.reduce(0, +) / Double(offsets.count)
        let picture = settled.map(\.picture).reduce(0, +) / Double(settled.count)
        let sound = settled.map(\.sound).reduce(0, +) / Double(settled.count)
        reportMetric(String(format: "Sync rule, %@, output %.0f ms: picture %.1f ms (held %.1f ms), sound %.1f ms; the sound "
            + "trails by %.1f ms (%.1f to %.1f); buffer target %.1f ms, %d gaps",
            lipSync ? "lip-sync" : "lowest delay", outputLatencyMs, picture, holds.max() ?? 0, sound, meanOffset,
            offsets.first ?? 0, offsets.last ?? 0, result.targetMs, result.gaps))
        #expect(!settled.isEmpty)
        #expect((offsets.first ?? -1) >= 0, "the sound is never ahead of the picture")
        #expect(result.gaps == 0)
        if lipSync {
            #expect((offsets.last ?? 99) <= SyncRule.maxTrailMs)
            if outputLatencyMs > 100 { #expect(abs(meanOffset - SyncRule.lipSyncTrailMs) < 6) }
        } else {
            #expect(holds.allSatisfy { $0 == 0 }, "the picture is never held back")
            if outputLatencyMs < 100 { #expect((offsets.last ?? 99) <= SyncRule.maxTrailMs) }
        }
    }

    /// Lip-sync through route changes: the speaker, then AirPods for 8 s, then the speaker again. The hold follows
    /// (up at 150 ms a second, down at 1,500), each stretch settles within the rule, and the sound is ahead of the
    /// picture only for a moment after the AirPods go.
    @Test func lipSyncFollowsTheRoute() {
        let sync = MediaSync()
        sync.lipSync = true
        var run = SoundRun(seconds: 24, floorMs: 20, transit: Self.homeTransit)
        run.sync = sync
        run.outputLatency = { time in time >= 8 && time < 16 ? 180 : 8 }
        run.pictureDelay = Self.pictureDelay
        let result = run.run()
        let samples = result.syncSamples
        let ahead = samples.filter { $0.sound < $0.picture }
        let aheadSeconds = Double(ahead.count) / 60
        let worstAhead = ahead.map { $0.picture - $0.sound }.max() ?? 0
        let farBehind = Double(samples.filter { $0.sound - $0.picture > SyncRule.maxTrailMs }.count) / 60
        var settledOffsets: [Double] = []
        for range in [4.0..<8.0, 12.0..<16.0, 20.0..<24.0] {
            settledOffsets += samples.filter { range.contains($0.time) }.map { $0.sound - $0.picture }
        }
        reportMetric(String(format: "Lip-sync through speaker → AirPods → speaker: settled offsets %.1f to %.1f ms; the sound "
            + "ahead for %.2f s (by up to %.0f ms) after the AirPods go, more than 40 ms behind for %.2f s while the hold "
            + "grows", settledOffsets.min() ?? 0, settledOffsets.max() ?? 0, aheadSeconds, worstAhead, farBehind))
        #expect((settledOffsets.min() ?? -1) >= 0)
        #expect((settledOffsets.max() ?? 99) <= SyncRule.maxTrailMs)
        #expect(aheadSeconds <= 0.25)
        #expect(farBehind <= 1.2)
    }

    // MARK: AAC-ELD

    /// The WebSocket's codec: a chord through AAC-ELD at 480 frames (10 ms) a packet comes back delayed by exactly
    /// the encoder's priming (240 samples, 5 ms), so the capture time stamped on each packet's first decoded sample
    /// is that sample's true capture time; and it comes back clean. AAC-LC's delay, for comparison.
    @Test(arguments: [MacAudioCodec.aacELD, MacAudioCodec.aacLC])
    func aacRoundTripKeepsTimeAndSound(codec: String) throws {
        let rate = 48_000.0
        let encoder = try MacAudioEncoder(codec: codec, sampleRate: rate, channels: 2)
        let decoder = try MacAudioDecoder(format: encoder.format)
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        var clock = SampleClock(sampleRate: rate, leadingFrames: encoder.leadingFrames)
        // Twelve partials at odd frequencies, so the signal doesn't repeat within the delays searched.
        var random = SeededGenerator(seed: 9)
        var frequencies: [Double] = []
        var phases: [Double] = []
        for _ in 0..<12 {
            frequencies.append(150 + random.unit() * 5_000)
            phases.append(random.unit() * 2 * Double.pi)
        }
        var sent: [Float] = []
        var heard: [Float] = []
        var stamps: [Stamp] = []
        var packetsOut = 0
        for piece in 0..<200 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
            buffer.frameLength = 480
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<480 {
                let t = Double(piece * 480 + frame) / rate
                var sum = 0.0
                for partial in 0..<12 { sum += 0.05 * sin(2 * Double.pi * frequencies[partial] * t + phases[partial]) }
                let value = Float(sum)
                channels[0][frame] = value
                channels[1][frame] = value
                sent.append(value)
            }
            // Captured at 10 ms a piece from 1 s on the Mac's clock.
            clock.input(frames: 480, captureTime: 1_000_000 + Int64(piece) * 10_000)
            let packets = encoder.encode(buffer)
            guard !packets.isEmpty else { continue }
            if let time = clock.captureTime(ofDecodedSample: packetsOut * encoder.format.framesPerPacket) {
                stamps.append(Stamp(sample: heard.count, time: time))
            }
            packetsOut += packets.count
            guard let pcm = decoder.decode(packets), let left = pcm.floatChannelData?[0] else { continue }
            heard += UnsafeBufferPointer(start: left, count: Int(pcm.frameLength))
        }
        // The delay: where the decoded sound best matches what went in.
        let span = 24_000
        let expected = encoder.leadingFrames
        try #require(heard.count >= 24_000 + span + expected + 300)
        var bestLag = 0
        var bestScore = -Float.infinity
        for lag in max(0, expected - 300)...(expected + 300) {
            var score: Float = 0
            sent.withUnsafeBufferPointer { a in
                heard.withUnsafeBufferPointer { b in
                    guard let a = a.baseAddress, let b = b.baseAddress else { return }
                    vDSP_dotpr(a + 24_000, 1, b + 24_000 + lag, 1, &score, vDSP_Length(span))
                }
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        // The stamps: decoded sample i was captured at 1 s + (i − delay) / rate.
        var stampErrors: [Double] = []
        for stamp in stamps {
            stampErrors.append(abs(Double(stamp.time - 1_000_000) - Double(stamp.sample - bestLag) / rate * 1e6))
        }
        var signal: Float = 0
        var noise: Float = 0
        for index in 24_000..<(24_000 + span) {
            let error = heard[index + bestLag] - sent[index]
            signal += sent[index] * sent[index]
            noise += error * error
        }
        let snr = 10 * log10(Double(signal / max(noise, 1e-12)))
        reportMetric(String(format: "%@ round trip: %d frames a packet, delay %d samples (%.1f ms; the encoder's priming is "
            + "%d), capture-time stamps off by at most %.0f µs, SNR %.1f dB", codec, encoder.format.framesPerPacket, bestLag,
            Double(bestLag) / 48, expected, stampErrors.max() ?? -1, snr))
        #expect(bestLag == expected, "the decoder's delay is the encoder's priming")
        #expect((stampErrors.max() ?? 999) < 25, "each packet's stamp is its first sample's capture time")
        #expect(snr > 12)
        if codec == MacAudioCodec.aacELD {
            #expect(encoder.format.framesPerPacket == 480)
            #expect(expected <= 512, "AAC-ELD's delay is a few ms, not AAC-LC's 44")
        }
    }

    struct Stamp {
        /// Where a packet's decoded sound starts in what was heard.
        var sample: Int
        /// The capture time the hub stamps on it.
        var time: Int64
    }

    @Test func timedMessagesCarryTheCaptureTime() throws {
        let packets = [Data([1, 2, 3]), Data(repeating: 9, count: 300)]
        let message = TimedAudioMessage.make(sequence: 77, captureTime: 123_456_789_012, packets: packets)
        let parsed = try #require(TimedAudioMessage.parse(message))
        #expect(parsed.sequence == 77)
        #expect(parsed.captureTime == 123_456_789_012)
        #expect(parsed.packets == packets)
        #expect(AudioPacketMessage.parse(message) == nil, "an older phone's parser leaves it alone")
        #expect(TimedAudioMessage.parse(AudioPacketMessage.make(sequence: 1, packets: packets)) == nil)
        #expect(TimedAudioMessage.parse(message.dropLast()) == nil, "cut short")
        #expect(TimedAudioMessage.parse(Data()) == nil)
    }

    @Test func theSampleClockStampsDecodedSamples() {
        var clock = SampleClock(sampleRate: 48_000, leadingFrames: 240)
        #expect(clock.captureTime(ofDecodedSample: 0) == nil)
        clock.input(frames: 480, captureTime: 1_000_000)
        clock.input(frames: 480, captureTime: 1_010_000)
        // The decoder plays the priming first: decoded sample 240 is the first sample captured.
        #expect(clock.captureTime(ofDecodedSample: 240) == 1_000_000)
        #expect(clock.captureTime(ofDecodedSample: 720) == 1_010_000)
        #expect(clock.captureTime(ofDecodedSample: 0) == 995_000)
        // The capture paused for 100 ms: times count from there.
        clock.input(frames: 480, captureTime: 1_120_000)
        #expect(clock.captureTime(ofDecodedSample: 1_200) == 1_120_000)
        // A timestamp a millisecond off doesn't move the count.
        clock.input(frames: 480, captureTime: 1_131_000)
        #expect(clock.captureTime(ofDecodedSample: 1_680) == 1_130_000)
    }

    /// The older request (no parameters) still gets AAC-LC untimed; a step-2 phone asks for AAC-ELD with times.
    @Test func soundParamsDecodeBothWays() throws {
        let ask = ScreenAudioParams()
        #expect(ask.codecs == [MacAudioCodec.aacELD, MacAudioCodec.aacLC])
        #expect(ask.timed)
        let decoded = try WireCoding.decoder.decode(ScreenAudioParams.self, from: WireCoding.encoder.encode(ask))
        #expect(decoded == ask)
        // An older phone sends `{}`: it isn't a step-2 ask.
        #expect((try? WireCoding.decoder.decode(ScreenAudioParams.self, from: Data("{}".utf8))) == nil)
        var format = MacAudioFormat(codec: MacAudioCodec.aacELD, sampleRate: 48_000, channels: 2, framesPerPacket: 480,
                                    magicCookie: Data([1, 2]))
        format.timed = true
        let back = try WireCoding.decoder.decode(MacAudioFormat.self, from: WireCoding.encoder.encode(format))
        #expect(back.timed == true)
        let old = try WireCoding.decoder.decode(
            MacAudioFormat.self, from: Data(#"{"codec":"aac","sampleRate":48000,"channels":2,"framesPerPacket":1024,"magicCookie":""}"#.utf8))
        #expect(old.timed == nil, "an older hub's format has no times")
    }

    // MARK: Capture to decoded

    /// How long from a sample's capture to its decoded output on this Mac, per codec: waiting for its packet to fill,
    /// the codec's own delay, and the time to encode and decode the packet.
    @Test func captureToDecodedProbe() throws {
        let rate = 48_000.0
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try #require(buffer.floatChannelData)
        var interleaved = [Float](repeating: 0, count: 960)
        var lines: [String] = []
        var totals: [String: Double] = [:]
        for codec in [MacAudioCodec.aacELD, MacAudioCodec.aacLC, "opus"] {
            var encodeTimes: [Double] = []
            var decodeTimes: [Double] = []
            var packetFrames = 480
            var leading = 0
            if codec == "opus" {
                let encoder = try OpusAudioEncoder(channels: 2, bitrate: 96_000)
                let decoder = try OpusAudioDecoder(channels: 2)
                leading = encoder.lookahead
                for piece in 0..<300 {
                    for frame in 0..<480 {
                        let value = Float(0.3 * sin(2 * .pi * 440 * Double(piece * 480 + frame) / rate))
                        interleaved[frame * 2] = value
                        interleaved[frame * 2 + 1] = value
                    }
                    let start = ContinuousClock.now
                    let packets = try interleaved.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
                    encodeTimes.append(Self.microseconds(since: start))
                    for packet in packets {
                        let decodeStart = ContinuousClock.now
                        _ = try decoder.decode(packet)
                        decodeTimes.append(Self.microseconds(since: decodeStart))
                    }
                }
            } else {
                let encoder = try MacAudioEncoder(codec: codec, sampleRate: rate, channels: 2)
                let decoder = try MacAudioDecoder(format: encoder.format)
                packetFrames = encoder.format.framesPerPacket
                leading = encoder.leadingFrames
                for piece in 0..<300 {
                    for frame in 0..<480 {
                        let value = Float(0.3 * sin(2 * .pi * 440 * Double(piece * 480 + frame) / rate))
                        channels[0][frame] = value
                        channels[1][frame] = value
                    }
                    let start = ContinuousClock.now
                    let packets = encoder.encode(buffer)
                    guard !packets.isEmpty else { continue }
                    encodeTimes.append(Self.microseconds(since: start) / Double(packets.count))
                    let decodeStart = ContinuousClock.now
                    _ = decoder.decode(packets)
                    decodeTimes.append(Self.microseconds(since: decodeStart) / Double(packets.count))
                }
            }
            let encode = Self.median(encodeTimes)
            let decode = Self.median(decodeTimes)
            let total = Double(packetFrames + leading) / rate * 1000 + (encode + decode) / 1000
            totals[codec] = total
            lines.append(String(format: "%@ %.1f ms (packet %.1f ms + codec delay %.1f ms + encode %.0f µs + decode %.0f µs)",
                                codec, total, Double(packetFrames) / 48, Double(leading) / 48, encode, decode))
        }
        reportMetric("Capture to decoded on this Mac: " + lines.joined(separator: "; "))
        #expect((totals[MacAudioCodec.aacELD] ?? 99) < 20)
        #expect((totals["opus"] ?? 99) < 20)
        #expect((totals[MacAudioCodec.aacLC] ?? 0) > 60, "what AAC-ELD saves over AAC-LC")
    }

    static func microseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

/// The phone's sound buffer on a simulated clock, in steps of 1 ms, run the way `SoundOutput` runs
/// `PlayoutController`: 10 ms frames captured on the Mac's clock arrive after a transit (released in order, as
/// `AudioPlayout` does) and the output takes 5 ms at a time (its IO buffer), more or less as the rate says; a take that
/// finds too little is a gap. Given a `MediaSync`, a picture beside it at 60 frames a second, and the sync rule.
struct SoundRun {
    struct Stall {
        var firstFrame: Int
        var lastFrame: Int
        /// When the held-up frames arrive (ms on the phone's clock).
        var heldUntilMs: Double
    }

    struct SyncSample {
        /// Seconds into the run.
        var time: Double
        /// Capture to the glass, the hold included (as `MediaSync.shownPictureDelay`), ms.
        var picture: Double
        /// Capture to the ear, ms.
        var sound: Double
        var hold: Double
    }

    struct Result {
        var gaps = 0
        var underruns = 0
        var skippedMs = 0.0
        var stalledFrames = 0
        var lowestRate = 1.0
        var highestRate = 1.0
        /// The fastest the rate changed between two updates, per second.
        var steepestSlew = 0.0
        /// From the third second on: the level as each frame arrives (what the controller steers), and the rate
        /// every 20 ms.
        var levels: [Double] = []
        var rates: [Double] = []
        var targetMs = 0.0
        var jitterMs = 0.0
        /// When playing first started, s.
        var started: Double?
        var resumedAfterStallMs: Double?
        var syncSamples: [SyncSample] = []
        /// Each gap: when (s), and the level, smoothed level, target and rate just before it.
        var gapNotes: [String] = []
    }

    var seconds: Double
    var floorMs: Double
    /// A frame's transit, ms.
    var transit: (Int, inout SeededGenerator) -> Double
    var seed: UInt64 = 1
    /// The Mac's clock runs this much faster than the phone's (parts per million): its sound comes that much faster.
    var driftPPM = 0.0
    /// The output's latency at a moment (s into the run): the speaker's, or AirPods'.
    var outputLatency: (Double) -> Double = { _ in 8 }
    var sync: MediaSync?
    /// The picture's delay to the glass, ms, before any hold.
    var pictureDelay: (inout SeededGenerator) -> Double = { _ in 45 }
    var stall: Stall?

    init(seconds: Double, floorMs: Double, transit: @escaping (Int, inout SeededGenerator) -> Double) {
        self.seconds = seconds
        self.floorMs = floorMs
        self.transit = transit
    }

    func run() -> Result {
        var random = SeededGenerator(seed: seed)
        var result = Result()
        var controller = PlayoutController(settings: .init(floorMs: floorMs))
        let frames = Int(seconds * 100)
        // Each frame's capture on the phone's clock, and when it's released to the buffer.
        var phoneCaptures: [Int64] = []
        var releases: [Int64] = []
        var latest: Int64 = 0
        for index in 0..<frames {
            let capture = Int64(index) * 10_000
            let phoneCapture = capture - Int64(Double(capture) * driftPPM / 1e6)
            var arrival = phoneCapture + Int64(transit(index, &random) * 1000)
            if let stall, index >= stall.firstFrame, index <= stall.lastFrame {
                arrival = max(arrival, Int64(stall.heldUntilMs * 1000))
            }
            latest = max(latest, arrival)
            phoneCaptures.append(phoneCapture)
            releases.append(latest)
        }
        var level = 0.0
        var filling: [Double] = []
        var smoothed: Double?
        var rate = 1.0
        var lastRate: Int64?
        var next = 0
        var soundDelay: Double?
        var arrivals: [(at: Int64, ms: Double)] = []
        var syncChecked: Int64?
        var nextPicture: Int64 = 0
        var inGap = false
        var dryAt: Int64?
        var stallBegan: Int64?
        var latency = outputLatency(0)
        let settle: Int64 = 3_000_000
        let end = Int64(seconds * 1e6)

        /// As `SoundOutput.steer`: the level is the sound waiting as a frame arrives; the timer passes nil.
        func steer(waiting: Double?, _ now: Int64) {
            if let waiting { smoothed = smoothed.map { $0 + (waiting - $0) * 0.15 } ?? waiting }
            let wasPlaying = controller.playing
            let previous = rate
            rate = controller.update(queuedMs: smoothed ?? controller.targetMs, now: now)
            if wasPlaying, let lastRate, now > lastRate {
                result.steepestSlew = max(result.steepestSlew, abs(rate - previous) / (Double(now - lastRate) / 1e6))
            }
            lastRate = now
        }

        func measure(_ arrivalAndWaiting: Double, now: Int64) {
            let measured = arrivalAndWaiting + latency
            let value = soundDelay.map { $0 + (measured - $0) * 0.1 } ?? measured
            soundDelay = value
            sync?.soundPlaying(delayMs: value, now: now)
        }

        var now: Int64 = 0
        while now < end {
            // A new route (AirPods coming or going) restarts the engine: the buffer fills again (`SoundOutput.restart`).
            let route = outputLatency(Double(now) / 1e6)
            if route != latency {
                latency = route
                controller.refill()
                level = 0
                filling = []
                smoothed = nil
                soundDelay = nil
                syncChecked = nil
                sync?.soundStopped()
            }
            while next < frames, releases[next] <= now {
                let index = next
                next += 1
                let arrival = Double(now - phoneCaptures[index]) / 1000
                if let sync, syncChecked.map({ now - $0 >= 100_000 }) ?? true {
                    syncChecked = now
                    arrivals.removeAll { now - $0.at > controller.settings.jitterWindow }
                    if let floor = sync.soundFloor(now: now) {
                        let mean = arrivals.isEmpty ? arrival : arrivals.reduce(0) { $0 + $1.ms } / Double(arrivals.count)
                        controller.syncFloorMs = SyncRule.bufferFloor(soundFloor: floor, meanArrivalMs: mean,
                                                                      outputLatencyMs: latency)
                    } else {
                        controller.syncFloorMs = 0
                    }
                }
                let waiting = level + filling.reduce(0, +)
                let transitMicros = now - Int64(index) * 10_000
                guard controller.admit(transit: transitMicros, queuedMs: waiting, frameMs: 10, now: now) else { continue }
                arrivals.append((now, arrival))
                if controller.playing {
                    measure(arrival + waiting, now: now)
                    steer(waiting: waiting, now)
                    if now >= settle { result.levels.append(waiting) }
                    level += 10
                } else {
                    filling.append(10)
                    if controller.shouldStart(queuedMs: level + filling.reduce(0, +) - 10) {
                        var excess = controller.startExcess(queuedMs: level + filling.reduce(0, +) - 10)
                        while excess > 0, filling.count > 1, filling[0] <= excess { excess -= filling.removeFirst() }
                        if result.started == nil { result.started = Double(now) / 1e6 }
                        if let began = stallBegan, result.resumedAfterStallMs == nil {
                            result.resumedAfterStallMs = Double(now - began) / 1000
                        }
                        measure(arrival + level + filling.reduce(0, +) - 10, now: now)
                        level += filling.reduce(0, +)
                        filling = []
                    }
                    steer(waiting: nil, now)
                }
            }
            // Once the last frame is in, the sound ends: what follows its draining isn't a gap.
            if now % 5_000 == 0, controller.playing, next < frames {
                let take = 5 * rate
                if level + 1e-9 >= take {
                    level -= take
                    inGap = false
                } else {
                    if !inGap {
                        result.gaps += 1
                        result.gapNotes.append(String(format: "%.3f s: level %.2f, smoothed %.2f, target %.1f, rate %.4f, frame %d",
                                                      Double(now) / 1e6, level, smoothed ?? -1, controller.targetMs, rate, next))
                    }
                    inGap = true
                    if stallBegan == nil, stall != nil { stallBegan = now }
                    level = 0
                }
            }
            if now % 20_000 == 0 {
                // As `SoundOutput.checkDry`: dry at two ticks running is a stall.
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
                steer(waiting: nil, now)
                if now >= settle { result.rates.append(rate) }
            }
            if let sync, now >= nextPicture {
                nextPicture += 16_667
                let picture = pictureDelay(&random)
                sync.pictureShown(delayMs: picture, now: now)
                let hold = sync.pictureHold(now: now)
                if let soundDelay, controller.playing, let shown = sync.shownPictureDelay(now: now) {
                    result.syncSamples.append(SyncSample(time: Double(now) / 1e6, picture: shown, sound: soundDelay, hold: hold))
                }
            }
            now += 1_000
        }
        result.underruns = controller.stats.underruns
        result.skippedMs = controller.stats.skippedMs
        result.stalledFrames = controller.stats.stalledFrames
        result.lowestRate = controller.stats.lowestRate
        result.highestRate = controller.stats.highestRate
        result.targetMs = controller.targetMs
        result.jitterMs = controller.jitterMs
        return result
    }
}
