import Foundation

/// What the video encoder should produce: the transport's target less sound, parity and packet headers, and the
/// path's frame-rate cap.
nonisolated public struct EncoderTarget: Sendable, Equatable {
    public var videoBitrate: Int
    public var maxFramesPerSecond: Int
    /// Everything the hub may send per second (picture, sound, resends, parity, headers).
    public var totalBitrate: Int
    public var path: PathKind
    public var fecRatio: Double
}

nonisolated public enum VideoDropReason: String, Sendable, Equatable {
    /// The picture backlog was over the profile's limit: the encoder's next frame must be a refresh frame.
    case queueFull
    /// An earlier frame was dropped and this one isn't a refresh frame.
    case awaitingRefresh
    /// The network holds more than the congestion window: wait for `hasRoom`, then send a refresh frame.
    case congested
    /// No phone has said hello yet.
    case notConnected
    /// Empty, or larger than a frame can be.
    case tooLarge
}

nonisolated public enum VideoAdmission: Sendable, Equatable {
    case sent(frameID: UInt32)
    case dropped(VideoDropReason)
}

nonisolated public enum SenderEvent: Sendable, Equatable {
    /// The phone said hello, first or from a new network: the socket now sends to the address it came from.
    case hello(TransportHello)
    /// A new bitrate or frame rate for the encoder.
    case encoderTarget(EncoderTarget)
    case appMessage(AppMessage)
    /// Nothing authenticated came from the phone for `Settings.silenceTimeout` (it sends reports every 25–40 ms):
    /// the path is gone, or one way of it is. Reported once; the app falls back to the WebSocket.
    case silent
}

nonisolated public struct SenderStats: Sendable, Equatable {
    public var packetsSent = 0
    public var bytesSent = 0
    public var framesSent = 0
    public var framesDropped = 0
    public var parityPackets = 0
    public var retransmissions = 0
    public var nacksReceived = 0
    public var feedbackReceived = 0
    public var packetsReceived = 0
    public var rejected: [PacketRejection: Int] = [:]
}

/// Datagrams to send now and what happened.
nonisolated public struct TransportOutput<Event: Sendable>: Sendable {
    public var datagrams: [Data] = []
    public var events: [Event] = []
}

