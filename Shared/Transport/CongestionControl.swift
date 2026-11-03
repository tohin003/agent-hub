import Foundation

// Send-side rate control after WebRTC's Google Congestion Control (draft-ietf-rmcat-gcc and WebRTC's GoogCC): the phone
// reports when each packet arrived; the hub groups packets sent within 5 ms, filters the change in one-way delay
// between groups through a trendline, and calls overuse when the slope stays above an adaptive threshold. An AIMD
// controller turns that into a rate (multiplicative growth until the link's capacity is known, additive near it, back
// to 85% of the delivered rate on overuse), a loss-based controller caps it when loss passes the path's threshold, and
// probe bursts find capacity quickly at the start. Times are µs, rates bits per second.

/// One sent packet's fate, from the phone's feedback.
nonisolated public struct PacketResult: Sendable, Equatable {
    public var number: UInt64
    /// µs on the hub's clock.
    public var sendTime: Int64
    /// The datagram's bytes.
    public var size: Int
    /// µs on the phone's clock; nil if it didn't arrive.
    public var arrival: Int64?
    public var probeCluster: UInt16?

    public init(number: UInt64, sendTime: Int64, size: Int, arrival: Int64?, probeCluster: UInt16? = nil) {
        self.number = number
        self.sendTime = sendTime
        self.size = size
        self.arrival = arrival
        self.probeCluster = probeCluster
    }
}

nonisolated public enum BandwidthUsage: String, Sendable, Equatable {
    case normal, overusing, underusing
}

// MARK: Delay-based estimation

/// Groups packets sent within 5 ms of each other (a burst) and gives the change in send spacing and in arrival
/// spacing from one group to the next.
nonisolated struct InterArrival: Sendable {
    static let groupLength: Int64 = 5_000
    static let burstThreshold: Int64 = 5_000
    static let maxBurstDuration: Int64 = 100_000
    static let reorderedResetThreshold = 3

    nonisolated struct Group: Sendable {
        var firstSend: Int64 = 0
        var send: Int64 = 0
        var firstArrival: Int64 = 0
        var completeArrival: Int64 = 0
        var size = 0
        var started = false
    }

    nonisolated struct Delta: Sendable, Equatable {
        var send: Int64
        var arrival: Int64
        var sizeDelta: Int
    }

    private var current = Group()
    private var previous = Group()
    private var reorderedRun = 0

    mutating func reset() {
        current = Group()
        previous = Group()
        reorderedRun = 0
    }

    /// Packets in arrival order; returns the deltas when this packet starts a new group.
    mutating func add(send: Int64, arrival: Int64, size: Int) -> Delta? {
        var delta: Delta?
        if !current.started {
            current = Group(firstSend: send, send: send, firstArrival: arrival, completeArrival: arrival, size: 0,
                            started: true)
        } else if current.firstSend > send {
            // Sent before the current group began: reordered on the way.
            return nil
        } else if isNewGroup(send: send, arrival: arrival) {
            if previous.started {
                let sendDelta = current.send - previous.send
                let arrivalDelta = current.completeArrival - previous.completeArrival
                if arrivalDelta < 0 {
                    reorderedRun += 1
                    if reorderedRun >= Self.reorderedResetThreshold { reset() }
                    return nil
                }
                reorderedRun = 0
                delta = Delta(send: sendDelta, arrival: arrivalDelta, sizeDelta: current.size - previous.size)
            }
            previous = current
            current = Group(firstSend: send, send: send, firstArrival: arrival, completeArrival: arrival, size: 0,
                            started: true)
        } else {
            current.send = max(current.send, send)
        }
        current.size += size
        current.completeArrival = arrival
        return delta
    }

    private func isNewGroup(send: Int64, arrival: Int64) -> Bool {
        guard current.started else { return false }
        if belongsToBurst(send: send, arrival: arrival) { return false }
        return send - current.firstSend > Self.groupLength
    }

    /// Packets that arrive back to back faster than they were sent were queued together on the way.
    private func belongsToBurst(send: Int64, arrival: Int64) -> Bool {
        let arrivalDelta = arrival - current.completeArrival
        let sendDelta = send - current.send
        if sendDelta == 0 { return true }
        let propagationDelta = arrivalDelta - sendDelta
        return propagationDelta < 0 && arrivalDelta <= Self.burstThreshold
            && arrival - current.firstArrival < Self.maxBurstDuration
    }
}

