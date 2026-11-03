import Foundation

/// Who gets which frame of one video stream, when to ask the encoder for a refresh or a keyframe, and how fast to
/// encode, for the phones sharing that stream. Pure bookkeeping: `ScreenService` feeds it the frames, each phone's
/// backlog and feedback, and acts on what it answers.
///
/// - A phone gets a frame only while the bytes already on their way to it fit in about 35 ms of the bitrate (at least
///   16 KB). A frame that doesn't fit is skipped, and that phone gets nothing more until a frame marked `refresh`.
/// - A refresh is asked for once the phone has room again and the encoder holds a frame every phone acknowledged (or
///   after half a second without one, when the refresh is a keyframe). A new phone waits for a keyframe.
/// - While every phone waits, nothing needs encoding (`holding`), which also keeps the acknowledged frame in the
///   encoder: HEVC's low-latency encoder lets an unacknowledged one go after about 12 frames.
/// - A skip cuts the bitrate by 30% (not below 0.5 Mbit/s); every 2 s without one raises it by 10%, up to the bitrate
///   asked for.
/// - A phone whose frames go over UDP is paced by its own transport instead (`admit(_:to:now:send:)`): the transport
///   takes or refuses each frame, and its congestion control sets that phone's bitrate, so a refusal is a skip without
///   the cut.
struct VideoPacing {
    enum Waiting: Equatable {
        case none
        /// Lost its place (a skipped frame, or it said so): a frame marked `refresh` picks it up.
        case refresh
        /// Has nothing to refer to (new, or its refresh didn't take): only a keyframe will do.
        case keyframe
    }

    enum Request: Equatable {
        case keyframe, refresh
    }

    /// What decides who gets a frame.
    struct Frame: Equatable {
        var flags: VideoFrameMessage.Flags
        var sequence: UInt32
        var ltrToken: UInt32
    }

    static let lowestBitrate = 500_000
    static let backlogSeconds = 0.035
    static let smallestBacklog = 16 * 1024
    static let cut = 0.7
    static let raise = 1.1
    static let calm: Duration = .seconds(2)
    /// How long a phone waiting for a refresh waits for an acknowledged frame before taking a keyframe.
    static let acknowledgementWait: Duration = .milliseconds(500)
    /// How long a refresh may take to reach a phone and show in its feedback before it counts as not having worked.
    static let refreshGrace: Duration = .milliseconds(500)
    /// Over UDP, how long past its delivery time a keyframe to a phone that has shown nothing is still waited for.
    static let arrivalSlack: Duration = .milliseconds(100)
    /// A request the encoder hasn't answered in this long is asked again.
    static let reask: Duration = .seconds(1)
    static let rememberedTokens = 256

    private struct Viewer {
        var waiting: Waiting = .keyframe
        var since: ContinuousClock.Instant
        /// The newest refresh or keyframe it was sent, when, how long it may take to show in the phone's feedback, and
        /// (over UDP) how long it takes just to arrive.
        var lastRefresh: (sequence: UInt32, at: ContinuousClock.Instant, grace: Duration, inFlight: Duration?)?
        var sent = 0
        var skipped = 0
        /// What the phone says it receives, in bits per second (smoothed).
        var received: Double?
        /// The phone's running count of frames its UDP transport gave up, and what it was when the newest refresh went.
        var lost = 0
        var lostAtRefresh = 0

        /// Over UDP, the newest keyframe (or refresh) is still within its delivery time: a phone that has shown
        /// nothing yet is waiting for it, and asking again in every feedback until it lands would send one keyframe
        /// after another.
        func keyframeOnItsWay(now: ContinuousClock.Instant) -> Bool {
            guard let last = lastRefresh, let inFlight = last.inFlight else { return false }
            return now - last.at < inFlight + VideoPacing.arrivalSlack
        }
    }

    private(set) var bitrate: Int
    private(set) var target: Int
    private var viewers: [UUID: Viewer] = [:]
    /// Tokens of the frames since the last keyframe (only those can still be referred to), oldest first.
    private var tokens: [UInt32] = []
    private var tokenSet: Set<UInt32> = []
    /// Tokens some phones acknowledged, waiting for the rest.
    private var acknowledgements: [UInt32: Set<UUID>] = [:]
    /// Every phone acknowledged a frame since the last keyframe, and the encoder was told.
    private(set) var referenceAcknowledged = false
    private var asked: (request: Request, at: ContinuousClock.Instant)?
    private var lastCut: ContinuousClock.Instant?
    private var lastRaise: ContinuousClock.Instant
    private var bitrateChanged = false