/// The hub's end of one phone's UDP session, without sockets: frames and sound in, sealed datagrams out at the pace
/// the path allows, the phone's hellos, resend requests and arrival reports in. Time is passed in (µs), so the
/// socket layer drives it with the clock and the tests with a simulated one. Not thread-safe: one queue owns it.
nonisolated public final class MediaSender {
    nonisolated public struct Settings: Sendable {
        /// Something goes to the phone at least this often while streaming (its Wi-Fi dozes otherwise).
        public var keepaliveInterval: Int64 = 20_000
        /// The report (round trip, deadline, newest piece sent) goes at least this often.
        public var reportInterval: Int64 = 100_000
        /// How long the phone may stay quiet before the session reports `.silent`.
        public var silenceTimeout: Int64 = 3_000_000

        public init() {}
    }

    public let sessionID: UInt32
    public let settings: Settings
    public private(set) var profile: PathProfile
    public private(set) var network: PhoneNetwork = .other
    public private(set) var plan: RecoveryPlan
    public private(set) var isConnected = false
    /// The phone's hello asked for pictures. A session for sound alone never probes for bandwidth it won't use.
    public private(set) var carriesVideo = true
    /// When the last authenticated packet from the phone arrived.
    public private(set) var lastHeard: Int64?
    /// `.silent` went out for the current quiet spell.
    private var reportedSilence = false
    /// Smoothed, from the arrival reports.
    public private(set) var roundTrip: Int64?
    public private(set) var stats = SenderStats()

    private var sealer: PacketSealer
    private var opener: PacketOpener
    private var packetizer = VideoPacketizer(stream: 0)
    private var audio: AudioPacketizer
    private let pacer: Pacer
    private let congestion: CongestionController
    private var history = SentPacketHistory()
    private var retransmits = RetransmitBuffer()
    private var lastSend: Int64?
    private var lastReport: Int64?
    private var lastAudio: Int64?
    private var announced: EncoderTarget?
    private var lastSentVideoSequence: UInt32?
    private var lastSentFrameID: UInt32?
    private var lastSentAudioSequence: UInt32?
    /// Parity bytes per picture byte, as sent (small frames get proportionally more).
    private var parityShare: Double
    /// The newest packet number the phone's reports have covered.
    private var highestReported: UInt64 = 0
    /// The round trip without queuing: the smallest in the last 10–20 s.
    private var baseRoundTrip = WindowedMinimum(window: 10_000_000)
    /// Resent bytes over the last second, which the encoder's share leaves room for.
    private var resent = ByteWindow(span: 1_000_000)
    /// Since when reports have found the sender over its congestion window.
    private var overWindowSince: Int64?
    /// A frame was refused for the congestion window since the last report.
    private var refusedForWindow = false
    /// A frame was refused for any reason of the network's (the window, a full queue) since the last report.
    private var heldBack = false

    public init(keys: TransportKeys, profile: PathProfile, settings: Settings = Settings()) {
        sessionID = keys.sessionID
        self.settings = settings
        self.profile = profile
        sealer = PacketSealer(keys: keys, direction: .hubToPhone)
        opener = PacketOpener(keys: keys, direction: .phoneToHub)
        plan = RecoveryPolicy.plan(profile: profile, network: .other, roundTripMs: nil, lossRate: 0)
        congestion = CongestionController(settings: CongestionController.Settings(profile: profile))
        pacer = Pacer(pacingRate: Double(congestion.pacingRate), maxVideoQueueDelay: Int64(profile.videoQueueMs * 1000))
        audio = AudioPacketizer(stream: 1, redundancy: plan.audioRedundancy)
        parityShare = plan.fec.ratio
    }

    public var targetBitrate: Int { congestion.targetBitrate }
    public var pacingRate: Int { congestion.pacingRate }
    public var lossRate: Double { congestion.lossRate }
    public var bandwidthUsage: BandwidthUsage { congestion.usage }
    public var applicationLimited: Bool { congestion.applicationLimited }
    public var acknowledgedBitrate: Int? { congestion.acknowledgedBitrate }
    public var pacerStats: Pacer.Stats { pacer.stats }

    /// Bytes sent that no report has covered yet: roughly what sits in the network.
    public var bytesInFlight: Int {
        // No report yet, or none for thousands of packets: count everything.
        guard highestReported > 0, let reported = history.entry(highestReported) else { return Int(history.totalBytes) }
        return Int(history.totalBytes - reported.cumulativeBytes)
    }

    /// Whether a frame would be taken now: the network isn't over the congestion window and the picture backlog is
    /// within the profile's limit. The encoder waits for this before making the refresh frame a refusal asks for.
    public var hasRoom: Bool {
        bytesInFlight <= congestionWindow && pacer.backlogDelay <= pacer.maxVideoQueueDelay
    }

    /// The most that may be in flight: the target rate's worth of the base round trip, the profile's allowance, and
    /// two report intervals (reports lag by up to one, and a lost one must not look like a full network).
    public var congestionWindow: Int {
        let roundTrip = baseRoundTrip.value ?? Int64(profile.assumedRoundTripMs * 1000)
        let span = Double(roundTrip) / 1e6 + (profile.inFlightAllowanceMs + 2 * profile.feedbackIntervalMs) / 1000
        return max(Int(Double(congestion.targetBitrate) / 8 * span), 16_000)
    }

    /// µs for a frame of this many bytes to reach the phone and its feedback to come back: what's queued ahead of it
    /// and the frame itself at the pacing rate, plus a round trip. A keyframe on a slow path takes much longer than a
    /// refresh, and whoever waits for the phone to show it should wait that long.
    public func deliveryTime(bytes: Int) -> Int64 {
        pacer.queueDelay + Int64(Double(bytes) * 8e6 / Double(max(congestion.pacingRate, 1))) + currentRoundTrip
    }

    /// What the encoder should aim for now.
    public var encoderTarget: EncoderTarget {
        let total = Double(congestion.targetBitrate)
        // Sound with its copies, plus ≈52 bytes of headers per 10 ms packet, while sound is flowing.
        let audioRate = lastAudio == nil ? 0 : Double(profile.opusBitrate * (1 + plan.audioRedundancy)) + 41_600
        let available = max(total - audioRate - resent.bitrate, total / 2)
        let payloadShare = Double(VideoFragment.maxPayloadSize) / Double(TransportWire.maxDatagramSize)
        let video = available * payloadShare / (1 + max(parityShare, plan.fec.ratio))
        return EncoderTarget(videoBitrate: max(Int(video), 100_000), maxFramesPerSecond: profile.maxFramesPerSecond,
                             totalBitrate: Int(total), path: profile.path, fecRatio: plan.fec.ratio)
    }

    // MARK: From the app

    /// Queues an encoded frame (a `VideoFrameMessage`'s bytes), or refuses it before any of it goes out. After a
    /// refusal the encoder's next frame must be a refresh frame (an LTR refresh or a keyframe).
    public func sendVideo(_ frame: Data, refresh: Bool, now: Int64) -> VideoAdmission {
        guard isConnected else { return .dropped(.notConnected) }
        pacer.windowOpen = bytesInFlight <= congestionWindow
        if case .dropped(let reason) = pacer.admitFrame(refresh: refresh, now: now) {
            stats.framesDropped += 1
            if reason != .awaitingRefresh { heldBack = true }
            switch reason {
            case .queueFull: return .dropped(.queueFull)
            case .awaitingRefresh: return .dropped(.awaitingRefresh)
            case .congested:
                refusedForWindow = true
                return .dropped(.congested)
            }
        }
        guard let packetized = packetizer.packetize(frame, refresh: refresh, fec: plan.fec) else {
            stats.framesDropped += 1
            return .dropped(.tooLarge)
        }
        // The phone waits for a frame while its pieces keep coming, and gives up a deadline after the last one: so a
        // piece is worth sending until what's queued ahead of it and the frame itself have gone out at the pacing rate,
        // plus that deadline and the trip there. (At a low rate a keyframe takes longer to send than the deadline; an
        // expiry that ignored that would cut its tail off, and the next keyframe's, over and over.)
        let sending = Int64(Double(frame.count + packetized.parityBytes) * 8e6 / Double(max(congestion.pacingRate, 1)))
        let expires = now + pacer.queueDelay + sending + plan.frameDeadline + currentRoundTrip / 2
        let messages = packetized.fragments.map(TransportMessage.video) + packetized.parity.map(TransportMessage.parity)
        pacer.enqueueFrame(messages, frameID: packetized.frameID, refresh: refresh, expires: expires, now: now)
        stats.framesSent += 1
        stats.parityPackets += packetized.parity.count
        parityShare += (Double(packetized.parityBytes) / Double(frame.count) - parityShare) * 0.05
        return .sent(frameID: packetized.frameID)
    }

    /// Queues one Opus frame; it goes out at once, never behind pictures. `timestamp` is its media time (µs on the
    /// Mac's host clock), `duration` its length in µs.
    public func sendAudio(_ frame: Data, timestamp: UInt64, duration: UInt16, now: Int64) {
        guard isConnected, let bundle = audio.packetize(frame, timestamp: timestamp, duration: duration) else { return }
        pacer.enqueue(.audio(bundle), priority: .audio, now: now)
        lastAudio = now
    }

    /// Queues a small app message (the pointer's position...); false before the phone said hello.
    @discardableResult
    public func sendAppMessage(_ message: AppMessage, now: Int64) throws -> Bool {
        guard message.data.count <= AppMessage.maxDataSize else { throw TransportError.tooLarge }
        guard isConnected else { return false }
        pacer.enqueue(.app(message), priority: .control, now: now)
        return true
    }

    /// How Tailscale reaches the phone changed: new bounds, buffers and protection; probes up when the new path is
    /// faster.
    public func setPath(_ path: PathKind, now: Int64) {
        guard path != profile.path else { return }
        let next = PathProfile.profile(for: path)
        let faster = next.maxBitrate > profile.maxBitrate
        profile = next
        congestion.update(settings: CongestionController.Settings(profile: next), now: now)
        pacer.maxVideoQueueDelay = Int64(next.videoQueueMs * 1000)
        replan()
        if faster, isConnected, carriesVideo { congestion.startProbing(now: now) }
    }

    // MARK: From the phone

    public func receive(_ datagram: Data, now: Int64) -> [SenderEvent] {
        let packet: TransportPacket
        switch opener.open(datagram) {
        case .success(let opened):
            packet = opened
        case .failure(let rejection):
            stats.rejected[rejection, default: 0] += 1
            return []
        }
        stats.packetsReceived += 1
        lastHeard = now
        reportedSilence = false
        switch packet.message {
        case .hello(let hello):
            return handleHello(hello, now: now)
        case .nack(let nack):
            handleNack(nack, now: now)
        case .feedback(let feedback):
            handleFeedback(feedback, phoneTime: packet.sendTime, now: now)
        case .app(let message):
            return [.appMessage(message)]
        default:
            // The phone's keepalives only keep the path awake; nothing else comes this way.
            break
        }
        return []
    }

    private func handleHello(_ hello: TransportHello, now: Int64) -> [SenderEvent] {
        let first = !isConnected
        isConnected = true
        carriesVideo = hello.wantsVideo
        let moved = !first && hello.network != network
        if hello.network != network {
            network = hello.network
            replan()
        }
        if moved {
            // A new network: its delay has nothing to do with the old one's, so the delay filters start over.
            congestion.update(settings: CongestionController.Settings(profile: profile), now: now)
        }
        pacer.enqueue(.helloAck(TransportHelloAck(nonce: hello.nonce, report: report())), priority: .control, now: now)
        if first || moved, carriesVideo { congestion.startProbing(now: now) }
        return [.hello(hello)]
    }

    private func handleNack(_ nack: TransportNack, now: Int64) {
        stats.nacksReceived += 1
        guard plan.nack else { return }
        for resend in retransmits.resends(for: nack.sequences, now: now, roundTrip: currentRoundTrip) {
            pacer.enqueue(.video(resend.fragment), priority: .retransmission, now: now, frameID: resend.fragment.frameID,
                          refresh: resend.fragment.flags.contains(.refresh), expires: resend.deadline)
        }
    }

    private func handleFeedback(_ feedback: TransportFeedback, phoneTime: UInt32, now: Int64) {
        stats.feedbackReceived += 1
        var results: [PacketResult] = []
        results.reserveCapacity(feedback.arrivals.count)
        var newest: (sendTime: Int64, arrival: Int64)?
        for (offset, arrival) in feedback.arrivals.enumerated() {
            guard let sent = history.take(feedback.baseNumber + UInt64(offset)) else { continue }
            results.append(PacketResult(number: sent.number, sendTime: sent.sendTime, size: sent.size, arrival: arrival,
                                        probeCluster: sent.probeCluster))
            if let arrival { newest = (sent.sendTime, arrival) }
        }
        if let newest {
            // The round trip, less the time the phone held the report after the newest packet arrived (both on the
            // phone's clock, so no clock sync is needed).
            let held = Int64(Int32(bitPattern: phoneTime &- UInt32(truncatingIfNeeded: newest.arrival)))
            let sample = now - newest.sendTime - held
            if held >= 0, held < 1_000_000, sample > 0 {
                let smoothed = roundTrip.map { ($0 * 7 + sample) / 8 } ?? sample
                roundTrip = smoothed
                congestion.setRoundTrip(smoothed)
                baseRoundTrip.add(sample, now: now)
            }
        }
        if !feedback.arrivals.isEmpty {
            highestReported = max(highestReported, feedback.baseNumber + UInt64(feedback.arrivals.count - 1))
        }
        // A standing queue: a frame refused for the window since the last report, or over the window for longer than
        // its allowance. The delay filters can't see it (a full buffer's delay stops changing), so it counts as
        // overuse; not before the first throughput measurement, so the start-up burst (keyframe, probes) doesn't.
        if bytesInFlight > congestionWindow {
            overWindowSince = overWindowSince ?? now
        } else {
            overWindowSince = nil
        }
        let over = overWindowSince.map { now - $0 >= Int64(profile.inFlightAllowanceMs * 1000) } ?? false
        let standing = congestion.acknowledgedBitrate != nil && (refusedForWindow || over)
        refusedForWindow = false
        congestion.onFeedback(results, now: now, standingQueue: standing, heldBack: heldBack || over)
        heldBack = false
        replan()
    }

    // MARK: Out

    /// The datagrams due now (paced), and new encoder targets.
    public func poll(now: Int64) -> TransportOutput<SenderEvent> {
        var output = TransportOutput<SenderEvent>()
        guard isConnected else { return output }
        pacer.pacingRate = Double(congestion.pacingRate)
        resent.trim(now: now)
        // One cluster at a time: the next starts once the pacer has sent this one.
        if carriesVideo, !pacer.isProbing, let cluster = congestion.takeProbe(now: now) { pacer.startProbe(cluster, now: now) }
        for item in pacer.poll(now: now) { seal(item.message, probeCluster: item.probeCluster, expires: item.expires, now: now, into: &output.datagrams) }
        let idle = lastSend.map { now - $0 >= settings.keepaliveInterval } ?? true
        let reportDue = lastReport.map { now - $0 >= settings.reportInterval } ?? true
        if idle || reportDue {
            seal(.keepalive(TransportKeepalive(report: report())), probeCluster: nil, expires: nil, now: now,
                 into: &output.datagrams)
            lastReport = now
        }
        retransmits.evict(now: now)
        let target = encoderTarget
        if shouldAnnounce(target) {
            announced = target
            output.events.append(.encoderTarget(target))
        }
        if let lastHeard, now - lastHeard >= settings.silenceTimeout, !reportedSilence {
            reportedSilence = true
            output.events.append(.silent)
        }
        return output
    }

    /// When `poll` next has something to do.
    public func nextWakeup(now: Int64) -> Int64 {
        guard isConnected else { return now + 1_000_000 }
        var next = min((lastSend ?? now) + settings.keepaliveInterval, (lastReport ?? now) + settings.reportInterval)
        if let send = pacer.nextSendTime(now: now) { next = min(next, send) }
        if let lastHeard, !reportedSilence { next = min(next, lastHeard + settings.silenceTimeout) }
        return max(next, now)
    }

    private var currentRoundTrip: Int64 { roundTrip ?? Int64(profile.assumedRoundTripMs * 1000) }

    private func seal(_ message: TransportMessage, probeCluster: UInt16?, expires: Int64?, now: Int64, into datagrams: inout [Data]) {
        guard let sealed = try? sealer.seal(message, sendTime: TransportClock.wire(now)) else { return }
        let size = sealed.datagram.count
        history.record(number: sealed.number, sendTime: now, size: size, probeCluster: probeCluster)
        if probeCluster == nil { congestion.onSent(size: size, now: now) }
        switch message {
        case .video(let fragment):
            if fragment.flags.contains(.retransmission) {
                stats.retransmissions += 1
                resent.add(size, now: now)
            } else {
                retransmits.store(fragment, sentAt: now, deadline: expires ?? now + plan.frameDeadline)
                if lastSentVideoSequence.map({ SerialNumber.isBefore($0, fragment.sequence) }) ?? true {
                    lastSentVideoSequence = fragment.sequence
                }
                if lastSentFrameID.map({ SerialNumber.isBefore($0, fragment.frameID) }) ?? true {
                    lastSentFrameID = fragment.frameID
                }
            }
        case .audio(let bundle):
            lastSentAudioSequence = bundle.sequence
        default:
            break
        }
        stats.packetsSent += 1
        stats.bytesSent += size
        datagrams.append(sealed.datagram)
        lastSend = now
    }

    private func report() -> SenderReport {
        SenderReport(path: profile.path, nack: plan.nack, roundTripMicros: UInt32(clamping: roundTrip ?? 0),
                     frameDeadlineMicros: UInt32(clamping: plan.frameDeadline),
                     targetBitrate: UInt32(clamping: congestion.targetBitrate),
                     lastVideoSequence: lastSentVideoSequence, lastFrameID: lastSentFrameID,
                     lastAudioSequence: lastSentAudioSequence)
    }

    private func replan() {
        plan = RecoveryPolicy.plan(profile: profile, network: network, roundTripMs: roundTrip.map { Double($0) / 1000 },
                                   lossRate: congestion.lossRate)
        audio.redundancy = plan.audioRedundancy
    }

    /// Up 5%, down 2%, or a new path, frame rate or parity ratio.
    private func shouldAnnounce(_ target: EncoderTarget) -> Bool {
        guard let last = announced else { return true }
        if last.path != target.path || last.maxFramesPerSecond != target.maxFramesPerSecond
            || abs(last.fecRatio - target.fecRatio) > 0.001 { return true }
        let change = Double(target.videoBitrate - last.videoBitrate) / Double(max(last.videoBitrate, 1))
        return change >= 0.05 || change <= -0.02
    }
}