/// The trend of the one-way delay: the slope of a line through the last 20 smoothed, accumulated delay changes, and
/// whether it stays above (overuse) or below (underuse) an adaptive threshold. In ms, as WebRTC keeps it.
nonisolated struct TrendlineEstimator: Sendable {
    static let windowSize = 20
    static let smoothing = 0.9
    static let thresholdGain = 4.0
    static let overusingTimeThreshold = 10.0
    static let minNumDeltas = 60
    static let maxAdaptOffset = 15.0
    static let thresholdUpRate = 0.0087
    static let thresholdDownRate = 0.039

    private(set) var state: BandwidthUsage = .normal
    private(set) var threshold = 12.5
    private(set) var modifiedTrend = 0.0
    /// The smoothed accumulated delay change (ms): roughly how much has queued since the start.
    private(set) var smoothedDelay = 0.0
    private var deltas = 0
    private var firstArrival: Double?
    private var accumulated = 0.0
    private var history: [(x: Double, y: Double)] = []
    private var previousTrend = 0.0
    private var lastThresholdUpdate: Double?
    private var timeOverusing = -1.0
    private var overuseCount = 0

    mutating func update(arrivalDeltaMs: Double, sendDeltaMs: Double, arrivalMs: Double) {
        let delta = arrivalDeltaMs - sendDeltaMs
        deltas = min(deltas + 1, 1000)
        let first = firstArrival ?? arrivalMs
        firstArrival = first
        accumulated += delta
        smoothedDelay = Self.smoothing * smoothedDelay + (1 - Self.smoothing) * accumulated
        history.append((arrivalMs - first, smoothedDelay))
        if history.count > Self.windowSize { history.removeFirst() }
        var trend = previousTrend
        if history.count == Self.windowSize, let slope = Self.slope(history) { trend = slope }
        detect(trend: trend, sendDeltaMs: sendDeltaMs, nowMs: arrivalMs)
    }

    /// Least-squares slope; nil when every x is the same.
    static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var numerator = 0.0
        var denominator = 0.0
        for point in points {
            numerator += (point.x - meanX) * (point.y - meanY)
            denominator += (point.x - meanX) * (point.x - meanX)
        }
        return denominator == 0 ? nil : numerator / denominator
    }

    private mutating func detect(trend: Double, sendDeltaMs: Double, nowMs: Double) {
        guard deltas >= 2 else {
            state = .normal
            return
        }
        let modified = Double(min(deltas, Self.minNumDeltas)) * trend * Self.thresholdGain
        modifiedTrend = modified
        if modified > threshold {
            // Assume the overuse began halfway since the last sample.
            timeOverusing = timeOverusing < 0 ? sendDeltaMs / 2 : timeOverusing + sendDeltaMs
            overuseCount += 1
            if timeOverusing > Self.overusingTimeThreshold, overuseCount > 1, trend >= previousTrend {
                timeOverusing = 0
                overuseCount = 0
                state = .overusing
            }
        } else if modified < -threshold {
            timeOverusing = -1
            overuseCount = 0
            state = .underusing
        } else {
            timeOverusing = -1
            overuseCount = 0
            state = .normal
        }
        previousTrend = trend
        updateThreshold(modified, nowMs: nowMs)
    }

    /// The threshold follows the trend's size, quickly up and slowly down, so neither a competing TCP flow nor noise
    /// starves or triggers the detector; a sudden spike (a capacity drop) doesn't move it.
    private mutating func updateThreshold(_ modified: Double, nowMs: Double) {
        let last = lastThresholdUpdate ?? nowMs
        lastThresholdUpdate = nowMs
        guard abs(modified) <= threshold + Self.maxAdaptOffset else { return }
        let rate = abs(modified) < threshold ? Self.thresholdDownRate : Self.thresholdUpRate
        threshold += rate * (abs(modified) - threshold) * min(nowMs - last, 100)
        threshold = min(max(threshold, 6), 600)
    }
}

/// The link's capacity as seen at overuse events: an average with a deviation, so the AIMD knows when it's near it.
nonisolated struct LinkCapacityEstimator: Sendable {
    private var estimateKbps: Double?
    private var deviationKbps = 0.4

    var estimate: Double? { estimateKbps.map { $0 * 1000 } }
    var upperBound: Double { estimateKbps.map { ($0 + 3 * deviation) * 1000 } ?? .infinity }
    var lowerBound: Double { estimateKbps.map { max(0, $0 - 3 * deviation) * 1000 } ?? 0 }
    private var deviation: Double { (deviationKbps * (estimateKbps ?? 0)).squareRoot() }

    mutating func reset() { estimateKbps = nil }
    mutating func onOveruse(_ throughput: Double) { update(throughput, alpha: 0.05) }

    private mutating func update(_ sample: Double, alpha: Double) {
        let sampleKbps = sample / 1000
        let estimate = estimateKbps.map { (1 - alpha) * $0 + alpha * sampleKbps } ?? sampleKbps
        estimateKbps = estimate
        let error = estimate - sampleKbps
        deviationKbps = (1 - alpha) * deviationKbps + alpha * error * error / max(estimate, 1)
        deviationKbps = min(max(deviationKbps, 0.4), 2.5)
    }
}