    /// For a stream about to start: its first frame is a keyframe, as good as asked for.
    init(target: Int, now: ContinuousClock.Instant) {
        self.target = max(target, Self.lowestBitrate)
        bitrate = self.target
        lastRaise = now
        asked = (.keyframe, now)
    }

    /// A default bitrate for a size and frame rate: 0.05 bits per pixel per frame, which gives text room to stay sharp
    /// while the screen moves (7.2 Mbit/s at 1920×1248 and 60 fps).
    static func defaultBitrate(width: Int, height: Int, fps: Int) -> Int {
        max(lowestBitrate, Int(Double(width * height * max(fps, 1)) * 0.05))
    }

    /// What the encoder runs at: the lowest of this stream's own bitrate (`bitrate`) and the targets of the UDP sessions
    /// watching it; frame rate capped by the slowest path's profile (nil: no cap).
    static func encoderSettings(bitrate: Int, targets: [EncoderTarget]) -> (bitrate: Int, frameRateCap: Int?) {
        (min(bitrate, targets.map(\.videoBitrate).min() ?? .max), targets.map(\.maxFramesPerSecond).min())
    }

    /// The bytes that may already be on their way to a phone for it to get another frame.
    var cap: Int {
        max(Self.smallestBacklog, Int(Double(bitrate) / 8 * Self.backlogSeconds))
    }

    /// The stream is starting a new encoder, whose first frame is a keyframe.
    mutating func restarting(now: ContinuousClock.Instant) {
        asked = (.keyframe, now)
    }

    /// The stream (re)started at this bitrate, which is also the one asked for.
    mutating func start(at bitrate: Int, now: ContinuousClock.Instant) {
        target = max(bitrate, Self.lowestBitrate)
        self.bitrate = target
        lastCut = nil
        lastRaise = now
        bitrateChanged = false
    }

    /// The bitrate asked for (the newest phone's); the current one comes down to it at once, or rises to it in steps.
    mutating func setTarget(_ newTarget: Int) {
        target = max(newTarget, Self.lowestBitrate)
        if bitrate > target {
            bitrate = target
            bitrateChanged = true
        }
    }

    // MARK: Phones

    /// A phone starts watching: it waits for a keyframe.
    mutating func join(_ id: UUID, now: ContinuousClock.Instant) {
        viewers[id] = Viewer(since: now)
    }

    /// A phone stops watching. Answers the tokens that the phones left have now all acknowledged, for the encoder (HEVC
    /// marks no new frame for acknowledgement until the last one is).
    mutating func leave(_ id: UUID) -> [UInt32] {
        viewers[id] = nil
        let needed = Set(viewers.filter { $0.value.waiting != .keyframe }.keys)
        var acknowledged: [UInt32] = []
        for token in tokens {
            guard var phones = acknowledgements[token] else { continue }
            phones.remove(id)
            if !needed.isEmpty, needed.isSubset(of: phones) {
                acknowledgements[token] = nil
                acknowledged.append(token)
                referenceAcknowledged = true
            } else {
                acknowledgements[token] = phones
            }
        }
        return acknowledged
    }

    func waiting(_ id: UUID) -> Waiting? {
        viewers[id]?.waiting
    }

    /// Every phone waits for a refresh or a keyframe: frames encoded now would go to nobody (and would push the
    /// acknowledged frame out of the encoder), so only the one asked for needs encoding.
    var holding: Bool {
        !viewers.isEmpty && viewers.values.allSatisfy { $0.waiting != .none }
    }

    /// Frames sent and skipped since the last call, and what the phones say they receive (bits per second), for the
    /// log.
    mutating func takeCounts() -> (sent: Int, skipped: Int, received: Double?) {
        var sent = 0, skipped = 0
        var received: Double?
        for id in viewers.keys {
            sent += viewers[id]?.sent ?? 0
            skipped += viewers[id]?.skipped ?? 0
            if let rate = viewers[id]?.received { received = (received ?? 0) + rate }
            viewers[id]?.sent = 0
            viewers[id]?.skipped = 0
        }
        return (sent, skipped, received)
    }

