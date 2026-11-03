import Foundation

// An in-process network for the transport's tests: a deterministic event loop on a simulated clock (µs) that runs the
// hub's `MediaSender` and the phone's `MediaReceiver` over two emulated links (bottleneck bandwidth with a drop-tail
// queue, propagation delay, jitter, random or bursty loss, reordering), with a video source that behaves like an encoder
// (frames sized by the transport's target, a refresh frame whenever a frame was dropped or the phone asks for one).

/// SplitMix64: the same numbers every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

/// One direction of a path.
final class EmulatedLink {
    enum Loss {
        case none
        /// Each packet independently.
        case random(Double)
        /// Gilbert's two-state model: runs of losses averaging `meanBurst` packets, `meanLoss` of packets overall.
        case bursty(meanLoss: Double, meanBurst: Double)
    }

    struct Config {
        /// Bottleneck rate, bits per second, at a time (µs).
        var capacity: (Int64) -> Double = { _ in 100_000_000 }
        /// One-way propagation, µs.
        var delay: Int64 = 20_000
        /// Up to this much extra delay per packet (uniform), µs; order is kept unless a packet is reordered.
        var jitter: Int64 = 0
        /// Drop-tail: a packet that would wait longer than this in the bottleneck queue is dropped.
        var queueLimit: Int64 = 300_000
        var loss: Loss = .none
        var reorderChance = 0.0
        var reorderDelay: Int64 = 8_000
    }

    struct Stats {
        var sent = 0
        var delivered = 0
        var queueDrops = 0
        var lossDrops = 0
    }

    let config: Config
    private(set) var stats = Stats()
    /// When each packet entered the bottleneck and how long it queued there.
    private(set) var queueDelays: [(time: Int64, delay: Int64)] = []
    /// When each packet arrived and its size.
    private(set) var deliveries: [(time: Int64, bytes: Int)] = []
    private var random: SeededGenerator
    private var busyUntil: Int64 = 0
    private var lastArrival: Int64 = 0
    private var inBurst = false
    private var order = 0
    /// Sorted by arrival time, then by sending order.
    private var inFlight: [(time: Int64, order: Int, data: Data)] = []

    init(_ config: Config, seed: UInt64) {
        self.config = config
        random = SeededGenerator(seed: seed)
    }

    var nextArrival: Int64? { inFlight.first?.time }

    func send(_ datagram: Data, at now: Int64) {
        stats.sent += 1
        let start = max(now, busyUntil)
        guard start - now <= config.queueLimit else {
            stats.queueDrops += 1
            return
        }
        queueDelays.append((now, start - now))
        busyUntil = start + Int64((Double(datagram.count * 8) / config.capacity(start) * 1e6).rounded())
        // Lost after the bottleneck: it used the capacity, as on a lossy radio hop.
        guard !lose() else {
            stats.lossDrops += 1
            return
        }
        var arrival = busyUntil + config.delay
        if config.jitter > 0 { arrival += Int64(random.unit() * Double(config.jitter)) }
        if config.reorderChance > 0, random.chance(config.reorderChance) {
            arrival += config.reorderDelay
        } else {
            arrival = max(arrival, lastArrival)
            lastArrival = arrival
        }
        order += 1
        let entry = (time: arrival, order: order, data: datagram)
        let index = inFlight.firstIndex { ($0.time, $0.order) > (arrival, order) } ?? inFlight.count
        inFlight.insert(entry, at: index)
    }

    func deliver(upTo now: Int64) -> [Data] {
        var due: [Data] = []
        while let first = inFlight.first, first.time <= now {
            inFlight.removeFirst()
            stats.delivered += 1
            deliveries.append((first.time, first.data.count))
            due.append(first.data)
        }
        return due
    }