/// Additive increase, multiplicative decrease, driven by the trendline's verdicts.
nonisolated struct AimdRateControl: Sendable {
    private enum State {
        case hold, increase, decrease
    }

    static let beta = 0.85

    var minBitrate: Double
    var maxBitrate: Double
    /// The round trip, for how fast to grow near capacity and how often to cut.
    var roundTrip: Int64 = 200_000
    private(set) var current: Double
    private var state: State = .hold
    private var lastChange: Int64?
    private var latestThroughput: Double?
    private var capacity = LinkCapacityEstimator()
    /// This spell of overuse has had its application-limited step.
    private var limitedCutThisSpell = false

    init(start: Double, min: Double, max: Double) {
        minBitrate = min
        maxBitrate = max
        current = Swift.min(Swift.max(start, min), max)
    }

    var linkCapacity: Double? { capacity.estimate }

    mutating func setEstimate(_ bitrate: Double, now: Int64) {
        current = clamp(bitrate)
        lastChange = now
    }

    mutating func clampToLimits() { current = clamp(current) }

    /// Whether to cut again while overuse continues: once per round trip (10–200 ms), or at once if far less is
    /// getting through than the estimate (unless that's only because the encoder sends less than it may).
    func timeToReduceFurther(now: Int64, throughput: Double, applicationLimited: Bool = false) -> Bool {
        let interval = Swift.min(Swift.max(roundTrip, 10_000), 200_000)
        if let lastChange, now - lastChange < interval { return !applicationLimited && throughput < 0.5 * current }
        return true
    }

    /// `applicationLimited`: the encoder sends well below the estimate (a still screen), so what gets through says
    /// nothing about the link, and cutting the estimate wouldn't drain anything (the trickle is all there is). Overuse
    /// then, most often a keyframe's own burst, gets one step down from the estimate itself (×0.85) per spell, instead
    /// of a cut to a fraction of the trickle: a still screen that starts to scroll still has the bitrate it had. If the
    /// link really did get slower, the first busy moment shows it, and the usual cut to what gets through applies; the
    /// congestion window holds the burst meanwhile.
    mutating func update(usage: BandwidthUsage, throughput: Double?, now: Int64, applicationLimited: Bool = false) -> Double {
        let measured = throughput ?? latestThroughput ?? current
        if let throughput { latestThroughput = throughput }
        switch usage {
        case .normal:
            if state == .hold {
                lastChange = now
                state = .increase
            }
        case .overusing:
            state = .decrease
        case .underusing:
            state = .hold
        }
        if usage != .overusing { limitedCutThisSpell = false }
        var next: Double?
        switch state {
        case .hold:
            break
        case .increase:
            if measured > capacity.upperBound { capacity.reset() }
            // Never run far ahead of what's actually getting through (an encoder sending less than allowed).
            let limit = 1.5 * measured + 10_000
            if current < limit {
                let step = capacity.estimate != nil ? additiveIncrease(now: now) : multiplicativeIncrease(now: now)
                next = Swift.min(current + step, limit)
            }
            lastChange = now
        case .decrease:
            if applicationLimited {
                if !limitedCutThisSpell { next = current * Self.beta }
                limitedCutThisSpell = true
            } else {
                // A little below what got through, to drain the queue it built.
                var decreased = measured * Self.beta
                if decreased > current, let link = capacity.estimate { decreased = Self.beta * link }
                if decreased < current { next = decreased }
                if measured < capacity.lowerBound { capacity.reset() }
                capacity.onOveruse(measured)
            }
            state = .hold
            lastChange = now
        }
        current = clamp(next ?? current)
        return current
    }

    /// 8% a second while the capacity is unknown.
    private func multiplicativeIncrease(now: Int64) -> Double {
        var alpha = 1.08
        if let lastChange { alpha = pow(1.08, Swift.min(Double(now - lastChange) / 1e6, 1)) }
        return Swift.max(current * (alpha - 1), 1000)
    }

    /// About one packet per response time (round trip + 100 ms) near the known capacity.
    private func additiveIncrease(now: Int64) -> Double {
        guard let lastChange else { return 0 }
        let frameBits = current / 30
        let packetsPerFrame = Swift.max((frameBits / (1200 * 8)).rounded(.up), 1)
        let responseTime = Double(roundTrip + 100_000) / 1e6
        let perSecond = Swift.max(4000, frameBits / packetsPerFrame / responseTime)
        return perSecond * Double(now - lastChange) / 1e6
    }

    private func clamp(_ bitrate: Double) -> Double { Swift.min(Swift.max(bitrate, minBitrate), maxBitrate) }
}