    // MARK: Frames

    /// The encoder made a frame (call before offering it to anyone).
    mutating func produced(_ frame: Frame) {
        if frame.flags.contains(.keyframe) {
            // Nothing before a keyframe can be referred to after it.
            tokens.removeAll()
            tokenSet.removeAll()
            acknowledgements.removeAll()
            referenceAcknowledged = false
            asked = nil
        } else if frame.flags.contains(.refresh), asked?.request == .refresh {
            asked = nil
        }
        guard frame.ltrToken != 0 else { return }
        tokens.append(frame.ltrToken)
        tokenSet.insert(frame.ltrToken)
        if tokens.count > Self.rememberedTokens {
            let old = tokens.removeFirst()
            tokenSet.remove(old)
            acknowledgements[old] = nil
        }
    }

    /// Whether this frame goes to this phone, given the bytes on their way to it (and how many of those are a keyframe).
    mutating func admit(_ frame: Frame, to id: UUID, backlog: Int, keyframeBacklog: Int,
                        now: ContinuousClock.Instant) -> Bool {
        guard var viewer = viewers[id] else { return false }
        defer { viewers[id] = viewer }
        let fits = backlog <= cap
        switch viewer.waiting {
        case .keyframe, .refresh:
            let usable = viewer.waiting == .keyframe ? frame.flags.contains(.keyframe) : frame.flags.contains(.refresh)
            guard usable, fits else { return false }
            viewer.waiting = .none
            viewer.lastRefresh = (frame.sequence, now, Self.refreshGrace, nil)
            viewer.lostAtRefresh = viewer.lost
            viewer.sent += 1
            return true
        case .none:
            if fits {
                if frame.flags.contains(.refresh) {
                    viewer.lastRefresh = (frame.sequence, now, Self.refreshGrace, nil)
                    viewer.lostAtRefresh = viewer.lost
                }
                viewer.sent += 1
                return true
            }
            viewer.waiting = .refresh
            viewer.since = now
            viewer.skipped += 1
            // A keyframe still going out makes the next frames wait; that's its size, not a slow link.
            if backlog - keyframeBacklog > cap {
                bitrate = max(Self.lowestBitrate, min(bitrate, Int(Double(bitrate) * Self.cut)))
                lastCut = now
                bitrateChanged = true
            }
            return false
        }
    }

    /// Whether this frame goes to a phone whose own transport queues and paces it (UDP): it must be one the phone can
    /// use (a keyframe or refresh frame while it waits for one), and `send` must be taken. A refusal is a skip: the
    /// phone waits for a refresh, and the transport has already cut its own target. `delivery`: how long this frame
    /// takes to reach the phone and be heard of (a keyframe on a slow path, seconds), added to the refresh grace.
    mutating func admit(_ frame: Frame, to id: UUID, now: ContinuousClock.Instant, delivery: Duration = .zero,
                        send: () -> Bool) -> Bool {
        guard var viewer = viewers[id] else { return false }
        defer { viewers[id] = viewer }
        let grace = Self.refreshGrace + delivery
        switch viewer.waiting {
        case .keyframe, .refresh:
            let usable = viewer.waiting == .keyframe ? frame.flags.contains(.keyframe) : frame.flags.contains(.refresh)
            guard usable, send() else { return false }
            viewer.waiting = .none
            viewer.lastRefresh = (frame.sequence, now, grace, delivery)
            viewer.lostAtRefresh = viewer.lost
            viewer.sent += 1
            return true
        case .none:
            if send() {
                if frame.flags.contains(.refresh) {
                    viewer.lastRefresh = (frame.sequence, now, grace, delivery)
                    viewer.lostAtRefresh = viewer.lost
                }
                viewer.sent += 1
                return true
            }
            viewer.waiting = .refresh
            viewer.since = now
            viewer.skipped += 1
            return false
        }
    }

    /// A phone's frames start going another way (UDP came up, or it fell back to the WebSocket). What the old way still
    /// carries may arrive after the new way's first frame, so it starts again from a refresh frame.
    mutating func resume(_ id: UUID, now: ContinuousClock.Instant) {
        guard var viewer = viewers[id], viewer.waiting == .none else { return }
        viewer.waiting = .refresh
        viewer.since = now
        viewers[id] = viewer
    }

    // MARK: Feedback and requests

