import Foundation

/// The phone's resend requests for missing picture pieces, by sequence number. A gap is asked about after a short
/// wait (packets reordered by a few milliseconds aren't lost), each request goes out twice a few milliseconds apart (a
/// lost request would cost a whole round trip), and a piece still missing a round trip later is asked for again, a few
/// times at most and never past its frame's deadline.
nonisolated public struct NackGenerator: Sendable {
    nonisolated public struct Settings: Sendable {
        /// µs to wait after a gap before asking.
        public var reorderWait: Int64 = 3_000
        /// Copies of each request, `copySpacing` µs apart.
        public var copies = 2
        public var copySpacing: Int64 = 4_000
        /// Ask again after the round trip × `retryFactor` + `retryExtra` µs.
        public var retryFactor = 1.25
        public var retryExtra: Int64 = 5_000
        /// Rounds of asking before giving up on a piece.
        public var maxRounds = 4
        /// A bigger gap is an outage: its frames are given up and refreshed instead.
        public var maxGap: Int64 = 2_000
        public var maxTracked = 4_000

        public init() {}
    }

    nonisolated public struct Stats: Sendable, Equatable {
        /// Sequence numbers put in requests (each copy counts).
        public var requested = 0
        /// Pieces given up after every round.
        public var gaveUp = 0
    }

    nonisolated private struct Entry: Sendable {
        var deadline: Int64
        var nextSend: Int64
        var round = 0
        var copiesSent = 0
    }

    public var settings: Settings
    public private(set) var stats = Stats()
    /// The newest sequence number received or known to have been sent.
    public private(set) var highest: UInt32?
    private var missing: [UInt32: Entry] = [:]

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var missingCount: Int { missing.count }

    public func isMissing(_ sequence: UInt32) -> Bool { missing[sequence] != nil }

    /// A piece arrived: sent, resent or rebuilt from parity. `deadline` is how long a gap it reveals is worth asking
    /// about; `wait` how long to give it first (default: the reorder wait; longer when the frame's parity, which comes
    /// after its pieces, may still rebuild it).
    public mutating func received(_ sequence: UInt32, now: Int64, deadline: Int64, wait: Int64? = nil) {
        guard let highest else {
            self.highest = sequence
            return
        }
        if SerialNumber.isBefore(highest, sequence) {
            addGap(from: highest &+ 1, to: sequence, now: now, wait: max(wait ?? settings.reorderWait, settings.reorderWait),
                   deadline: deadline)
            self.highest = sequence
        } else {
            missing[sequence] = nil
        }
    }

    /// The hub has sent pieces up to `sequence` (a frame's last piece once the rest of it stopped coming, or the
    /// hub's report): any not here yet are missing, to be asked for after `wait`.
    public mutating func expect(through sequence: UInt32, now: Int64, wait: Int64, deadline: Int64) {
        guard let highest, SerialNumber.isBefore(highest, sequence) else { return }
        addGap(from: highest &+ 1, to: sequence &+ 1, now: now, wait: wait, deadline: deadline)
        self.highest = sequence
    }

    /// Stops asking for pieces up to `sequence`: their frames were shown or given up.
    public mutating func forget(through sequence: UInt32) {
        guard !missing.isEmpty else { return }
        missing = missing.filter { SerialNumber.isBefore(sequence, $0.key) }
    }

    /// The pieces to ask for now, oldest first.
    public mutating func due(now: Int64, roundTrip: Int64) -> [UInt32] {
        var due: [UInt32] = []
        for (sequence, var entry) in missing {
            if now >= entry.deadline {
                missing[sequence] = nil
                stats.gaveUp += 1
                continue
            }
            guard now >= entry.nextSend else { continue }
            due.append(sequence)
            entry.copiesSent += 1
            if entry.copiesSent < settings.copies {
                entry.nextSend = now + settings.copySpacing
            } else {
                entry.round += 1
                entry.copiesSent = 0
                guard entry.round < settings.maxRounds else {
                    missing[sequence] = nil
                    stats.gaveUp += 1
                    continue
                }
                let retry = Int64(Double(roundTrip) * settings.retryFactor) + settings.retryExtra
                entry.nextSend = now + max(retry - settings.copySpacing * Int64(settings.copies - 1), settings.copySpacing)
            }
            missing[sequence] = entry
        }
        stats.requested += due.count
        return TransportNack.normalized(due)
    }

    /// When `due` next has something to do.
    public var nextWakeup: Int64? { missing.values.lazy.map { min($0.nextSend, $0.deadline) }.min() }

    private mutating func addGap(from first: UInt32, to end: UInt32, now: Int64, wait: Int64, deadline: Int64) {
        let count = SerialNumber.distance(from: first, to: end)
        guard count > 0 else { return }
        guard count <= settings.maxGap else {
            missing.removeAll()
            return
        }
        var sequence = first
        while sequence != end {
            if missing[sequence] == nil { missing[sequence] = Entry(deadline: deadline, nextSend: now + wait) }
            sequence &+= 1
        }
        if missing.count > settings.maxTracked, let highest = Optional(end &- 1) {
            missing = missing.filter { SerialNumber.distance(from: $0.key, to: highest) < Int64(settings.maxTracked) }
        }
    }
}

