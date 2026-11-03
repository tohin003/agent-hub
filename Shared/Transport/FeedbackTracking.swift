import Foundation

/// The phone's side of the arrival reports: records when each of the hub's packets arrived and, every 20–50 ms, writes
/// them as `TransportFeedback` runs covering every packet number since the last report, so the hub sees losses too.
/// Arrival times keep 250 µs, quantized against the previous reported time so the error never accumulates. A gap of
/// more than 400 numbers (an outage) starts a new run instead of being reported number by number.
nonisolated public struct FeedbackBuilder: Sendable {
    public static let maxPacketsPerFeedback = 400

    private var pending: [(number: UInt64, arrival: Int64)] = []
    private var nextUnreported: UInt64?
    private var sequence: UInt16 = 0
    public private(set) var lastBuilt: Int64?

    public init() {}

    public var pendingCount: Int { pending.count }

    public mutating func record(number: UInt64, arrival: Int64) {
        // Already covered by a report, which called it lost: arriving this late, it changes nothing.
        if let nextUnreported, number < nextUnreported { return }
        pending.append((number, arrival))
    }

    public func isDue(now: Int64, interval: Int64) -> Bool {
        guard !pending.isEmpty else { return false }
        if pending.count >= Self.maxPacketsPerFeedback { return true }
        return lastBuilt.map { now - $0 >= interval } ?? true
    }

    /// When the next report is due, if anything waits to be reported.
    public func nextDue(interval: Int64) -> Int64? {
        guard !pending.isEmpty else { return nil }
        return lastBuilt.map { $0 + interval } ?? Int64.min
    }

    public mutating func build(now: Int64) -> [TransportFeedback] {
        guard !pending.isEmpty else { return [] }
        pending.sort { $0.number < $1.number }
        let limit = UInt64(Self.maxPacketsPerFeedback)
        var feedbacks: [TransportFeedback] = []
        var base = pending[0].number
        if let nextUnreported, base >= nextUnreported, base - nextUnreported < limit { base = nextUnreported }
        var arrivals: [Int64?] = []
        var reference: Int64?
        var previous: Int64 = 0
        var index = 0
        while index < pending.count {
            let packet = pending[index]
            let offset = packet.number - base
            if offset < UInt64(arrivals.count) {
                // The same number twice (the opener refuses replays, so this is only defensive).
                index += 1
                continue
            }
            let ticks: Double? = reference == nil ? nil
                : (Double(packet.arrival - previous) / Double(TransportFeedback.tick)).rounded()
            let tooFar = ticks.map { abs($0) > Double(Int16.max) } ?? false
            if offset >= limit || tooFar {
                // Close this run; the next one starts right after it, or at this packet after a long gap or jump.
                if let reference {
                    feedbacks.append(TransportFeedback(feedbackSequence: sequence, baseNumber: base, referenceTime: reference,
                                                       arrivals: arrivals))
                    sequence &+= 1
                }
                let continuing = base + UInt64(arrivals.count)
                base = !tooFar && packet.number - continuing < limit ? continuing : packet.number
                arrivals = []
                reference = nil
                continue
            }
            while UInt64(arrivals.count) < offset { arrivals.append(nil) }
            if let ticks {
                previous += Int64(ticks) * TransportFeedback.tick
            } else {
                reference = packet.arrival
                previous = packet.arrival
            }
            arrivals.append(previous)
            index += 1
        }
        if let reference {
            feedbacks.append(TransportFeedback(feedbackSequence: sequence, baseNumber: base, referenceTime: reference,
                                               arrivals: arrivals))
            sequence &+= 1
        }
        nextUnreported = base + UInt64(arrivals.count)
        pending.removeAll(keepingCapacity: true)
        lastBuilt = now
        return feedbacks
    }
}

/// The hub's record of what it sent, by packet number, so the phone's reports can be matched to send times and sizes.
/// Holds the last 8,192 packets (several seconds at the highest rates).
nonisolated public struct SentPacketHistory: Sendable {
    public static let capacity = 8192

    nonisolated public struct Entry: Sendable, Equatable {
        public var number: UInt64
        public var sendTime: Int64
        public var size: Int
        public var probeCluster: UInt16?
        /// Bytes sent up to and including this packet.
        public var cumulativeBytes: Int64
        var reported = false
    }

    private var ring = [Entry?](repeating: nil, count: SentPacketHistory.capacity)
    /// Every byte recorded so far.
    public private(set) var totalBytes: Int64 = 0

    public init() {}

    public mutating func record(number: UInt64, sendTime: Int64, size: Int, probeCluster: UInt16? = nil) {
        totalBytes += Int64(size)
        ring[Int(number % UInt64(Self.capacity))] = Entry(number: number, sendTime: sendTime, size: size,
                                                          probeCluster: probeCluster, cumulativeBytes: totalBytes)
    }

    /// The packet's record, reported or not; nil if unknown or overwritten.
    public func entry(_ number: UInt64) -> Entry? {
        guard let entry = ring[Int(number % UInt64(Self.capacity))], entry.number == number else { return nil }
        return entry
    }

    /// The packet's record, once: nil if unknown, already reported or overwritten.
    public mutating func take(_ number: UInt64) -> Entry? {
        let slot = Int(number % UInt64(Self.capacity))
        guard var entry = ring[slot], entry.number == number, !entry.reported else { return nil }
        entry.reported = true
        ring[slot] = entry
        return entry
    }
}