// MARK: Throughput

/// What the phone received over the last quarter second, by its arrival times: during overuse while busy, that's what
/// the bottleneck carries. The acknowledged bitrate below smooths so much that after a jump (a still screen that starts
/// to move) it lags by seconds; a cut taken from it alone would land at a fraction of the link.
nonisolated struct DeliveryRate: Sendable {
    static let span: Int64 = 250_000
    /// Too few arrivals to tell a rate from.
    static let shortest: Int64 = 50_000

    private var samples: [(arrival: Int64, size: Int)] = []
    private var head = 0
    private var bytes = 0

    mutating func add(arrival: Int64, size: Int) {
        samples.append((arrival, size))
        bytes += size
        while head < samples.count, arrival - samples[head].arrival > Self.span {
            bytes -= samples[head].size
            head += 1
        }
        if head > 1024 {
            samples.removeFirst(head)
            head = 0
        }
    }

    /// bits per second over the window: the bytes after the first arrival, over the time since it.
    var rate: Double? {
        guard head < samples.count, let last = samples.last else { return nil }
        let first = samples[head]
        let elapsed = last.arrival - first.arrival
        guard elapsed >= Self.shortest else { return nil }
        return Double(bytes - first.size) * 8e6 / Double(elapsed)
    }
}

/// The rate the phone actually received (WebRTC's BitrateEstimator): 150 ms windows (500 ms for the first) blended
/// into a Bayesian estimate that trusts a sample less the further it is from the estimate.
nonisolated struct AcknowledgedBitrateEstimator: Sendable {
    static let initialWindowMs = 500.0
    static let windowMs = 150.0

    private var sum = 0
    private var windowElapsedMs = 0.0
    private var previousMs: Double?
    private var estimateKbps: Double?
    private var variance = 50.0

    var bitrate: Double? { estimateKbps.map { $0 * 1000 } }

    mutating func update(arrival: Int64, size: Int, inAlr: Bool) {
        let nowMs = Double(arrival) / 1000
        let window = estimateKbps == nil ? Self.initialWindowMs : Self.windowMs
        guard let sample = updateWindow(nowMs: nowMs, bytes: size, windowMs: window) else { return }
        guard let estimate = estimateKbps else {
            estimateKbps = sample
            return
        }
        // Samples below the estimate while the sender is app-limited say little about capacity.
        let scale = inAlr && sample < estimate ? 20.0 : 10.0
        let uncertainty = scale * abs(estimate - sample) / max(estimate, 1)
        let sampleVariance = uncertainty * uncertainty
        let predicted = variance + 5
        estimateKbps = (sampleVariance * estimate + predicted * sample) / (sampleVariance + predicted)
        variance = sampleVariance * predicted / (sampleVariance + predicted)
    }

    private mutating func updateWindow(nowMs: Double, bytes: Int, windowMs: Double) -> Double? {
        if let previousMs, nowMs < previousMs {
            self.previousMs = nil
            sum = 0
            windowElapsedMs = 0
        }
        if let previousMs {
            windowElapsedMs += nowMs - previousMs
            // Nothing for a whole window: start a fresh one.
            if nowMs - previousMs > windowMs {
                sum = 0
                windowElapsedMs = windowElapsedMs.truncatingRemainder(dividingBy: windowMs)
            }
        }
        previousMs = nowMs
        var sample: Double?
        if windowElapsedMs >= windowMs {
            sample = 8 * Double(sum) / windowMs
            windowElapsedMs -= windowMs
            sum = 0
        }
        sum += bytes
        return sample
    }
}

// MARK: Loss-based control