    /// Delivered bits per second between two times.
    func throughput(from start: Int64, to end: Int64) -> Double {
        let bytes = deliveries.reduce(0) { $0 + ($1.time >= start && $1.time < end ? $1.bytes : 0) }
        return Double(bytes) * 8e6 / Double(end - start)
    }

    /// Queuing delays (µs) of packets entering the bottleneck between two times, sorted.
    func queueDelays(from start: Int64, to end: Int64) -> [Int64] {
        queueDelays.filter { $0.time >= start && $0.time < end }.map(\.delay).sorted()
    }

    private func lose() -> Bool {
        switch config.loss {
        case .none:
            return false
        case .random(let rate):
            return random.chance(rate)
        case .bursty(let meanLoss, let meanBurst):
            let leave = 1 / max(meanBurst, 1)
            let enter = meanLoss * leave / max(1 - meanLoss, 0.01)
            inBurst = inBurst ? !random.chance(leave) : random.chance(enter)
            return inBurst
        }
    }
}

/// The hub's sender and the phone's receiver over two emulated links, with an encoder-like video source.
final class TransportSimulation {
    struct FrameRecord {
        var sentAt: Int64
        var data: Data
        var refresh: Bool
        var deliveredAt: Int64?
        var lost = false
        var skipped = false
        var recoveredPieces = 0
        var resentPieces = 0
        var corrupt = false
    }

    struct FrameSummary: CustomStringConvertible {
        var sent = 0
        var delivered = 0
        var onTime = 0
        var lost = 0
        var skipped = 0
        var unresolved = 0
        var corrupt = 0
        var refusedAtHub = ""
        var withRecovery = 0
        var withResends = 0
        var latencies: [Int64] = []

        var onTimeShare: Double { sent == 0 ? 0 : Double(onTime) / Double(sent) }
        var deliveredShare: Double { sent == 0 ? 0 : Double(delivered) / Double(sent) }

        func percentile(_ fraction: Double) -> Double {
            guard !latencies.isEmpty else { return 0 }
            let index = min(latencies.count - 1, Int(Double(latencies.count - 1) * fraction))
            return Double(latencies[index]) / 1000
        }

        var description: String {
            String(format: "sent %ld, delivered %ld (%.2f%%), on time %ld (%.2f%%), lost %ld, skipped %ld, unresolved %ld, "
                + "corrupt %ld, rebuilt from parity %ld, completed by resends %ld, latency p50 %.1f ms p95 %.1f ms p99 %.1f ms",
                   sent, delivered, deliveredShare * 100, onTime, onTimeShare * 100, lost, skipped, unresolved, corrupt,
                   withRecovery, withResends, percentile(0.5), percentile(0.95), percentile(0.99)) + "; refused at the hub: \(refusedAtHub)"
        }
    }

    let sender: MediaSender
    let receiver: MediaReceiver
    let forward: EmulatedLink
    let backward: EmulatedLink
    private(set) var now: Int64 = 1_000_000
    /// The source's frame rate before the path's cap.
    var framesPerSecond = 60.0
    /// A fixed frame size instead of following the encoder target.
    var fixedFrameSize: Int?
    var sendsAudio = false
    private(set) var videoBitrate = 1_000_000
    private(set) var frames: [UInt32: FrameRecord] = [:]
    private(set) var dropsAtSender = 0
    private(set) var refreshRequests = 0
    private(set) var audioFramesSent = 0
    private(set) var audioFramesReceived = 0
    /// (time, target bitrate), every 50 ms.
    private(set) var targets: [(time: Int64, bitrate: Int)] = []
    private var maxFramesPerSecond = 60
    private var needsRefresh = true
    private var awaitingAfterLoss = false
    private var lastRefreshRequest: Int64?
    /// When the source last sent a refresh frame: like step 1's `VideoPacing`, it ignores the phone's requests while
    /// that one is still on its way (a round trip and a little), since it answers them.
    private var lastRefreshFrame: Int64?
    private var nextFrame: Int64
    private var nextAudio: Int64
    private var nextSample: Int64
    private var frameIndex = 0
    private var random: SeededGenerator
    private var started = false
    private var streaming = false

