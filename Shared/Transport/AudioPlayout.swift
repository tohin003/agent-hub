import Foundation

/// The phone's sound over UDP put back in order, one 10 ms Opus frame at a time: which to decode, which to rebuild
/// from the next frame's in-band FEC, and which to conceal. A missing frame is waited for at most `hold` after a later
/// one arrives (a reordered packet, or a copy in the next bundle, still makes it), then rebuilt from its successor if
/// that's here (Opus decodes the successor's FEC copy, or conceals when it has none), else concealed. Long gaps aren't
/// concealed frame by frame: past `longestConcealment` the playout skips to the next frame it has, so a stall doesn't
/// turn into a run of made-up sound. Pure bookkeeping, driven by `add` and `expire`; time in µs.
///
/// Each step carries the capture time of the sound it gives (µs on the Mac's host clock, as the hub stamped it), for
/// the phone's buffer and the sync rule: a lost frame's is its successor's less a frame, a concealed one's follows its
/// predecessor's, nil when neither is known.
nonisolated public struct AudioPlayout: Sendable {
    public enum Step: Sendable, Equatable {
        case decode(Data, timestamp: UInt64)
        /// The frame before `next` is lost: decode `next`'s FEC (or conceal, if it has none).
        case recover(next: Data, timestamp: UInt64)
        case conceal(timestamp: UInt64?)
    }

    public var hold: Int64
    public var longestConcealment: Int

    /// The sequence number played next; nil before the first frame.
    public private(set) var next: UInt32?
    private var waiting: [UInt32: ReceivedAudioFrame] = [:]
    /// The newest frame given out: where a concealed one follows.
    private var lastGiven: (timestamp: UInt64, duration: UInt16)?
    /// When a frame after the missing one arrived, so the wait for the missing one is bounded.
    private var missingSince: Int64?
    public private(set) var stats = Stats()

    public struct Stats: Sendable, Equatable {
        public var decoded = 0
        public var recovered = 0
        public var concealed = 0
        /// Frames given up in a skip past a long gap.
        public var skipped = 0
        public var late = 0
    }

    public init(hold: Int64 = 20_000, longestConcealment: Int = 10) {
        self.hold = hold
        self.longestConcealment = longestConcealment
    }

    /// New frames (any order, copies included); answers what to play now, in order.
    public mutating func add(_ frames: [ReceivedAudioFrame], now: Int64) -> [Step] {
        for frame in frames {
            if let next, SerialNumber.isBefore(frame.sequence, next) {
                stats.late += 1
                continue
            }
            if next == nil { next = frame.sequence }
            if waiting[frame.sequence] == nil { waiting[frame.sequence] = frame }
        }
        return drain(now: now)
    }

    /// Time passed: a frame waited for long enough is rebuilt or concealed.
    public mutating func expire(now: Int64) -> [Step] {
        drain(now: now)
    }

    /// When `expire` next has something to do.
    public var nextDeadline: Int64? {
        missingSince.map { $0 + hold }
    }

    /// Drops everything waiting (playback starts over).
    public mutating func reset() {
        next = nil
        waiting.removeAll()
        missingSince = nil
        lastGiven = nil
    }

    private mutating func drain(now: Int64) -> [Step] {
        var steps: [Step] = []
        while let current = next, !waiting.isEmpty {
            if let frame = waiting.removeValue(forKey: current) {
                steps.append(.decode(frame.data, timestamp: frame.timestamp))
                lastGiven = (frame.timestamp, frame.duration)
                stats.decoded += 1
                next = current &+ 1
                missingSince = nil
                continue
            }
            // `current` is missing and something later is here.
            guard let earliest = waiting.keys.min(by: { SerialNumber.isBefore($0, $1) }) else { break }
            let gap = Int(SerialNumber.distance(from: current, to: earliest))
            if gap > longestConcealment {
                stats.skipped += gap
                next = earliest
                missingSince = nil
                continue
            }
            let since = missingSince ?? now
            missingSince = since
            guard now - since >= hold else { break }
            if let successor = waiting[current &+ 1] {
                let timestamp = successor.timestamp &- UInt64(successor.duration)
                steps.append(.recover(next: successor.data, timestamp: timestamp))
                lastGiven = (timestamp, successor.duration)
                stats.recovered += 1
            } else {
                let timestamp = lastGiven.map { $0.timestamp &+ UInt64($0.duration) }
                steps.append(.conceal(timestamp: timestamp))
                if let timestamp, let duration = lastGiven?.duration { lastGiven = (timestamp, duration) }
                stats.concealed += 1
            }
            // The frames after it are already here, so the rest of the gap won't come either: no new wait.
            next = current &+ 1
        }
        if waiting.isEmpty { missingSince = nil }
        return steps
    }
}