/// The smallest value seen in the current and the previous window.
nonisolated struct WindowedMinimum: Sendable {
    let window: Int64
    private var current: (value: Int64, since: Int64)?
    private var previous: Int64?

    init(window: Int64) {
        self.window = window
    }

    var value: Int64? {
        guard let current else { return previous }
        return min(current.value, previous ?? current.value)
    }

    mutating func add(_ value: Int64, now: Int64) {
        guard let current, now - current.since < window else {
            previous = self.current?.value
            self.current = (value, now)
            return
        }
        self.current = (min(current.value, value), current.since)
    }
}

/// Bytes over a sliding span, as a bitrate.
nonisolated struct ByteWindow: Sendable {
    let span: Int64
    private var samples: [(time: Int64, bytes: Int)] = []
    private var head = 0
    private var total = 0

    init(span: Int64) {
        self.span = span
    }

    var bitrate: Double { Double(total) * 8e6 / Double(span) }

    mutating func add(_ bytes: Int, now: Int64) {
        samples.append((now, bytes))
        total += bytes
    }

    mutating func trim(now: Int64) {
        while head < samples.count, now - samples[head].time > span {
            total -= samples[head].bytes
            head += 1
        }
        if head > 1024 {
            samples.removeFirst(head)
            head = 0
        }
    }
}