/// WebRTC's classic loss-based controller: below the low threshold the rate may grow 8% over the lowest of the last
/// second; above the high one it drops by half the loss rate, at most once per 300 ms plus a round trip; in between
/// it holds. Never above the delay-based estimate.
nonisolated struct LossBasedControl: Sendable {
    var lowLoss: Double
    var highLoss: Double
    var minBitrate: Double
    var maxBitrate: Double
    var roundTrip: Int64 = 200_000
    private(set) var current: Double
    private(set) var lastLossFraction = 0.0
    private var delayLimit = Double.infinity
    private var expected = 0
    private var lost = 0
    private var haveReport = false
    private var decreasedSinceReport = false
    private var lastDecrease: Int64?
    private var minHistory: [(time: Int64, bitrate: Double)] = []

    init(start: Double, min: Double, max: Double, lowLoss: Double, highLoss: Double) {
        minBitrate = min
        maxBitrate = max
        self.lowLoss = lowLoss
        self.highLoss = highLoss
        current = Swift.min(Swift.max(start, min), max)
    }

    /// Jumps to a rate (a probe's result), dropping the history that would hold it back.
    mutating func setSendBitrate(_ bitrate: Double, now: Int64) {
        delayLimit = .infinity
        setTarget(bitrate)
        minHistory.removeAll()
    }

    mutating func updateDelayLimit(_ bitrate: Double, now: Int64) {
        delayLimit = bitrate
        setTarget(current)
    }

    mutating func onPackets(lost newlyLost: Int, total: Int, now: Int64) {
        guard total > 0 else { return }
        let expected = self.expected + total
        // Decide on at least 20 packets.
        guard expected >= 20 else {
            self.expected = expected
            lost += newlyLost
            return
        }
        lastLossFraction = Double(lost + newlyLost) / Double(expected)
        self.expected = 0
        lost = 0
        haveReport = true
        decreasedSinceReport = false
        updateEstimate(now: now)
    }

    private mutating func updateEstimate(now: Int64) {
        updateMinHistory(now: now)
        guard haveReport else { return }
        if lastLossFraction <= lowLoss {
            setTarget((minHistory.first?.bitrate ?? current) * 1.08 + 1000)
        } else if lastLossFraction > highLoss, !decreasedSinceReport,
                  lastDecrease.map({ now - $0 >= 300_000 + roundTrip }) ?? true {
            lastDecrease = now
            decreasedSinceReport = true
            setTarget(current * (1 - 0.5 * lastLossFraction))
        } else {
            setTarget(current)
        }
    }

    private mutating func updateMinHistory(now: Int64) {
        while let first = minHistory.first, now - first.time + 1000 > 1_000_000 { minHistory.removeFirst() }
        while let last = minHistory.last, current <= last.bitrate { minHistory.removeLast() }
        minHistory.append((now, current))
    }

    private mutating func setTarget(_ bitrate: Double) {
        current = Swift.max(Swift.min(bitrate, delayLimit, maxBitrate), minBitrate)
    }
}

// MARK: Probing

/// A burst of padding at a set rate; how fast it arrives says whether the path can carry that rate.
nonisolated public struct ProbeCluster: Sendable, Equatable {
    public var id: UInt16
    public var bitrate: Int
    public var minPackets: Int
    public var minBytes: Int

    /// 15 ms worth at the rate, at least five full packets.
    public init(id: UInt16, bitrate: Int) {
        self.id = id
        self.bitrate = bitrate
        minPackets = 5
        minBytes = max(bitrate * 15 / 8000, 5 * TransportWire.maxDatagramSize)
    }
}

/// A probe cluster's delivered rate, once 80% of it is back (WebRTC's ProbeBitrateEstimator): if it arrived clearly
/// slower than it was sent, the path's capacity is about the arrival rate.
nonisolated struct ProbeBitrateEstimator: Sendable {
    nonisolated struct Cluster: Sendable {
        var firstSend = Int64.max
        var lastSend = Int64.min
        var firstArrival = Int64.max
        var lastArrival = Int64.min
        var sizeLastSend = 0
        var sizeFirstArrival = 0
        var total = 0
        var packets = 0
    }

    private var clusters: [UInt16: Cluster] = [:]
    private var estimate: Double?

    mutating func add(_ result: PacketResult, spec: ProbeCluster) {
        guard let arrival = result.arrival, let id = result.probeCluster else { return }
        var cluster = clusters[id] ?? Cluster()
        if result.sendTime < cluster.firstSend { cluster.firstSend = result.sendTime }
        if result.sendTime > cluster.lastSend {
            cluster.lastSend = result.sendTime
            cluster.sizeLastSend = result.size
        }
        if arrival < cluster.firstArrival {
            cluster.firstArrival = arrival
            cluster.sizeFirstArrival = result.size
        }
        if arrival > cluster.lastArrival { cluster.lastArrival = arrival }
        cluster.total += result.size
        cluster.packets += 1
        clusters[id] = cluster
        if clusters.count > 16, let oldest = clusters.keys.min(by: { SerialNumber.isBefore($0, $1) }) {
            clusters[oldest] = nil
        }
        guard Double(cluster.packets) >= Double(spec.minPackets) * 0.8,
              Double(cluster.total) >= Double(spec.minBytes) * 0.8 else { return }
        let sendInterval = cluster.lastSend - cluster.firstSend
        let receiveInterval = cluster.lastArrival - cluster.firstArrival
        guard sendInterval > 0, sendInterval <= 1_000_000, receiveInterval > 0, receiveInterval <= 1_000_000 else { return }
        // The last packet sent and the first received don't span an interval of their own.
        let sendRate = Double(cluster.total - cluster.sizeLastSend) * 8e6 / Double(sendInterval)
        let receiveRate = Double(cluster.total - cluster.sizeFirstArrival) * 8e6 / Double(receiveInterval)
        guard receiveRate <= 2 * sendRate else { return }
        estimate = receiveRate < 0.9 * sendRate ? 0.95 * receiveRate : min(sendRate, receiveRate)
    }

    mutating func takeEstimate() -> Double? {
        defer { estimate = nil }
        return estimate
    }
}