    init(profile: PathProfile, network: PhoneNetwork = .wifi, forward: EmulatedLink.Config,
         backward: EmulatedLink.Config, seed: UInt64) throws {
        guard let keys = TransportKeys(sessionID: 0x00C0_FFEE, sessionKey: Data((0..<32).map { UInt8($0) })) else {
            throw TransportError.sealFailed
        }
        sender = MediaSender(keys: keys, profile: profile)
        receiver = MediaReceiver(keys: keys, network: network)
        self.forward = EmulatedLink(forward, seed: seed)
        self.backward = EmulatedLink(backward, seed: seed &+ 1)
        random = SeededGenerator(seed: seed &+ 2)
        nextFrame = now
        nextAudio = now
        nextSample = now
    }

    func run(until end: Int64) {
        if !started {
            started = true
            if let hello = receiver.hello(now: now) { backward.send(hello, at: now) }
        }
        while now < end {
            var next = min(end, sender.nextWakeup(now: now), receiver.nextWakeup(now: now), nextSample)
            if sender.isConnected { next = min(next, nextFrame) }
            if sendsAudio, sender.isConnected { next = min(next, nextAudio) }
            if let arrival = forward.nextArrival { next = min(next, arrival) }
            if let arrival = backward.nextArrival { next = min(next, arrival) }
            now = max(next, now + 1)
            step()
        }
    }

    private func step() {
        for datagram in forward.deliver(upTo: now) { phone(receiver.receive(datagram, now: now)) }
        for datagram in backward.deliver(upTo: now) { hub(sender.receive(datagram, now: now)) }
        if sender.isConnected, !streaming {
            // The source starts when the hub hears the phone, not at time zero.
            streaming = true
            nextFrame = now
            nextAudio = now
        }
        if sender.isConnected, now >= nextFrame {
            produceFrame()
            nextFrame += Int64(1e6 / min(framesPerSecond, Double(maxFramesPerSecond)))
        }
        if sendsAudio, sender.isConnected, now >= nextAudio {
            let frame = Data(repeating: UInt8(truncatingIfNeeded: audioFramesSent), count: 160)
            sender.sendAudio(frame, timestamp: UInt64(now), duration: 10_000, now: now)
            audioFramesSent += 1
            nextAudio += 10_000
        }
        let out = sender.poll(now: now)
        hub(out.events)
        for datagram in out.datagrams { forward.send(datagram, at: now) }
        let back = receiver.poll(now: now)
        phone(back.events)
        for datagram in back.datagrams { backward.send(datagram, at: now) }
        // The app asks for a refresh with every feedback while frames are being skipped after a loss.
        if awaitingAfterLoss, receiver.awaitingRefresh, lastRefreshRequest.map({ now - $0 >= 20_000 }) ?? true,
           let request = try? receiver.appMessage(AppMessage(channel: 1, data: Data([1])), now: now) {
            lastRefreshRequest = now
            backward.send(request, at: now)
        }
        if now >= nextSample {
            targets.append((now, sender.targetBitrate))
            nextSample += 50_000
        }
    }