    /// A phone's feedback. Answers the tokens every phone has now acknowledged, for the encoder.
    mutating func feedback(_ feedback: ScreenFeedback, from id: UUID, now: ContinuousClock.Instant) -> [UInt32] {
        guard var viewer = viewers[id] else { return [] }
        if let lost = feedback.lost, lost > viewer.lost { viewer.lost = lost }
        if let bytes = feedback.receivedBytes, let milliseconds = feedback.intervalMs, milliseconds > 0 {
            let rate = Double(bytes) * 8 / (milliseconds / 1000)
            viewer.received = viewer.received.map { $0 * 0.9 + rate * 0.1 } ?? rate
        }
        var acknowledged: [UInt32] = []
        if viewer.waiting != .keyframe {
            // The phones that refreshes must work for: all but those starting at a keyframe.
            let needed = Set(viewers.filter { $0.value.waiting != .keyframe }.keys)
            for token in feedback.ltrTokens where tokenSet.contains(token) {
                var phones = acknowledgements[token, default: []]
                phones.insert(id)
                if needed.isSubset(of: phones) {
                    acknowledgements[token] = nil
                    acknowledged.append(token)
                    referenceAcknowledged = true
                } else {
                    acknowledgements[token] = phones
                }
            }
        }
        if feedback.refresh, viewer.waiting == .none {
            if let decoded = feedback.sequence {
                if let last = viewer.lastRefresh, last.sequence > decoded {
                    if viewer.lost > viewer.lostAtRefresh {
                        // Frames were given up since that refresh went, maybe the refresh itself (a hiccup on the
                        // way): another refresh, now, which is small, rather than a keyframe after the grace.
                        viewer.waiting = .refresh
                        viewer.since = now
                    } else if now - last.at >= last.grace {
                        // A refresh is on its way; if it should have shown by now, it didn't work: start over.
                        viewer.waiting = .keyframe
                        viewer.since = now
                    }
                } else {
                    viewer.waiting = .refresh
                    viewer.since = now
                }
            } else if !viewer.keyframeOnItsWay(now: now) {
                // Nothing decoded: its decoder has nothing to refer to.
                viewer.waiting = .keyframe
                viewer.since = now
            }
        } else if feedback.refresh, viewer.waiting == .refresh, feedback.sequence == nil, !viewer.keyframeOnItsWay(now: now) {
            // Waiting for a refresh (a frame was refused) but it has shown nothing: only a keyframe will do, and a
            // refresh would first wait for an acknowledged frame that can't come.
            viewer.waiting = .keyframe
        }
        viewers[id] = viewer
        return acknowledged
    }

    /// What to ask the encoder for now, if anything: one request at a time, until a frame answers it. A refresh waits
    /// until the phone's backlog fits the cap.
    mutating func nextRequest(now: ContinuousClock.Instant, backlog: (UUID) -> Int) -> Request? {
        let cap = self.cap
        return nextRequest(now: now, hasRoom: { backlog($0) <= cap })
    }

    /// The same, with each phone's own answer to whether it has room (a WebSocket's backlog against `cap`, a UDP
    /// session's congestion window and queue).
    mutating func nextRequest(now: ContinuousClock.Instant, hasRoom: (UUID) -> Bool) -> Request? {
        if let asked, now - asked.at < Self.reask { return nil }
        var request: Request?
        for (id, viewer) in viewers {
            switch viewer.waiting {
            case .keyframe:
                request = .keyframe
            case .refresh:
                // Asked for when it can take it, and when it can be small (or has waited long enough not to be).
                guard hasRoom(id),
                      referenceAcknowledged || now - viewer.since >= Self.acknowledgementWait else { continue }
                if request == nil { request = .refresh }
            case .none:
                continue
            }
        }
        if let request { asked = (request, now) }
        return request
    }

    /// The new bitrate, when it changed since the last call (a skip cut it, or 2 s went by without one).
    mutating func takeBitrateChange(now: ContinuousClock.Instant) -> Int? {
        let calmSince = max(lastCut ?? lastRaise, lastRaise)
        if bitrate < target, now - calmSince >= Self.calm {
            bitrate = min(target, max(bitrate + 1, Int(Double(bitrate) * Self.raise)))
            lastRaise = now
            bitrateChanged = true
        }
        guard bitrateChanged else { return nil }
        bitrateChanged = false
        return bitrate
    }
}
