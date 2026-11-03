import Foundation

/// Puts pictures back together on the phone: pieces in any order, repeated or missing, rebuilt from parity where a
/// block has enough, and frames handed on in order, each once.
///
/// A frame refers to the ones before it, so a later frame is never handed on over a lost one. When a frame isn't
/// complete by its deadline it's reported lost and everything after it is skipped until a refresh frame (a keyframe or
/// one that refers only to an acknowledged long-term reference) completes; the app asks for one with
/// `ScreenFeedback.refresh` while `awaitingRefresh` holds. A complete refresh frame also ends the wait for any
/// incomplete frame before it, since it doesn't need them.
nonisolated public final class FrameAssembler {
    nonisolated public struct Settings: Sendable {
        /// µs to wait for a frame after its first sign (a piece, a parity packet, a later frame or the hub's report)
        /// or, while its pieces keep coming, after the latest one: a large keyframe on a slow path takes longer than
        /// the deadline to arrive, and giving it up halfway would only bring another one.
        public var frameDeadline: Int64 = 150_000
        /// µs after which a frame is given up even while pieces still trickle in.
        public var maxFrameAge: Int64 = 2_000_000
        /// Frames held at once; past it, the oldest are given up (only after a long outage).
        public var maxPendingFrames = 64
        /// The largest frame accepted, in pieces (≈9 MB).
        public var maxFragments = 8192

        public init() {}
    }

    nonisolated public struct AssembledFrame: Sendable, Equatable {
        public var frameID: UInt32
        public var flags: FrameFlags
        /// The frame's bytes, as the hub handed them over.
        public var data: Data
        public var firstSequence: UInt32
        public var fragmentCount: Int
        /// µs: the frame's first sign, and when it completed.
        public var firstSeen: Int64
        public var completed: Int64
        public var recoveredFragments: Int
        public var retransmittedFragments: Int
        /// The hub's clock against the phone's when the frame was delivered (`MediaReceiver.hubClockOffset`), for
        /// measuring the frame's delay from capture; nil until the receiver has an estimate.
        public var hubClockOffset: UInt32? = nil

        public var lastSequence: UInt32 { firstSequence &+ UInt32(fragmentCount - 1) }
    }

    nonisolated public enum Event: Sendable, Equatable {
        case frame(AssembledFrame)
        /// Not complete by its deadline (or pushed out): what follows waits for a refresh frame.
        case lost(frameID: UInt32, lastSequence: UInt32?)
        /// Dropped without asking for anything: it followed a lost frame and isn't a refresh frame, or a later
        /// refresh frame made it unnecessary.
        case skipped(frameID: UInt32, lastSequence: UInt32?)
        /// Pieces rebuilt from parity, so asking for their resend can stop.
        case recovered(sequences: [UInt32])
    }

    nonisolated public struct Stats: Sendable, Equatable {
        public var delivered = 0
        public var lost = 0
        public var skipped = 0
        public var recoveredFragments = 0
    }

    public var settings: Settings
    /// A frame was lost and no refresh frame has completed since.
    public private(set) var awaitingRefresh = true
    public private(set) var stats = Stats()
    /// The frame to hand on next.
    private var next: UInt32?
    /// A frame was shown or given up, so nothing before `next` can still matter. Until then a frame from before the
    /// first one seen may still arrive (the first frames came out of order), and the stream's first frames wait for it.
    private var anchored = false
    private var frames: [UInt32: Partial] = [:]

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var pendingFrames: Int { frames.count }

    /// When the frame everything waits on gives up, if it's waiting.
    public var nextDeadline: Int64? { next.flatMap { frames[$0]?.deadline } }

    public func add(_ fragment: VideoFragment, now: Int64) -> [Event] {
        var events: [Event] = []
        guard let partial = entry(for: fragment.frameID, now: now, events: &events),
              describe(partial, count: Int(fragment.count), flags: fragment.flags.frameOnly,
                       blockSize: Int(fragment.fecBlockSize), firstSequence: fragment.firstSequence) else {
            drain(now: now, events: &events)
            return events
        }
        let index = Int(fragment.index)
        if partial.pieces[index] == nil {
            partial.pieces[index] = fragment.payload
            partial.received += 1
            partial.lastProgress = now
            if fragment.flags.contains(.retransmission) { partial.retransmitted += 1 }
            if partial.blockSize > 0 { recover(partial, block: index / partial.blockSize, events: &events) }
        }
        drain(now: now, events: &events)
        return events
    }

    public func add(_ parity: ParityFragment, now: Int64) -> [Event] {
        var events: [Event] = []
        guard let partial = entry(for: parity.frameID, now: now, events: &events),
              describe(partial, count: Int(parity.count), flags: parity.flags.frameOnly,
                       blockSize: Int(parity.fecBlockSize), firstSequence: parity.firstSequence) else {
            drain(now: now, events: &events)
            return events
        }
        let block = Int(parity.block)
        let parityCount = Int(parity.parityCount)
        if let known = partial.parityCounts[block], known != parityCount {
            drain(now: now, events: &events)
            return events
        }
        partial.parityCounts[block] = parityCount
        let start = block * partial.blockSize
        let end = min(start + partial.blockSize, partial.count)
        let blockComplete = (start..<end).allSatisfy { partial.pieces[$0] != nil }
        if !blockComplete, partial.parity[block]?[Int(parity.parityIndex)] == nil {
            partial.parity[block, default: [:]][Int(parity.parityIndex)] = parity.shard
            partial.lastProgress = now
            recover(partial, block: block, events: &events)
        }
        drain(now: now, events: &events)
        return events
    }

    /// The hub has sent frames up to this one (from its report), so a frame that never showed a single piece gets a
    /// deadline too.
    public func announce(lastFrameID: UInt32, now: Int64) -> [Event] {
        var events: [Event] = []
        if let next, SerialNumber.isBefore(lastFrameID, next) { return events }
        _ = entry(for: lastFrameID, now: now, events: &events)
        drain(now: now, events: &events)
        return events
    }

    /// Gives up the frame everything waits on once its deadline passes, and what that unblocks.
    public func expire(now: Int64) -> [Event] {
        var events: [Event] = []
        while let id = next, let partial = frames[id], now >= partial.deadline {
            frames[id] = nil
            next = id &+ 1
            events.append(.lost(frameID: id, lastSequence: partial.lastSequence))
            stats.lost += 1
            awaitingRefresh = true
            anchored = true
            drain(now: now, events: &events)
        }
        return events
    }

    // MARK: Frames

    nonisolated private final class Partial {
        let frameID: UInt32
        let firstSeen: Int64
        /// The latest time a piece or parity shard added something.
        var lastProgress: Int64
        let deadlineAfterProgress: Int64
        let latestDeadline: Int64
        /// Count, flags, block size and first sequence are known once any piece or parity packet arrived.
        var known = false
        var count = 0
        var flags: FrameFlags = []
        var blockSize = 0
        var firstSequence: UInt32 = 0
        var pieces: [Data?] = []
        var received = 0
        /// Block → parity index → shard, while the block is incomplete.
        var parity: [Int: [Int: Data]] = [:]
        var parityCounts: [Int: Int] = [:]
        var recovered = 0
        var retransmitted = 0

        init(frameID: UInt32, firstSeen: Int64, settings: Settings) {
            self.frameID = frameID
            self.firstSeen = firstSeen
            lastProgress = firstSeen
            deadlineAfterProgress = settings.frameDeadline
            latestDeadline = firstSeen + max(settings.maxFrameAge, settings.frameDeadline)
        }

        var deadline: Int64 { min(lastProgress + deadlineAfterProgress, latestDeadline) }
        var isComplete: Bool { known && received == count }
        var isRefresh: Bool { known && flags.contains(.refresh) }
        var lastSequence: UInt32? { known ? firstSequence &+ UInt32(count - 1) : nil }
    }

    /// The frame's entry, made if needed; nil for a frame already handed on or given up.
    private func entry(for frameID: UInt32, now: Int64, events: inout [Event]) -> Partial? {
        if let existing = frames[frameID] { return existing }
        if let next {
            if SerialNumber.isBefore(frameID, next) {
                // Already handed on or given up; unless nothing has been yet and this frame comes from just before the
                // one the stream started with (the first frames arrived out of order).
                guard !anchored, SerialNumber.distance(from: frameID, to: next) < Int64(settings.maxPendingFrames) else {
                    return nil
                }
                self.next = frameID
            }
        } else {
            next = frameID
        }
        if let start = next, SerialNumber.distance(from: start, to: frameID) >= Int64(settings.maxPendingFrames) {
            // A long outage: the frames before the window are gone.
            giveUp(before: frameID &- UInt32(settings.maxPendingFrames - 1), events: &events)
        }
        // Frames between the next one and this one haven't shown a piece yet: their deadline starts now.
        var id = next ?? frameID
        while SerialNumber.isBefore(id, frameID) {
            if frames[id] == nil { frames[id] = Partial(frameID: id, firstSeen: now, settings: settings) }
            id &+= 1
        }
        let partial = Partial(frameID: frameID, firstSeen: now, settings: settings)
        frames[frameID] = partial
        return partial
    }

    /// Fills in what a piece or parity packet says about its frame; false if it contradicts what's known.
    private func describe(_ partial: Partial, count: Int, flags: FrameFlags, blockSize: Int, firstSequence: UInt32) -> Bool {
        if partial.known {
            return partial.count == count && partial.blockSize == blockSize && partial.flags == flags
                && partial.firstSequence == firstSequence
        }
        guard count > 0, count <= settings.maxFragments else { return false }
        partial.known = true
        partial.count = count
        partial.flags = flags
        partial.blockSize = blockSize
        partial.firstSequence = firstSequence
        partial.pieces = Array(repeating: nil, count: count)
        return true
    }

    /// Rebuilds a block's missing pieces once it has as many pieces and parity shards as it has pieces.
    private func recover(_ partial: Partial, block: Int, events: inout [Event]) {
        guard partial.blockSize > 0, let parityCount = partial.parityCounts[block],
              let shards = partial.parity[block], !shards.isEmpty else { return }
        let start = block * partial.blockSize
        let end = min(start + partial.blockSize, partial.count)
        guard start < end else { return }
        let pieces = end - start
        let missing = (start..<end).filter { partial.pieces[$0] == nil }
        guard !missing.isEmpty else {
            partial.parity[block] = nil
            return
        }
        guard pieces - missing.count + shards.count >= pieces,
              let shardLength = shards.values.first?.count, shardLength >= 2,
              shards.values.allSatisfy({ $0.count == shardLength }),
              let code = ReedSolomon(dataShards: pieces, parityShards: parityCount) else { return }
        var input = [[UInt8]?](repeating: nil, count: pieces + parityCount)
        for offset in 0..<pieces {
            guard let piece = partial.pieces[start + offset] else { continue }
            guard piece.count <= shardLength - 2 else { return }
            input[offset] = VideoFEC.shard(piece, length: shardLength - 2)
        }
        for (index, shard) in shards where index < parityCount { input[pieces + index] = [UInt8](shard) }
        guard let data = code.reconstruct(input) else { return }
        let rebuilt = missing.compactMap { index in VideoFEC.payload(fromShard: data[index - start]).map { (index, $0) } }
        guard rebuilt.count == missing.count else { return }
        for (index, payload) in rebuilt {
            partial.pieces[index] = payload
            partial.received += 1
            partial.recovered += 1
        }
        partial.parity[block] = nil
        stats.recoveredFragments += rebuilt.count
        events.append(.recovered(sequences: missing.map { partial.firstSequence &+ UInt32($0) }))
    }

    /// Hands on every frame that can go now, in order.
    private func drain(now: Int64, events: inout [Event]) {
        while let id = next {
            let refresh = earliestCompleteRefresh()
            guard let partial = frames[id] else {
                if let refresh {
                    skip(until: refresh, events: &events)
                    continue
                }
                return
            }
            if partial.isComplete && (!awaitingRefresh || partial.isRefresh) {
                deliver(partial, now: now, events: &events)
                continue
            }
            if awaitingRefresh && anchored && partial.known && !partial.isRefresh {
                // It needs the lost frame: it can never be shown.
                frames[id] = nil
                next = id &+ 1
                stats.skipped += 1
                events.append(.skipped(frameID: id, lastSequence: partial.lastSequence))
                continue
            }
            if let refresh, refresh != id {
                skip(until: refresh, events: &events)
                continue
            }
            return
        }
    }

    private func earliestCompleteRefresh() -> UInt32? {
        guard let next else { return nil }
        var earliest: UInt32?
        for (id, partial) in frames where partial.isComplete && partial.isRefresh && !SerialNumber.isBefore(id, next) {
            if let current = earliest, !SerialNumber.isBefore(id, current) { continue }
            earliest = id
        }
        return earliest
    }

    /// Drops the frames before a complete refresh frame: it doesn't need them.
    private func skip(until target: UInt32, events: inout [Event]) {
        while let id = next, SerialNumber.isBefore(id, target) {
            let partial = frames.removeValue(forKey: id)
            next = id &+ 1
            stats.skipped += 1
            events.append(.skipped(frameID: id, lastSequence: partial?.lastSequence))
        }
    }

    private func giveUp(before target: UInt32, events: inout [Event]) {
        while let id = next, SerialNumber.isBefore(id, target) {
            let partial = frames.removeValue(forKey: id)
            next = id &+ 1
            stats.lost += 1
            awaitingRefresh = true
            anchored = true
            events.append(.lost(frameID: id, lastSequence: partial?.lastSequence))
        }
    }

    private func deliver(_ partial: Partial, now: Int64, events: inout [Event]) {
        var data = Data(capacity: partial.pieces.reduce(0) { $0 + ($1?.count ?? 0) })
        for piece in partial.pieces {
            if let piece { data.append(piece) }
        }
        frames[partial.frameID] = nil
        next = partial.frameID &+ 1
        awaitingRefresh = false
        anchored = true
        stats.delivered += 1
        events.append(.frame(AssembledFrame(frameID: partial.frameID, flags: partial.flags, data: data,
                                            firstSequence: partial.firstSequence, fragmentCount: partial.count,
                                            firstSeen: partial.firstSeen, completed: now,
                                            recoveredFragments: partial.recovered,
                                            retransmittedFragments: partial.retransmitted)))
    }
}