/// The hub's copies of the picture pieces it sent, for resends: each piece is resent at most once per ¾ round trip
/// (both copies of a request arrive within a few ms), a few times at most, and never after its frame's deadline. Kept
/// for a second or 4 MB.
nonisolated public struct RetransmitBuffer: Sendable {
    nonisolated public struct Settings: Sendable {
        public var maxAge: Int64 = 1_000_000
        public var maxBytes = 4 << 20
        public var minResendSpacing = 0.75
        public var maxResends = 4

        public init() {}
    }

    nonisolated private struct Entry: Sendable {
        var fragment: VideoFragment
        var firstSent: Int64
        var lastSent: Int64
        var deadline: Int64
        var resends = 0
    }

    public var settings: Settings
    public private(set) var bytes = 0
    private var entries: [UInt32: Entry] = [:]
    private var order: [UInt32] = []
    private var head = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var count: Int { entries.count }

    /// Keeps a piece just sent for the first time; `deadline` is when its frame stops being worth resending.
    public mutating func store(_ fragment: VideoFragment, sentAt: Int64, deadline: Int64) {
        guard entries[fragment.sequence] == nil else { return }
        entries[fragment.sequence] = Entry(fragment: fragment, firstSent: sentAt, lastSent: sentAt, deadline: deadline)
        order.append(fragment.sequence)
        bytes += fragment.payload.count
        evict(now: sentAt)
    }

    /// The pieces to resend for a request, marked as resends, with their frames' deadlines.
    public mutating func resends(for sequences: [UInt32], now: Int64, roundTrip: Int64)
        -> [(fragment: VideoFragment, deadline: Int64)] {
        let spacing = max(Int64(Double(roundTrip) * settings.minResendSpacing), 2_000)
        var resends: [(fragment: VideoFragment, deadline: Int64)] = []
        for sequence in sequences {
            guard var entry = entries[sequence], now < entry.deadline, now - entry.lastSent >= spacing,
                  entry.resends < settings.maxResends else { continue }
            entry.lastSent = now
            entry.resends += 1
            entries[sequence] = entry
            var copy = entry.fragment
            copy.flags.insert(.retransmission)
            resends.append((copy, entry.deadline))
        }
        return resends
    }

    /// Drops pieces older than `maxAge`, and the oldest while over `maxBytes`.
    public mutating func evict(now: Int64) {
        while head < order.count {
            let sequence = order[head]
            guard let entry = entries[sequence] else {
                head += 1
                continue
            }
            guard now - entry.firstSent > settings.maxAge || bytes > settings.maxBytes else { break }
            entries[sequence] = nil
            bytes -= entry.fragment.payload.count
            head += 1
        }
        if head > 4096 {
            order.removeFirst(head)
            head = 0
        }
    }
}
