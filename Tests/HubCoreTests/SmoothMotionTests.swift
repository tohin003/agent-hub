import Foundation
import Testing

/// Smooth (an even pace from each frame's capture), how it meets lip-sync, and the order and place frames take on the
/// phone's display layer, in simulated time.
@Suite("Smooth motion")
struct SmoothMotionTests {
    /// A 60 fps stream: frames 16.667 ms apart on the Mac's clock (the phone's here: mapping it is `MacClock`'s job).
    static let frameInterval = 1_000_000.0 / 60
    /// An iPhone Pro's refresh, 120 Hz.
    static let refresh = 1_000_000.0 / 120
    static let part = ScreenRegion(x: 0.2, y: 0.25, width: 0.6, height: 0.6)

    struct Frame {
        /// µs.
        var capture: Double
        /// ms from capture to decoded.
        var delay: Double
        /// µs.
        var arrival: Double
    }

    /// The same noise every run.
    struct Noise: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Wi-Fi at home: 12 ms from capture to decoded and up to 3 ms of noise; every half second a stall holds three
    /// frames back (14, 9 and 4 ms more) and they come in a bunch; once in 7 s one frame is 60 ms late. Decoded in order.
    static func wifi(seconds: Double, seed: UInt64 = 7) -> [Frame] {
        var noise = Noise(state: seed)
        var frames: [Frame] = []
        var lastArrival = -Double.infinity
        for index in 0..<Int(seconds * 60) {
            let capture = 100_000 + Double(index) * frameInterval
            var delay = 12 + Double.random(in: 0..<3, using: &noise)
            switch index % 30 {
            case 10: delay += 14
            case 11: delay += 9
            case 12: delay += 4
            default: break
            }
            if index % 420 == 200 { delay += 60 }
            let arrival = max(capture + delay * 1000, lastArrival + 100)
            lastArrival = arrival
            frames.append(Frame(capture: capture, delay: (arrival - capture) / 1000, arrival: arrival))
        }
        return frames
    }

