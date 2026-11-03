import Foundation

/// Smooth (plan step 4): every frame shows at the same delay after the Mac captured it, so motion the Mac captured at an
/// even pace reaches the glass at an even pace, whatever the network did to the frames on the way. Off, frames show as
/// soon as they're decoded: the lowest delay.
///
/// The delay is the 99th percentile of how long frames took from their capture to decoded here, over the last 10 s: the
/// quickest a frame takes plus the jitter, about a refresh at home. A frame never shows before it arrives, and none is
/// held longer than evening out the slowest of those 99% needs; the rest (a stall) show late, as they would anyway.
/// Frames decoded in a bunch right behind a late one don't count: they were held up behind it, and only repeat its
/// delay (without that, one 60 ms stall raised the delay by 12 ms for the whole window).
/// The delay rises at once when a frame comes late (that frame's step is there anyway), else it moves gradually, up at
/// 20 ms a second and down at 4, so the pace stays even while it does: a third of a millisecond a frame at most.
nonisolated public struct FrameSmoother: Sendable {
    /// The frames the delay is taken from: those of the last 10 s.
    public static let window: Int64 = 10_000_000
    /// A late frame decoded this soon after a late one was held up behind it.
    public static let bunched: Int64 = 2_000
    /// The share of them the delay covers.
    public static let coverage = 0.99
    /// How fast the delay moves toward what the jitter asks, when no frame came late: ms a second.
    public static let risePerSecond = 20.0
    public static let fallPerSecond = 4.0

    private var arrivals: [(at: Int64, ms: Double)] = []
    private var updated: Int64?
    private var lastArrival: Int64?
    private var lastWasLate = false
    /// The delay frames show at after their capture, ms; nil before the first frame.
    public private(set) var delayMs: Double?

    public init() {}

    /// A frame arrived (`now`, µs on this phone's host clock) `delay` ms after its capture, on the Mac's clock as the
    /// phone tracks it: how long to hold it, ms, so it shows at the steady delay.
    public mutating func hold(arrivedAfter delay: Double, now: Int64) -> Double {
        let late = delayMs.map { delay > $0 } ?? false
        let heldUp = late && lastWasLate && lastArrival.map { now - $0 <= Self.bunched } == true
        lastArrival = now
        lastWasLate = late
        if !heldUp { arrivals.append((now, delay)) }
        if let first = arrivals.first, now - first.at > Self.window {
            arrivals.removeAll { now - $0.at > Self.window }
        }
        let wanted = Self.percentile(arrivals.map(\.ms), Self.coverage)
        if let current = delayMs, let updated {
            let seconds = Double(max(0, now - updated)) / 1e6
            if delay > current {
                // Late: it shows as it arrives, and the delay takes up at once what the jitter now asks.
                delayMs = max(current, wanted)
            } else if wanted > current {
                delayMs = min(wanted, current + Self.risePerSecond * seconds)
            } else {
                delayMs = max(wanted, current - Self.fallPerSecond * seconds)
            }
        } else {
            delayMs = wanted
        }
        updated = now
        return max(0, (delayMs ?? delay) - delay)
    }

    /// Forgets the frames so far: Smooth turned off, or the stream ended.
    public mutating func reset() {
        guard updated != nil else { return }
        arrivals.removeAll()
        updated = nil
        delayMs = nil
        lastArrival = nil
        lastWasLate = false
    }

    /// The value `share` of `values` are at or under.
    static func percentile(_ values: [Double], _ share: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * share).rounded(.up)))]
    }
}

