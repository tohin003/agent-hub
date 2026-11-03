import AppKit

/// How many frames a second a display's video stream captures, from the bitrate the link carries (the lowest of the
/// phones' delay-based UDP targets and the WebSocket backlog's steps) and how much of the screen moves. The frame rate
/// gives way before the resolution does, so text stays sharp when the link is slow:
/// - 12 Mbit/s and up: the most the stream runs at (the display's refresh rate: 120 on ProMotion);
/// - 6 to 12: 60;
/// - 3 to 6: 45, or 30 while the picture is busy;
/// - under 3: 30, or 20 while the picture is busy.
///
/// "Busy" is the encoder using most of the bitrate (much of the screen moving). Each boundary has a 10% band, a higher
/// rate waits 2 s to be sure and a lower one 0.5 s, so the rate doesn't flap on a link that wavers.
struct FrameRatePolicy {
    struct Tier {
        /// The lowest bitrate (bits/s) of the tier.
        let floor: Int
        let calm: Int
        let busy: Int
    }

    static let tiers = [
        Tier(floor: 12_000_000, calm: .max, busy: .max),
        Tier(floor: 6_000_000, calm: 60, busy: 60),
        Tier(floor: 3_000_000, calm: 45, busy: 30),
        Tier(floor: 0, calm: 30, busy: 20),
    ]
    static let band = 0.10
    static let raiseAfter: Duration = .seconds(2)
    static let lowerAfter: Duration = .milliseconds(500)
    /// Busy once the encoder uses more than this share of the bitrate over a second; calm again under `calmBelow`.
    static let busyAbove = 0.6
    static let calmBelow = 0.4

    /// The most the stream runs at.
    let maximum: Int
    private(set) var rate: Int
    private(set) var busy = false
    private var tier = 0
    private var pending: (rate: Int, since: ContinuousClock.Instant)?

    init(maximum: Int) {
        self.maximum = max(1, maximum)
        rate = self.maximum
    }

    /// The rate for now. `bitrate`: what the stream may send (bits/s); `used`: the share of it the encoder used over the
    /// last second.
    mutating func update(bitrate: Int, used: Double, now: ContinuousClock.Instant) -> Int {
        tier = Self.tier(for: bitrate, current: tier)
        if busy, used < Self.calmBelow { busy = false } else if !busy, used > Self.busyAbove { busy = true }
        let wanted = min(maximum, busy ? Self.tiers[tier].busy : Self.tiers[tier].calm)
        guard wanted != rate else {
            pending = nil
            return rate
        }
        if let pending, pending.rate == wanted {
            if now - pending.since >= (wanted > rate ? Self.raiseAfter : Self.lowerAfter) {
                rate = wanted
                self.pending = nil
            }
        } else {
            pending = (wanted, now)
        }
        return rate
    }

    /// The tier for a bitrate, given the one it's in: a higher tier takes 10% more than its floor, and the current one
    /// is left for a lower one only 10% under its own floor.
    static func tier(for bitrate: Int, current: Int) -> Int {
        let rate = Double(bitrate)
        let plain = tiers.firstIndex { bitrate >= $0.floor } ?? tiers.count - 1
        if plain < current {
            let up = tiers.firstIndex { rate >= Double($0.floor) * (1 + band) } ?? current
            return min(up, current)
        }
        if plain > current, rate < Double(tiers[current].floor) * (1 - band) { return plain }
        return current
    }

    /// The most a display's video runs at: its highest refresh rate (`NSScreen.maximumFramesPerSecond`, 120 on a
    /// ProMotion display), within 30...120; 60 when the display doesn't say.
    static func displayMaximum(reported: Int) -> Int {
        reported > 0 ? min(max(reported, 30), 120) : 60
    }

    /// The highest refresh rate of the display with this id, as macOS reports it (0 when it isn't connected).
    @MainActor
    static func reportedMaximum(of displayID: CGDirectDisplayID) -> Int {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }?
            .maximumFramesPerSecond ?? 0
    }
}