/// When to probe: at the start, at 3× and 6× the starting rate and then at twice whatever the path carried while it
/// keeps carrying more; and every 5 s while the encoder sends less than allowed (an idle screen), at twice the
/// estimate, so the estimate stays honest for the next burst of motion.
nonisolated struct ProbeController: Sendable {
    static let firstScale = 3.0
    static let secondScale = 6.0
    static let furtherScale = 2.0
    static let furtherThreshold = 0.7
    static let waitingTimeout: Int64 = 1_000_000
    static let alrInterval: Int64 = 5_000_000

    var maxBitrate: Double
    private var nextID: UInt16 = 1
    private var queued: [ProbeCluster] = []
    private var specs: [UInt16: ProbeCluster] = [:]
    /// While exponential probing: the rate a result must beat to probe further, and since when.
    private var probeFurtherAbove: Double?
    private var waitingSince: Int64?
    private var lastProbe: Int64?

    init(maxBitrate: Double) {
        self.maxBitrate = maxBitrate
    }

    mutating func startExponentialProbing(from bitrate: Double, now: Int64) {
        probe([bitrate * Self.firstScale, bitrate * Self.secondScale], current: bitrate, now: now)
    }

    /// After each estimate: probe higher while the last probe was mostly carried.
    mutating func onEstimate(_ bitrate: Double, now: Int64) {
        if let since = waitingSince, now - since > Self.waitingTimeout {
            waitingSince = nil
            probeFurtherAbove = nil
        }
        if let threshold = probeFurtherAbove, bitrate > threshold {
            probeFurtherAbove = nil
            probe([bitrate * Self.furtherScale], current: bitrate, now: now)
        }
    }

    /// While the encoder sends well under the estimate, probe every 5 s; a probe the link carries is followed by one
    /// at twice the rate (as at the start), so an estimate that sank during a still spell is back near the link's
    /// rate within a second or so, before the screen moves.
    mutating func onApplicationLimited(_ limited: Bool, estimate: Double, now: Int64) {
        guard limited, waitingSince == nil, queued.isEmpty,
              lastProbe.map({ now - $0 >= Self.alrInterval }) ?? true else { return }
        probe([estimate * Self.furtherScale], current: estimate, now: now)
    }

    mutating func next() -> ProbeCluster? {
        queued.isEmpty ? nil : queued.removeFirst()
    }

    func spec(_ id: UInt16) -> ProbeCluster? { specs[id] }

    private mutating func probe(_ rates: [Double], current: Double, now: Int64) {
        // A probe capped at the profile's ceiling has nowhere further to go.
        let reachesCeiling = rates.contains { $0 >= maxBitrate }
        let rates = rates.map { min($0, maxBitrate) }.filter { $0 > current * 1.05 }
        guard let highest = rates.max() else {
            waitingSince = nil
            probeFurtherAbove = nil
            return
        }
        for rate in rates {
            let cluster = ProbeCluster(id: nextID, bitrate: Int(rate))
            nextID = nextID == UInt16.max ? 1 : nextID + 1
            queued.append(cluster)
            specs[cluster.id] = cluster
        }
        if specs.count > 32, let oldest = specs.keys.min(by: { SerialNumber.isBefore($0, $1) }) { specs[oldest] = nil }
        lastProbe = now
        waitingSince = now
        probeFurtherAbove = reachesCeiling ? nil : highest * Self.furtherThreshold
    }
}