/// When a decoded frame shows: at once (the lowest delay), at Smooth's steady delay after its capture, or held back
/// for lip-sync (`MediaSync`), whichever is latest, never two added up. Smooth's hold counts as part of the picture's
/// own delay, so lip-sync adds only what still keeps the sound from trailing too far, the readout's delay includes it,
/// and the sound's floor keeps the sound behind the smoothed picture.
nonisolated public enum PictureTiming {
    /// µs on this phone's host clock to show a frame at; nil for at once. `sinceCapture`: ms since the Mac captured it,
    /// through `MacClock` (nil while the Mac's clock isn't known); `displayLatencyMs`: from the layer to the glass.
    public static func presentationTime(sinceCapture: Double?, smooth: Bool, smoother: inout FrameSmoother, sync: MediaSync,
                                        displayLatencyMs: Double, now: Int64) -> Int64? {
        if !smooth { smoother.reset() }
        guard let sinceCapture else { return nil }
        let smoothing = smooth ? smoother.hold(arrivedAfter: sinceCapture, now: now) : 0
        sync.pictureShown(delayMs: sinceCapture + smoothing + displayLatencyMs, now: now)
        let hold = smoothing + sync.pictureHold(now: now)
        // Smooth keeps every frame on the clock, one due now too, so none jumps ahead of a frame still waiting.
        if smooth { return now + Int64((hold * 1000).rounded()) }
        guard hold >= 0.5 else { return nil }
        return now + Int64(hold * 1000)
    }
}

/// The order frames take on a display layer (`VideoSurfaceView`) and where on the picture the layer is when, apart
/// from the layer itself so it can be tested. A frame of part of the display (a zoomed-in phone's sharper capture)
/// moves the layer to that part's place, and the move happens when that frame shows, never when it's queued: frames of
/// the old part still waiting (Smooth, lip-sync) show in the old place, and the new part never shows stretched over it.
nonisolated public struct SurfaceSchedule: Sendable {
    /// Frames waiting less than this when one comes to show at once go first, in order, and none is dropped (Smooth
    /// turned off: a refresh or so). A longer wait (lip-sync turned off) is flushed rather than lag that far behind.
    public static let drainLimit: Int64 = 50_000

    public struct Step: Equatable, Sendable {
        /// When the frame shows: µs on the host clock; nil for at once.
        public var show: Int64?
        /// Drop the frames still waiting, first.
        public var flush: Bool
        /// The layer moves to the frame's part when it shows.
        public var moves: Bool
    }

    /// When the newest frame queued shows (µs, host clock); nil when it showed at once.
    public private(set) var lastPresentation: Int64?
    /// The part of the display the layer covers now (nil: all of it), and the moves still to come, in time order.
    public private(set) var current: ScreenRegion?
    public private(set) var moves: [(at: Int64, region: ScreenRegion?)] = []

    public init() {}

    /// The part the newest frame queued shows.
    public var newestRegion: ScreenRegion? { moves.isEmpty ? current : moves[moves.count - 1].region }

    /// A frame of `region` comes to the layer at `now`, to show at `presentationTime` (nil: at once). `lead`: how far
    /// ahead a frame that moves the layer is timed when it would show at once, so the move and the frame reach the
    /// screen together.
    public mutating func step(region: ScreenRegion?, presentationTime: Int64?, now: Int64, lead: Int64) -> Step {
        settle(now: now)
        var show: Int64?
        var flush = false
        if let presentationTime {
            // Never before the frame before it, so waiting frames keep their order as a hold shrinks.
            show = max(presentationTime, (lastPresentation ?? 0) + 1)
        } else if let last = lastPresentation, last > now {
            if last - now <= Self.drainLimit {
                show = last + 1
            } else {
                // They would show after this one, a step back: let them go. The layer stays with the frame on show.
                flush = true
                moves.removeAll()
            }
        }
        let moving = region != newestRegion
        if moving {
            let at = show ?? now + lead
            show = at
            moves.append((at, region))
        }
        lastPresentation = show
        return Step(show: show, flush: flush, moves: moving)
    }

    /// The renderer dropped what was waiting (the app went to the background, or decoding failed).
    public mutating func flushed(now: Int64) {
        settle(now: now)
        moves.removeAll()
        lastPresentation = nil
    }

    /// The part the layer covers at `time`.
    public func region(at time: Int64) -> ScreenRegion? {
        if let move = moves.last(where: { $0.at <= time }) { return move.region }
        return current
    }

    /// The moves whose moment has come become the current place.
    public mutating func settle(now: Int64) {
        while let first = moves.first, first.at <= now {
            current = first.region
            moves.removeFirst()
        }
    }
}