/// When a still screen gets a refinement. After motion the encoder may have spent less on a frame than its detail
/// needed (on a slow link most of all), and ScreenCaptureKit sends nothing more once the screen is still. So the hub
/// encodes the unchanged picture again a few times: ordinary frames that refer to the one before, never keyframes.
///
/// Measured on this Mac's encoder (HEVC 4:4:4, low-latency rate control): after a big change it starves the next
/// frames, then spends freely, and how long it waits between them hardly matters. A frame of a still text screen went
/// 34.7 → 35.1 → 37.5 → 40.9 → 44.2 dB over five passes at 1.5 Mbit/s, and 45.4 → 49.1 dB at 3. So there are five
/// passes: the first 150 ms after the last change, each next one 100 ms after the last, and none before the link has
/// carried the frames already sent (a pass queued behind them would only be skipped): well within a second at
/// 1.5 Mbit/s. On a slow link (under 6 Mbit/s) any motion whose frames used half their share of the bitrate or more
/// gets them; on a fast link only frames that used nearly all of it, as the picture is sharp already otherwise (and
/// there the passes come out at a kilobyte or two).
///
/// A small change during the passes (a blinking cursor right after a scroll) puts them off without starting them over,
/// so they still refine what the scroll left and still stop at five; a frame that fills half its share or more is new
/// motion and gets five again. While the screen keeps changing a little (a spinner), there are no passes: its frames
/// refine the picture themselves.
struct RefinementTrigger {
    static let passes = 5
    static let firstPass: Duration = .milliseconds(150)
    static let gap: Duration = .milliseconds(100)
    static let slowLink = 6_000_000
    static let slowFill = 0.5
    static let fastFill = 0.9

    private var lastChange: ContinuousClock.Instant?
    private var lastPass: ContinuousClock.Instant?
    /// When the link will have carried every frame so far, at the bitrate.
    private var linkFree: ContinuousClock.Instant?
    /// The fullest frame of the motion: its bytes over its share of the bitrate.
    private(set) var fullest = 0.0
    /// Passes made (or passed over) for the motion.
    private(set) var done = 0

    /// The screen changed (a frame was captured): the next pass waits for it. Once the last motion's passes are over (or
    /// it needed none), that begins new motion.
    mutating func changed(at now: ContinuousClock.Instant) {
        if done >= Self.passes {
            fullest = 0
            done = 0
        }
        lastChange = now
        lastPass = nil
    }

    /// A frame came out of the encoder. Each keeps the link busy for its bytes' time at the bitrate; a captured one (not
    /// a pass) also counts towards whether to refine, against its share of the bitrate.
    mutating func encoded(bytes: Int, pass: Bool, at now: ContinuousClock.Instant, bitrate: Int, frameInterval: Double) {
        if bitrate > 0 { linkFree = max(linkFree ?? now, now) + .seconds(Double(bytes * 8) / Double(bitrate)) }
        let share = Double(bitrate) / 8 * frameInterval
        guard !pass, share > 0 else { return }
        let fill = Double(bytes) / share
        fullest = max(fullest, fill)
        if fill >= Self.slowFill { done = 0 }
    }

    /// When the next pass is due, if one is.
    func nextPass() -> ContinuousClock.Instant? {
        guard let lastChange, done < Self.passes else { return nil }
        let due = lastPass.map { $0 + Self.gap } ?? lastChange + Self.firstPass
        return max(due, linkFree ?? due)
    }

    /// Whether to make the due pass now, counting it. False when none is due, or the motion's frames had room enough.
    mutating func refineNow(at now: ContinuousClock.Instant, bitrate: Int) -> Bool {
        guard let due = nextPass(), now >= due else { return false }
        guard fullest >= (bitrate < Self.slowLink ? Self.slowFill : Self.fastFill) else {
            done = Self.passes
            return false
        }
        done += 1
        lastPass = now
        return true
    }
}