    private func produceFrame() {
        let base = fixedFrameSize ?? max(300, videoBitrate / 8 / min(Int(framesPerSecond), maxFramesPerSecond))
        var size = Int(Double(base) * (0.7 + 0.6 * random.unit()))
        let refresh = needsRefresh
        // The first frame is a keyframe; later refresh frames (from a long-term reference) are about twice a frame.
        if refresh { size *= frames.isEmpty ? 4 : 2 }
        frameIndex += 1
        var bytes = [UInt8](repeating: 0, count: max(size, 8))
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ frameIndex &* 7) }
        withUnsafeBytes(of: UInt64(frameIndex).bigEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        let data = Data(bytes)
        switch sender.sendVideo(data, refresh: refresh, now: now) {
        case .sent(let frameID):
            frames[frameID] = FrameRecord(sentAt: now, data: data, refresh: refresh)
            if refresh { lastRefreshFrame = now }
            needsRefresh = false
        case .dropped(.queueFull), .dropped(.awaitingRefresh), .dropped(.congested):
            dropsAtSender += 1
            needsRefresh = true
        case .dropped:
            break
        }
    }

    private func hub(_ events: [SenderEvent]) {
        for event in events {
            switch event {
            case .encoderTarget(let target):
                videoBitrate = target.videoBitrate
                maxFramesPerSecond = target.maxFramesPerSecond
            case .appMessage(let message) where message.channel == 1:
                refreshRequests += 1
                let inFlight = (sender.roundTrip ?? 100_000) + 50_000
                if lastRefreshFrame.map({ now - $0 >= inFlight }) ?? true { needsRefresh = true }
            default:
                break
            }
        }
    }

    private func phone(_ events: [ReceiverEvent]) {
        for event in events {
            switch event {
            case .frame(let frame):
                awaitingAfterLoss = false
                guard var record = frames[frame.frameID] else { continue }
                record.deliveredAt = now
                record.corrupt = frame.data != record.data
                record.recoveredPieces = frame.recoveredFragments
                record.resentPieces = frame.retransmittedFragments
                frames[frame.frameID] = record
            case .frameLost(let frameID):
                awaitingAfterLoss = true
                frames[frameID]?.lost = true
            case .frameSkipped(let frameID):
                frames[frameID]?.skipped = true
            case .audio(let received):
                audioFramesReceived += received.count
            default:
                break
            }
        }
    }

    /// Frames sent between two times; on time means shown within `budget` µs of being handed to the transport.
    func summary(from start: Int64, to end: Int64, budget: Int64) -> FrameSummary {
        var summary = FrameSummary()
        for record in frames.values where record.sentAt >= start && record.sentAt < end {
            summary.sent += 1
            if record.corrupt { summary.corrupt += 1 }
            if let delivered = record.deliveredAt {
                summary.delivered += 1
                let latency = delivered - record.sentAt
                summary.latencies.append(latency)
                if latency <= budget { summary.onTime += 1 }
                if record.recoveredPieces > 0 { summary.withRecovery += 1 }
                if record.resentPieces > 0 { summary.withResends += 1 }
            } else if record.lost {
                summary.lost += 1
            } else if record.skipped {
                summary.skipped += 1
            } else {
                summary.unresolved += 1
            }
        }
        summary.latencies.sort()
        let pacer = sender.pacerStats
        summary.refusedAtHub = "\(pacer.framesDroppedQueueFull) backlog, \(pacer.framesDroppedCongested) window, "
            + "\(pacer.framesDroppedAwaitingRefresh) awaiting a refresh"
        return summary
    }

    /// The first sampled time at or after `start` when the target satisfied `condition`.
    func firstTarget(after start: Int64, where condition: (Int) -> Bool) -> Int64? {
        targets.first { $0.time >= start && condition($0.bitrate) }?.time
    }

    /// The longest time between two frames being shown: how long the picture froze at worst.
    func longestStall(from start: Int64, to end: Int64) -> Int64 {
        let times = frames.values.compactMap(\.deliveredAt).filter { $0 >= start && $0 < end }.sorted()
        return zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
    }

    func meanTarget(from start: Int64, to end: Int64) -> Double {
        let window = targets.filter { $0.time >= start && $0.time < end }
        guard !window.isEmpty else { return 0 }
        return Double(window.reduce(0) { $0 + $1.bitrate }) / Double(window.count)
    }
}

/// Prints a measured number where the test log shows it (grep "TRANSPORT-METRIC").
func reportMetric(_ text: String) {
    print("TRANSPORT-METRIC \(text)")
}
