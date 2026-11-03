import Foundation

/// Paces what the hub sends at about 2.5× the target bitrate with a 5 ms burst allowance, so a frame leaves in a
/// fraction of its interval without flooding the bottleneck's queue.
///
/// Control messages and sound go at once (they count against the budget, so pictures yield to them, never the other
/// way); resends go before new picture pieces. Picture data never waits long: when the queued resends and pieces would
/// take longer than the profile's 20–35 ms to leave, a new frame is refused before any of it is sent and reported, and
/// every later frame is refused until the encoder sends a refresh frame (one that refers only to an acknowledged
/// long-term reference, or a keyframe). A refresh frame makes everything still queued unnecessary and drops it, except
/// the rest of a refresh frame already going out, which frames behind it may need; and a refresh frame's own bytes
/// don't count against the backlog, so the frames after a big keyframe wait for it rather than force another.
/// Probe padding goes at its cluster's own rate. While the network holds more than the congestion window
/// (`windowOpen` false, set by `MediaSender`), new frames are refused, refresh frames too; frames already queued finish.
nonisolated public final class Pacer {
    nonisolated public enum Priority: Int, Sendable, CaseIterable {
        case control = 0, audio, retransmission, video
    }

    nonisolated public struct Item: Sendable {
        public var message: TransportMessage
        public var priority: Priority
        /// The sealed datagram's size.
        public var size: Int
        public var enqueued: Int64
        public var frameID: UInt32?
        public var refresh: Bool
        /// Not worth sending after this µs (the phone has given up on its frame).
        public var expires: Int64?
        public var probeCluster: UInt16?
    }

    nonisolated public enum DropReason: String, Sendable, Equatable {
        /// The picture backlog was over the limit.
        case queueFull
        /// An earlier frame was dropped and this isn't a refresh frame, so the phone couldn't decode it.
        case awaitingRefresh
        /// The network already holds more than the congestion window.
        case congested
    }

    nonisolated public enum Admission: Sendable, Equatable {
        case accepted
        case dropped(DropReason)
    }

    nonisolated public struct Stats: Sendable, Equatable {
        public var controlSent = 0
        public var audioSent = 0
        public var retransmissionsSent = 0
        public var videoSent = 0
        public var probesSent = 0
        public var framesDroppedQueueFull = 0
        public var framesDroppedAwaitingRefresh = 0
        public var framesDroppedCongested = 0
        /// Queued frames dropped because a refresh frame made them unnecessary.
        public var framesSuperseded = 0
        /// Queued pieces dropped at their frame's deadline.
        public var expired = 0
    }

    /// Bits per second.
    public var pacingRate: Double {
        didSet { pacingRate = max(pacingRate, 64_000) }
    }
    /// µs of picture backlog allowed before frames are refused.
    public var maxVideoQueueDelay: Int64
    /// False while the network holds more than the congestion window (`MediaSender` decides): new frames are
    /// refused until reports catch up, and the first one after must be a refresh frame.
    public var windowOpen = true
    public var burstInterval: Int64 = 5_000
    public private(set) var stats = Stats()
    /// A frame was refused; only a refresh frame is accepted until one comes.
    public private(set) var needsRefresh = false

    private var queues = [Queue](repeating: Queue(), count: Priority.allCases.count)
    /// Bytes sent beyond what the pacing rate has paid off yet.
    private var debt = 0.0
    private var lastUpdate: Int64?
    private var probe: ActiveProbe?
    /// The picture whose pieces have started going out.
    private var sending: (frameID: UInt32, refresh: Bool)?

    public init(pacingRate: Double, maxVideoQueueDelay: Int64) {
        self.pacingRate = max(pacingRate, 64_000)
        self.maxVideoQueueDelay = maxVideoQueueDelay
    }

    private var bytesPerMicrosecond: Double { pacingRate / 8e6 }
    private var burstBytes: Double { max(bytesPerMicrosecond * Double(burstInterval), Double(TransportWire.maxDatagramSize)) }

    public var isProbing: Bool { probe != nil }

    public func queuedCount(_ priority: Priority) -> Int { queues[priority.rawValue].count }

    /// µs for everything queued ahead of a new frame (resends and every picture piece, refresh frames too) to leave.
    public var queueDelay: Int64 {
        let bytes = queues[Priority.retransmission.rawValue].bytes + queues[Priority.video.rawValue].bytes
        return Int64(Double(bytes) / bytesPerMicrosecond)
    }

    /// µs for the queued resends and (non-refresh) picture pieces to leave at the pacing rate.
    public var backlogDelay: Int64 {
        let pictureBytes = queues[Priority.video.rawValue].pending.reduce(0) { $0 + ($1.refresh ? 0 : $1.size) }
        let bytes = queues[Priority.retransmission.rawValue].bytes + pictureBytes
        return Int64(Double(bytes) / bytesPerMicrosecond)
    }

    // MARK: In

    public func enqueue(_ message: TransportMessage, priority: Priority, now: Int64, frameID: UInt32? = nil,
                        refresh: Bool = false, expires: Int64? = nil) {
        queues[priority.rawValue].push(Item(message: message, priority: priority, size: message.datagramSize,
                                            enqueued: now, frameID: frameID, refresh: refresh, expires: expires))
    }

    /// Whether a new frame may be sent; call before packetizing it, and enqueue its pieces only if accepted.
    public func admitFrame(refresh: Bool, now: Int64) -> Admission {
        payOff(now: now)
        guard windowOpen else {
            // Even a refresh frame would only add to the queue the network already holds.
            needsRefresh = true
            stats.framesDroppedCongested += 1
            return .dropped(.congested)
        }
        if refresh {
            stats.framesSuperseded += dropForRefresh()
            needsRefresh = false
            return .accepted
        }
        if needsRefresh {
            stats.framesDroppedAwaitingRefresh += 1
            return .dropped(.awaitingRefresh)
        }
        if backlogDelay > maxVideoQueueDelay {
            needsRefresh = true
            stats.framesDroppedQueueFull += 1
            return .dropped(.queueFull)
        }
        return .accepted
    }

    public func enqueueFrame(_ messages: [TransportMessage], frameID: UInt32, refresh: Bool, expires: Int64, now: Int64) {
        for message in messages {
            enqueue(message, priority: .video, now: now, frameID: frameID, refresh: refresh, expires: expires)
        }
    }

    public func startProbe(_ cluster: ProbeCluster, now: Int64) {
        probe = ActiveProbe(cluster: cluster, nextSend: now)
    }

    // MARK: Out

    /// Everything due now, in sending order.
    public func poll(now: Int64) -> [Item] {
        payOff(now: now)
        var out: [Item] = []
        for priority in [Priority.control, .audio] {
            while let item = queues[priority.rawValue].pop() { send(item, into: &out) }
        }
        while debt < burstBytes, let item = nextPaced(now: now) { send(item, into: &out) }
        if var active = probe {
            while now >= active.nextSend, !active.isDone {
                let message = TransportMessage.probe(TransportProbe(cluster: active.cluster.id,
                                                                    paddingSize: TransportWire.maxPayloadSize - 2))
                out.append(Item(message: message, priority: .video, size: message.datagramSize, enqueued: now,
                                frameID: nil, refresh: false, expires: nil, probeCluster: active.cluster.id))
                let size = message.datagramSize
                let interval: Double = Double(size) * 8e6 / Double(max(active.cluster.bitrate, 1))
                active.sentBytes += size
                active.sentPackets += 1
                active.nextSend += Int64(interval.rounded())
                stats.probesSent += 1
            }
            probe = active.isDone ? nil : active
        }
        return out
    }

    /// When `poll` next has something to send; nil when nothing is queued.
    public func nextSendTime(now: Int64) -> Int64? {
        if !queues[Priority.control.rawValue].isEmpty || !queues[Priority.audio.rawValue].isEmpty { return now }
        var next: Int64?
        if !queues[Priority.retransmission.rawValue].isEmpty || !queues[Priority.video.rawValue].isEmpty {
            let elapsed = Double(max(0, now - (lastUpdate ?? now)))
            let projected = max(0, debt - elapsed * bytesPerMicrosecond)
            next = projected < burstBytes ? now : now + Int64(((projected - burstBytes) / bytesPerMicrosecond).rounded(.up)) + 1
        }
        if let probe { next = min(next ?? probe.nextSend, probe.nextSend) }
        return next
    }

    // MARK: Inside

    nonisolated private struct ActiveProbe: Sendable {
        var cluster: ProbeCluster
        var nextSend: Int64
        var sentBytes = 0
        var sentPackets = 0

        var isDone: Bool { sentBytes >= cluster.minBytes && sentPackets >= cluster.minPackets }
    }

    nonisolated private struct Queue: Sendable {
        private var items: [Item] = []
        private var head = 0
        private(set) var bytes = 0

        var isEmpty: Bool { head >= items.count }
        var count: Int { items.count - head }
        var pending: ArraySlice<Item> { items[head...] }

        mutating func push(_ item: Item) {
            items.append(item)
            bytes += item.size
        }

        mutating func pop() -> Item? {
            guard head < items.count else { return nil }
            let item = items[head]
            head += 1
            bytes -= item.size
            if head > 256, head * 2 > items.count {
                items.removeFirst(head)
                head = 0
            }
            return item
        }

        mutating func removeAll(where shouldRemove: (Item) -> Bool) {
            items = items[head...].filter { !shouldRemove($0) }
            head = 0
            bytes = items.reduce(0) { $0 + $1.size }
        }
    }

    private func payOff(now: Int64) {
        if let lastUpdate, now > lastUpdate {
            debt = max(0, debt - Double(now - lastUpdate) * bytesPerMicrosecond)
        }
        lastUpdate = max(lastUpdate ?? now, now)
    }

    /// The next resend or picture piece, skipping any whose frame the phone has given up on.
    private func nextPaced(now: Int64) -> Item? {
        for priority in [Priority.retransmission, .video] {
            while let item = queues[priority.rawValue].pop() {
                if let expires = item.expires, now >= expires {
                    stats.expired += 1
                    continue
                }
                return item
            }
        }
        return nil
    }

    private func send(_ item: Item, into out: inout [Item]) {
        debt += Double(item.size)
        switch item.priority {
        case .control: stats.controlSent += 1
        case .audio: stats.audioSent += 1
        case .retransmission: stats.retransmissionsSent += 1
        case .video:
            stats.videoSent += 1
            if let frameID = item.frameID { sending = (frameID, item.refresh) }
        }
        out.append(item)
    }

    /// Drops queued pictures and resends for a refresh frame; returns how many frames went.
    private func dropForRefresh() -> Int {
        let keep = sending.flatMap { $0.refresh ? $0.frameID : nil }
        var dropped = Set<UInt32>()
        queues[Priority.video.rawValue].removeAll { item in
            guard item.frameID != keep else { return false }
            if let frameID = item.frameID { dropped.insert(frameID) }
            return true
        }
        queues[Priority.retransmission.rawValue].removeAll { $0.frameID != keep }
        return dropped.count
    }
}