    static func percentile(_ values: [Double], _ share: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * share)]
    }

    // MARK: Smooth

    @Test func smoothEvensOutWiFiJitter() {
        let frames = Self.wifi(seconds: 20)
        var smoother = FrameSmoother()
        var shown: [Double] = []
        var holds: [Double] = []
        var late = Set<Int>()
        for (index, frame) in frames.enumerated() {
            let before = smoother.delayMs
            let hold = smoother.hold(arrivedAfter: frame.delay, now: Int64(frame.arrival))
            #expect(hold >= 0, "never before it arrives")
            // Late enough to see: over a quarter of a refresh past the steady delay.
            if hold == 0, let before, frame.delay > before + Self.refresh / 4000 { late.insert(index) }
            shown.append(frame.arrival + hold * 1000)
            holds.append(hold)
        }
        // Once 5 s have gone by.
        let settled = 300..<frames.count
        let paced = settled.dropFirst().filter { !late.contains($0) && !late.contains($0 - 1) }
        let smoothError = paced.map { abs(shown[$0] - shown[$0 - 1] - Self.frameInterval) }.max() ?? .infinity
        let arrivalError = settled.dropFirst().map { abs(frames[$0].arrival - frames[$0 - 1].arrival - Self.frameInterval) }.max() ?? 0
        let added = Array(holds[settled])
        let mean = added.reduce(0, +) / Double(added.count)
        print(String(format: "smooth: frames %.2f ms off an even pace at most (arrivals: %.2f ms); %d of %d late (%.1f%%); added delay mean %.1f ms, 95th percentile %.1f ms, most %.1f ms; steady delay %.1f ms",
                     smoothError / 1000, arrivalError / 1000, late.count, frames.count, 100 * Double(late.count) / Double(frames.count),
                     mean, Self.percentile(added, 0.95), added.max() ?? 0, smoother.delayMs ?? 0))
        #expect(smoothError <= Self.refresh / 4, "within a quarter of a refresh: \(smoothError / 1000) ms")
        #expect(arrivalError > Self.refresh, "the arrivals themselves are uneven")
        #expect(Double(late.count) <= Double(frames.count) * 0.01, "only the stalls' frames come visibly late")
        #expect(mean > 5 && mean < 17, "about a refresh at 60 Hz: \(mean) ms")
        #expect((added.max() ?? 0) < 20)
    }

    /// Smooth adds nothing on a steady link: frames already arriving at an even pace aren't held.
    @Test func aSteadyLinkGetsNoDelay() {
        var smoother = FrameSmoother()
        var most = 0.0
        for index in 0..<600 {
            let arrival = 100_000 + Double(index) * Self.frameInterval + 12_000
            most = max(most, smoother.hold(arrivedAfter: 12, now: Int64(arrival)))
        }
        #expect(most == 0)
    }

    // MARK: With lip-sync

    /// Plays frames through the picture's timing with the sound at `soundMs`; the frames' delays from capture to the
    /// glass once settled (after 5 s), and the sync's view of them.
    func delays(smooth: Bool, lipSync: Bool, soundMs: Double) -> (median: Double, readout: Double, floor: Double, smoothMs: Double) {
        let sync = MediaSync()
        sync.lipSync = lipSync
        var smoother = FrameSmoother()
        let latency = 12.5
        var settled: [Double] = []
        var last: Int64 = 0
        for (index, frame) in Self.wifi(seconds: 8).enumerated() {
            let now = Int64(frame.arrival)
            sync.soundPlaying(delayMs: soundMs, now: now)
            let time = PictureTiming.presentationTime(sinceCapture: frame.delay, smooth: smooth, smoother: &smoother, sync: sync,
                                                      displayLatencyMs: latency, now: now) ?? now
            if index >= 300 { settled.append(Double(time) / 1000 - frame.capture / 1000 + latency) }
            last = now
        }
        return (Self.percentile(settled, 0.5), sync.shownPictureDelay(now: last) ?? 0, sync.soundFloor(now: last) ?? 0,
                smoother.delayMs ?? 0)
    }

    @Test func lipSyncAndSmoothDontStack() {
        // AirPods: the sound 180 ms behind. Lip-sync wants the picture at 160 ms, with Smooth or without.
        let airPods = delays(smooth: true, lipSync: true, soundMs: 180)
        let airPodsPlain = delays(smooth: false, lipSync: true, soundMs: 180)
        // The speaker: the sound 30 ms behind, so lip-sync holds nothing and Smooth's delay stands.
        let speaker = delays(smooth: true, lipSync: true, soundMs: 30)
        let smoothOnly = delays(smooth: true, lipSync: false, soundMs: 30)
        print(String(format: "lip-sync with AirPods (180 ms): picture %.1f ms with Smooth, %.1f without; speaker (30 ms): %.1f with Smooth (its delay %.1f + 12.5); Smooth alone %.1f ms, readout %.1f, sound floor %.1f",
                     airPods.median, airPodsPlain.median, speaker.median, speaker.smoothMs, smoothOnly.median, smoothOnly.readout,
                     smoothOnly.floor))
        #expect(abs(airPods.median - 160) < 3, "the larger hold wins: \(airPods.median)")
        #expect(abs(airPods.median - airPodsPlain.median) < 3, "Smooth adds nothing on top of lip-sync's hold")
        #expect(abs(speaker.median - (speaker.smoothMs + 12.5)) < 1.5, "Smooth's delay wins: \(speaker.median)")
        #expect(abs(smoothOnly.readout - smoothOnly.median) < 1.5, "the readout includes Smooth's hold")
        #expect(smoothOnly.floor >= smoothOnly.median + 4, "the sound stays behind the smoothed picture")
    }

    // MARK: The layer's order and place

    struct Played {
        var shown: [(index: Int, at: Int64, region: ScreenRegion?)] = []
        var moves: [(at: Int64, region: ScreenRegion?)] = []
        var flushes = 0
        var drained = 0
    }

    /// Frames through a schedule: which show when (in the order they show), and where the layer goes when.
    func play(_ frames: [(now: Int64, region: ScreenRegion?, presentation: Int64?)], lead: Int64 = 8_333) -> Played {
        var schedule = SurfaceSchedule()
        var played = Played()
        for (index, frame) in frames.enumerated() {
            let step = schedule.step(region: frame.region, presentationTime: frame.presentation, now: frame.now, lead: lead)
            if step.flush {
                played.flushes += 1
                played.shown.removeAll { $0.at > frame.now }
                played.moves.removeAll { $0.at > frame.now }
            }
            if frame.presentation == nil, step.show != nil, !step.moves { played.drained += 1 }
            let at = step.show ?? frame.now
            if step.moves { played.moves.append((at, frame.region)) }
            played.shown.append((index, at, frame.region))
        }
        return played
    }

    /// Every frame that shows comes after the one before, and the layer is at its part from when it shows until the
    /// next one does: a frame of the old part never shows in the new place, nor the other way round.
    func expectInOrderAndInPlace(_ played: Played, _ comment: Comment) {
        for (earlier, later) in zip(played.shown, played.shown.dropFirst()) {
            #expect(later.at >= earlier.at, "frame \(later.index) shows before frame \(earlier.index): \(comment)")
            let place = played.moves.last { $0.at <= earlier.at }?.region
            #expect(place == earlier.region, "frame \(earlier.index) shows in another part's place: \(comment)")
            #expect(!played.moves.contains { $0.at > earlier.at && $0.at < later.at },
                    "the layer moves while frame \(earlier.index) shows: \(comment)")
        }
    }

    /// 60 frames, the part changing at frames 10 (zoom in) and 30 (back out), shown as `presentation` says.
    func zoomInAndOut(presentation: (Int, Int64) -> Int64?) -> [(now: Int64, region: ScreenRegion?, presentation: Int64?)] {
        (0..<60).map { index in
            let now = 1_000_000 + Int64(Double(index) * Self.frameInterval)
            return (now, (10..<30).contains(index) ? Self.part : nil, presentation(index, now))
        }
    }

    @Test func theLayerMovesWhenItsFrameShows() {
        // Lip-sync holding the picture 120 ms: six frames of the whole display still waiting when the zoom's first
        // frame comes, and they show in the whole display's place.
        let lipSync = play(zoomInAndOut { _, now in now + 120_000 })
        expectInOrderAndInPlace(lipSync, "lip-sync")
        #expect(lipSync.shown.count == 60 && lipSync.moves.count == 2)
        #expect(lipSync.moves.first?.at == lipSync.shown[10].at, "the move is the zoom's first frame's moment")
        // Smooth over Wi-Fi.
        var smoother = FrameSmoother()
        let wifi = Self.wifi(seconds: 1)
        let smooth = play(zoomInAndOut { index, now in
            now + Int64((smoother.hold(arrivedAfter: wifi[index].delay, now: now) * 1000).rounded())
        })
        expectInOrderAndInPlace(smooth, "Smooth")
        // The lowest delay: the frame that moves the layer is timed a refresh ahead, and frames that come meanwhile
        // wait behind it.
        let lowest = play(zoomInAndOut { _, _ in nil })
        expectInOrderAndInPlace(lowest, "lowest delay")
        let slowLead = play(zoomInAndOut { _, _ in nil }, lead: 20_000)
        expectInOrderAndInPlace(slowLead, "lowest delay, a lead longer than a frame")
        #expect(slowLead.drained == 2, "the frame after each move waits behind it")
        #expect(slowLead.flushes == 0)
    }

    @Test func turningSmoothOffKeepsTheOrder() {
        // Smooth on for 30 frames (each held up to 15 ms), then off: the frames still waiting go first, none dropped.
        var smoother = FrameSmoother()
        let wifi = Self.wifi(seconds: 1)
        let played = play(zoomInAndOut { index, now in
            index < 30 ? now + Int64((smoother.hold(arrivedAfter: wifi[index].delay, now: now) * 1000).rounded()) : nil
        })
        expectInOrderAndInPlace(played, "Smooth turned off")
        #expect(played.flushes == 0 && played.shown.count == 60, "nothing dropped")
        // Lip-sync turned off with 150 ms still waiting: those frames go (step 2's flush), the rest keep their order and
        // place, the move that was waiting included.
        let lipSync = play(zoomInAndOut { index, now in index < 12 ? now + 150_000 : nil })
        expectInOrderAndInPlace(lipSync, "lip-sync turned off")
        #expect(lipSync.flushes == 1)
        #expect(lipSync.shown.first { $0.region != nil }?.index == 12, "the zoom's first frames waiting were let go")
    }

    @Test func aFlushedRendererStartsOver() {
        var schedule = SurfaceSchedule()
        _ = schedule.step(region: nil, presentationTime: 1_100_000, now: 1_000_000, lead: 8_333)
        _ = schedule.step(region: Self.part, presentationTime: 1_120_000, now: 1_016_000, lead: 8_333)
        #expect(schedule.region(at: 1_130_000) == Self.part)
        // The app went to the background: nothing waits, and the layer stays where it is.
        schedule.flushed(now: 1_050_000)
        #expect(schedule.lastPresentation == nil && schedule.moves.isEmpty && schedule.current == nil)
        let next = schedule.step(region: Self.part, presentationTime: nil, now: 2_000_000, lead: 8_333)
        #expect(next.moves && next.show == 2_008_333, "the part's next frame moves the layer, a refresh ahead")
    }
}