/// Whether the sender is application-limited: sending clearly less than allowed over the last half second (an idle
/// screen), with hysteresis.
nonisolated struct ApplicationLimitDetector: Sendable {
    static let window: Int64 = 500_000

    private(set) var limited = false
    private var sent: [(time: Int64, bytes: Int)] = []
    private var head = 0
    private var bytes = 0

    mutating func onSent(_ size: Int, now: Int64) {
        sent.append((now, size))
        bytes += size
        trim(now: now)
    }

    mutating func update(target: Double, now: Int64) -> Bool {
        trim(now: now)
        let rate = Double(bytes) * 8e6 / Double(Self.window)
        if limited {
            if rate > 0.85 * target { limited = false }
        } else if rate < 0.65 * target {
            limited = true
        }
        return limited
    }

    private mutating func trim(now: Int64) {
        while head < sent.count, now - sent[head].time > Self.window {
            bytes -= sent[head].bytes
            head += 1
        }
        if head > 1024 {
            sent.removeFirst(head)
            head = 0
        }
    }
}

// MARK: The controller

/// Everything above, for one stream: feed it what was sent and the phone's feedback, read the target and pacing rates.
nonisolated public final class CongestionController {
    nonisolated public struct Settings: Sendable, Equatable {
        public var minBitrate: Int
        public var startBitrate: Int
        public var maxBitrate: Int
        public var lossLow: Double
        public var lossHigh: Double
        /// Pacing runs this much faster than the target, so a frame leaves in a fraction of its interval.
        public var pacingFactor = 2.5
        public var probing = true

        public init(minBitrate: Int, startBitrate: Int, maxBitrate: Int, lossLow: Double, lossHigh: Double) {
            self.minBitrate = minBitrate
            self.startBitrate = startBitrate
            self.maxBitrate = maxBitrate
            self.lossLow = lossLow
            self.lossHigh = lossHigh
        }

        public init(profile: PathProfile) {
            self.init(minBitrate: profile.minBitrate, startBitrate: profile.startBitrate, maxBitrate: profile.maxBitrate,
                      lossLow: profile.lossLow, lossHigh: profile.lossHigh)
        }
    }

    public private(set) var settings: Settings
    /// Everything the hub may send per second.
    public private(set) var targetBitrate: Int
    public private(set) var usage: BandwidthUsage = .normal
    /// The share of packets lost, smoothed over the last second or so of feedback.
    public private(set) var lossRate = 0.0
    public private(set) var acknowledgedBitrate: Int?
    public private(set) var applicationLimited = false
    /// The sender refused frames since the last report (or is over its window): its rate then says nothing about the
    /// encoder, so `applicationLimited` keeps the value it had. A keyframe on a still screen stays a still screen's
    /// burst; a sender that was filling its target when the link slowed stays one that was.
    private var heldBackLately = false
    /// A probe result not yet used (it came during an overuse), and the last cut made before any throughput was known.
    private var pendingProbe: Double?
    private var delivery = DeliveryRate()
    private var lastBlindCut: Int64?
    static let blindCutInterval: Int64 = 200_000
    /// The trendline's smoothed accumulated delay (ms) and threshold, for diagnostics.
    public var delayTrend: (modified: Double, threshold: Double) { (trendline.modifiedTrend, trendline.threshold) }

    private var interArrival = InterArrival()
    private var trendline = TrendlineEstimator()
    private var aimd: AimdRateControl
    private var acknowledged = AcknowledgedBitrateEstimator()
    private var lossControl: LossBasedControl
    private var probes: ProbeController
    private var probeEstimator = ProbeBitrateEstimator()
    private var limitDetector = ApplicationLimitDetector()

    public init(settings: Settings) {
        self.settings = settings
        let start = Double(settings.startBitrate)
        aimd = AimdRateControl(start: start, min: Double(settings.minBitrate), max: Double(settings.maxBitrate))
        lossControl = LossBasedControl(start: start, min: Double(settings.minBitrate), max: Double(settings.maxBitrate),
                                       lowLoss: settings.lossLow, highLoss: settings.lossHigh)
        probes = ProbeController(maxBitrate: Double(settings.maxBitrate))
        targetBitrate = Int(lossControl.current)
    }

    public var pacingRate: Int { Int(Double(targetBitrate) * settings.pacingFactor) }

    /// The delay-based estimate on its own.
    public var delayBasedBitrate: Int { Int(aimd.current) }

    public func setRoundTrip(_ roundTrip: Int64) {
        aimd.roundTrip = roundTrip
        lossControl.roundTrip = roundTrip
    }

    /// Probes up from the current target (at the start, and when the path changes to a faster one).
    public func startProbing(now: Int64) {
        guard settings.probing else { return }
        probes.startExponentialProbing(from: Double(targetBitrate), now: now)
    }

    /// New bounds and thresholds (the path changed). The delay filters start over: the path's delay jumped.
    public func update(settings: Settings, now: Int64) {
        self.settings = settings
        aimd.minBitrate = Double(settings.minBitrate)
        aimd.maxBitrate = Double(settings.maxBitrate)
        aimd.clampToLimits()
        lossControl.minBitrate = Double(settings.minBitrate)
        lossControl.maxBitrate = Double(settings.maxBitrate)
        lossControl.lowLoss = settings.lossLow
        lossControl.highLoss = settings.lossHigh
        lossControl.updateDelayLimit(aimd.current, now: now)
        probes.maxBitrate = Double(settings.maxBitrate)
        interArrival.reset()
        trendline = TrendlineEstimator()
        targetBitrate = Int(lossControl.current)
    }

    /// Media sent (not probes), for telling whether the encoder uses what it's allowed.
    public func onSent(size: Int, now: Int64) {
        limitDetector.onSent(size, now: now)
    }

    /// A probe cluster to send now, if one is due.
    public func takeProbe(now: Int64) -> ProbeCluster? {
        if !heldBackLately { applicationLimited = limitDetector.update(target: Double(targetBitrate), now: now) }
        if settings.probing { probes.onApplicationLimited(applicationLimited, estimate: Double(targetBitrate), now: now) }
        return probes.next()
    }

    /// `standingQueue`: the sender is still over its congestion window after this report. A full buffer's delay stops
    /// changing, which the trendline reads as normal; this treats it as the overuse it is. `heldBack`: the sender
    /// refused frames since the last report, so if it sent less than the target, the network made it, not the
    /// encoder: that isn't application-limited.
    public func onFeedback(_ results: [PacketResult], now: Int64, standingQueue: Bool = false, heldBack: Bool = false) {
        guard !results.isEmpty else { return }
        heldBackLately = heldBack || standingQueue
        let lost = results.reduce(0) { $0 + ($1.arrival == nil ? 1 : 0) }
        lossControl.onPackets(lost: lost, total: results.count, now: now)
        // About a second's worth of reports carries the average.
        let weight = min(1, Double(results.count) / 400)
        lossRate += (Double(lost) / Double(results.count) - lossRate) * weight

        if !heldBackLately { applicationLimited = limitDetector.update(target: Double(targetBitrate), now: now) }
        let received = results.compactMap { result in result.arrival.map { (result, $0) } }.sorted { $0.1 < $1.1 }
        for (result, arrival) in received {
            acknowledged.update(arrival: arrival, size: result.size, inAlr: applicationLimited)
            delivery.add(arrival: arrival, size: result.size)
            if let cluster = result.probeCluster, let spec = probes.spec(cluster) { probeEstimator.add(result, spec: spec) }
            if let delta = interArrival.add(send: result.sendTime, arrival: arrival, size: result.size) {
                trendline.update(arrivalDeltaMs: Double(delta.arrival) / 1000, sendDeltaMs: Double(delta.send) / 1000,
                                 arrivalMs: Double(arrival) / 1000)
            }
        }
        usage = standingQueue ? .overusing : trendline.state
        let throughput = acknowledged.bitrate
        acknowledgedBitrate = throughput.map { Int($0) }
        // A probe's measurement is kept through an overuse (often the probe's own burst) and used once it's over.
        if let fresh = probeEstimator.takeEstimate() { pendingProbe = fresh }
        let probe = usage == .overusing ? nil : pendingProbe
        if probe != nil { pendingProbe = nil }

        var probed = false
        if usage == .overusing {
            if let throughput {
                // What gets through now, if the smoothed figure hasn't caught up with it yet.
                let measured = max(throughput, delivery.rate ?? 0)
                if aimd.timeToReduceFurther(now: now, throughput: measured, applicationLimited: applicationLimited) {
                    _ = aimd.update(usage: .overusing, throughput: measured, now: now,
                                    applicationLimited: applicationLimited)
                }
            } else if lastBlindCut.map({ now - $0 >= Self.blindCutInterval }) ?? true {
                // Overuse before anything was measured (as WebRTC): halve, at most every 200 ms.
                lastBlindCut = now
                aimd.setEstimate(aimd.current / 2, now: now)
            }
        } else if let probe, probe > aimd.current {
            aimd.setEstimate(probe, now: now)
            probed = true
        } else {
            _ = aimd.update(usage: usage, throughput: throughput, now: now)
        }
        if probed { lossControl.setSendBitrate(aimd.current, now: now) }
        lossControl.updateDelayLimit(aimd.current, now: now)
        targetBitrate = Int(lossControl.current)
        if settings.probing { probes.onEstimate(Double(targetBitrate), now: now) }
    }
}
