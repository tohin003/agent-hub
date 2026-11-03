import Foundation

/// The phone's sound buffer, decided (plan step 2): how much sound to hold, and how fast to play to stay there.
///
/// - **How much:** enough for the arrivals' jitter, measured as the spread of `arrival − capture` over the last 10 s
///   (99th percentile less the minimum: Wi-Fi's spikes recur, and each one the buffer misses is a gap), plus a small
///   margin. Never less than the path's floor (20–40 ms at home,
///   more on relays and DERP, from the path profile), and never so little that the sound would be ahead of the picture
///   (`syncFloorMs`, from `MediaSync`). A stall's sound isn't jitter: it stays out of the measure, or the buffer would
///   hold that much more for seconds after every stall.
/// - **How fast:** the buffer is steered by playing 1–2% faster or slower (time-stretch), never by dropping sound or
///   adding silence. Only a stall (the buffer ran dry) waits to fill again, and fills from fresh sound: what the stall
///   held up arrives late, in a burst, and is skipped (`admit`). Beyond that, only sound far over the target is.
///
/// The level is the sound waiting when a frame arrives (before it joins), so a frame's delay is its arrival delay plus
/// the level plus the output's latency, which is what the sync rule counts on.
///
/// Pure bookkeeping; times in µs, levels in ms. `SoundOutput` drives it on the phone, the tests with a simulated clock.
nonisolated public struct PlayoutController: Sendable {
    public struct Settings: Sendable, Equatable {
        /// The least sound held: the path profile's buffer less 10 ms (20 ms direct, 40 ms peer relay, 90 ms DERP).
        public var floorMs: Double
        public var ceilingMs: Double = 300
        /// Held over the measured jitter.
        public var marginMs: Double = 8
        /// The rate stays within 1 ± this (2%: at most a third of a semitone, and only briefly).
        public var maxRateChange: Double = 0.02
        /// An error of `maxRateChange × 1000 × correctionSeconds` ms or more gets the full change.
        public var correctionSeconds: Double = 1.5
        /// Within this of the target, play at the normal rate.
        public var deadbandMs: Double = 2
        /// How fast the rate itself may change (per second), so it never warbles.
        public var slewPerSecond: Double = 0.02
        /// This far over the target, sound is skipped whatever the reason.
        public var excessMs: Double = 250
        /// A frame this much later than the quickest (or three times the jitter, if more) was held up by a stall.
        public var stallMs: Double = 100
        /// The window the jitter is measured over, and the share of arrivals it covers.
        public var jitterWindow: Int64 = 10_000_000
        public var jitterQuantile: Double = 0.99

        public init(floorMs: Double) {
            self.floorMs = floorMs
        }

        /// The floor for a path profile's sound buffer.
        public static func forPath(bufferMs: Double) -> Settings {
            Settings(floorMs: max(bufferMs - 10, 15))
        }
    }

    public struct Stats: Sendable, Equatable {
        /// Times the buffer ran dry while playing (each a gap of silence).
        public var underruns = 0
        /// Sound skipped to recover from a stall (or, far over the target, anything), in ms.
        public var skippedMs = 0.0
        /// Frames held up by a stall, kept out of the jitter.
        public var stalledFrames = 0
        public var lowestRate = 1.0
        public var highestRate = 1.0
    }

    public var settings: Settings
    /// Extra hold so the sound isn't ahead of the picture (`SyncRule.bufferFloor`), ms.
    public var syncFloorMs: Double = 0
    public private(set) var rate = 1.0
    public private(set) var jitterMs = 0.0
    public private(set) var stats = Stats()
    /// Playing (filled once to the target), as opposed to filling.
    public private(set) var playing = false

    private var transits: [(at: Int64, transit: Int64)] = []
    private var jitterMeasured: Int64?
    /// The quickest transit of each second over the last 30: what a frame's lateness is measured from.
    private var quickest: [(second: Int64, transit: Int64)] = []
    private var lastUpdate: Int64?

    public init(settings: Settings) {
        self.settings = settings
    }

    /// The level to hold, ms.
    public var targetMs: Double {
        let jitter = min(max(jitterMs + settings.marginMs, settings.floorMs), settings.ceilingMs)
        return max(jitter, min(syncFloorMs, settings.ceilingMs + settings.floorMs))
    }

    /// A frame arrived with `queuedMs` already waiting; whether to play it. `transit` is its arrival (phone µs) less its
    /// capture time (Mac µs), nil when unknown: the clocks' offset doesn't matter, only how much the transit varies.
    /// Every frame plays, except
    /// - while filling after a stall, one later than the target allows behind the quickest: the sound the stall held
    ///   up, arriving in a burst, which would start playing that far behind;
    /// - any, far over the target (`excessMs`).
    public mutating func admit(transit: Int64?, queuedMs: Double, frameMs: Double, now: Int64) -> Bool {
        if let transit {
            let lateness = quickestTransit.map { Double(transit - $0) / 1000 } ?? 0
            noteQuickest(transit, now: now)
            if lateness <= max(settings.stallMs, 3 * jitterMs) {
                measure(transit, now: now)
            } else {
                stats.stalledFrames += 1
            }
            if !playing, lateness > targetMs + settings.marginMs {
                stats.skippedMs += frameMs
                return false
            }
        }
        guard queuedMs > targetMs + settings.excessMs else { return true }
        stats.skippedMs += frameMs
        return false
    }

    /// Whether to start playing: once filled to the target (at first, and after running dry). `queuedMs` is what
    /// waits before the newest frame, as the level is measured.
    public mutating func shouldStart(queuedMs: Double) -> Bool {
        if !playing, queuedMs >= targetMs { playing = true }
        return playing
    }

    /// As playing starts with `queuedMs` filled: how much of the oldest to skip so it starts at the target (a sound
    /// buffer of several packets can overshoot it).
    public mutating func startExcess(queuedMs: Double) -> Double {
        let excess = queuedMs - targetMs
        guard excess > settings.marginMs else { return 0 }
        stats.skippedMs += excess
        return excess
    }

    /// The buffer ran dry while playing: a stall. It fills to the target again before playing on.
    public mutating func ranDry() {
        guard playing else { return }
        playing = false
        stats.underruns += 1
        rate = 1
    }

    /// The output started again (a new route, a call ended): fill to the target again. Not a stall.
    public mutating func refill() {
        playing = false
        rate = 1
    }

    /// The rate to play at now, from how much waits (call at every frame and on a timer). 1 while filling.
    public mutating func update(queuedMs: Double, now: Int64) -> Double {
        let elapsed = lastUpdate.map { Double(now - $0) / 1e6 } ?? 0
        lastUpdate = now
        guard playing else {
            rate = 1
            return rate
        }
        let error = queuedMs - targetMs
        var wanted = 1.0
        if abs(error) > settings.deadbandMs {
            let full = settings.maxRateChange * 1000 * settings.correctionSeconds
            wanted = 1 + settings.maxRateChange * max(-1, min(1, error / full))
        }
        let step = settings.slewPerSecond * max(elapsed, 0)
        rate = max(1 - settings.maxRateChange, min(1 + settings.maxRateChange, rate + max(-step, min(step, wanted - rate))))
        stats.lowestRate = min(stats.lowestRate, rate)
        stats.highestRate = max(stats.highestRate, rate)
        return rate
    }

    // MARK: Inside

    private var quickestTransit: Int64? { quickest.map(\.transit).min() }

    private mutating func noteQuickest(_ transit: Int64, now: Int64) {
        let second = now / 1_000_000
        if let last = quickest.last, last.second == second {
            if transit < last.transit { quickest[quickest.count - 1].transit = transit }
            return
        }
        quickest.append((second, transit))
        quickest.removeAll { second - $0.second >= 30 }
    }

    /// The spread is measured again every 50 ms (a sort of up to 1,000 transits), not at every frame.
    private mutating func measure(_ transit: Int64, now: Int64) {
        transits.append((now, transit))
        guard jitterMeasured.map({ now - $0 >= 50_000 }) ?? true else { return }
        jitterMeasured = now
        transits.removeAll { now - $0.at > settings.jitterWindow }
        let sorted = transits.map(\.transit).sorted()
        guard let lowest = sorted.first else { return }
        let high = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * settings.jitterQuantile).rounded()))]
        jitterMs = Double(high - lowest) / 1000
    }
}
