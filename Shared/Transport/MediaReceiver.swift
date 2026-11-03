import Foundation

nonisolated public enum ReceiverEvent: Sendable, Equatable {
    /// The hub answered (or its stream arrived): the UDP path works. The round trip is the hello's, 0 if unknown.
    case connected(roundTrip: Int64, path: PathKind)
    case frame(FrameAssembler.AssembledFrame)
    /// A frame was given up: ask for a refresh (`ScreenFeedback.refresh`) while `awaitingRefresh` holds.
    case frameLost(frameID: UInt32)
    case frameSkipped(frameID: UInt32)
    /// New sound frames, oldest first (some may be copies that stand in for lost packets).
    case audio([ReceivedAudioFrame])
    case appMessage(AppMessage)
    /// The hub's path, resend setting or deadline changed.
    case report(SenderReport)
    /// The hub's clock against this phone's (`MediaReceiver.hubClockOffset`): when it changes, and at least once a
    /// second while reports come. Video frames carry it too; sound has no frame to, and needs it for the sync rule.
    case clock(hubClockOffset: UInt32)
}

nonisolated public struct ReceiverStats: Sendable, Equatable {
    public var packetsReceived = 0
    public var bytesReceived = 0
    public var videoPackets = 0
    public var parityPackets = 0
    public var audioPackets = 0
    public var probePackets = 0
    public var retransmissionsReceived = 0
    public var fecRecovered = 0
    public var framesDelivered = 0
    public var framesLost = 0
    public var framesSkipped = 0
    public var audioFrames = 0
    public var audioFramesFromRedundancy = 0
    public var nackPacketsSent = 0
    public var feedbackSent = 0
    public var rejected: [PacketRejection: Int] = [:]
}

/// The phone's end of the UDP session, without sockets: says hello (and again after a network change), opens the
/// hub's packets, puts pictures back together, unpacks sound, and sends arrival reports, resend requests and
/// keepalives. Time is passed in (µs). Not thread-safe: one queue owns it.
nonisolated public final class MediaReceiver {
    nonisolated public struct Settings: Sendable {
        /// Something goes to the hub at least this often (the arrival reports usually do it).
        public var keepaliveInterval: Int64 = 20_000
        /// Hello again this often until answered.
        public var helloInterval: Int64 = 200_000
        /// The frame deadline until the hub's report gives one.
        public var frameDeadline: Int64 = 150_000
        /// What the hellos ask for: a session for sound alone says so, and the hub doesn't probe its bandwidth.
        public var wantsVideo = true
        public var wantsAudio = true

        public init() {}
    }

    public let sessionID: UInt32
    public var settings: Settings
    /// Sent in each hello; change it and call `hello(now:)` after a network change.
    public var network: PhoneNetwork
    public private(set) var isConnected = false
    public private(set) var report: SenderReport?
    /// The hub's smoothed round trip, or the hello's until the hub has one.
    public private(set) var roundTrip: Int64?
    public private(set) var stats = ReceiverStats()
    /// Added to a time on the hub's clock (µs, 32 bits, as packets carry it), gives this phone's time for it: the
    /// shortest trip a packet made over the last 10–20 s, less half the shortest round trip (each way taken as half,
    /// as NTP does; a lopsided path, like a cellular uplink, is off by half the difference). Nil until both are known.
    public private(set) var hubClockOffset: UInt32?
    private var shortestTrip = ModularMinimum(window: 10_000_000)
    private var shortestRoundTrip = WindowedMinimum(window: 10_000_000)
    private var lastClockEvent: Int64?

    private var sealer: PacketSealer
    private var opener: PacketOpener
    private let assembler: FrameAssembler
    private var nack = NackGenerator()
    private var feedback = FeedbackBuilder()
    private var audio = AudioDepacketizer()
    /// Unanswered hellos: nonce → when sent.
    private var hellos: [UInt32: Int64] = [:]
    private var helloPending = false
    private var lastHello: Int64?
    private var lastSend: Int64?
    /// The newest picture piece known to have been sent.
    private var expectedVideo: UInt32?
    private var lastVideoArrival: Int64?
    /// Typical spacing of picture packets (µs), for telling a pause from a lost tail.
    private var videoSpacing = 2_000.0
    private var nackEnabled = true

    public init(keys: TransportKeys, network: PhoneNetwork, settings: Settings = Settings()) {
        sessionID = keys.sessionID
        self.settings = settings
        self.network = network
        sealer = PacketSealer(keys: keys, direction: .phoneToHub)
        opener = PacketOpener(keys: keys, direction: .hubToPhone)
        var assembly = FrameAssembler.Settings()
        assembly.frameDeadline = settings.frameDeadline
        assembler = FrameAssembler(settings: assembly)
    }

    /// A frame was lost and no refresh frame has arrived since: keep asking for one.
    public var awaitingRefresh: Bool { assembler.awaitingRefresh }
    public var assemblyStats: FrameAssembler.Stats { assembler.stats }
    public var nackStats: NackGenerator.Stats { nack.stats }

    /// The hello to send now; it's repeated every 200 ms from `poll` until the hub answers. Call again after a network
    /// change (from the new socket).
    public func hello(now: Int64) -> Data? {
        helloPending = true
        return makeHello(now: now)
    }

    /// A small app message to send now (`ScreenFeedback`...).
    public func appMessage(_ message: AppMessage, now: Int64) throws -> Data {
        guard message.data.count <= AppMessage.maxDataSize else { throw TransportError.tooLarge }
        let sealed = try sealer.seal(.app(message), sendTime: TransportClock.wire(now))
        lastSend = now
        return sealed.datagram
    }

    // MARK: From the hub

    public func receive(_ datagram: Data, now: Int64) -> [ReceiverEvent] {
        let packet: TransportPacket
        switch opener.open(datagram) {
        case .success(let opened):
            packet = opened
        case .failure(let rejection):
            stats.rejected[rejection, default: 0] += 1
            return []
        }
        feedback.record(number: packet.number, arrival: now)
        shortestTrip.add(TransportClock.wire(now) &- packet.sendTime, now: now)
        stats.packetsReceived += 1
        stats.bytesReceived += datagram.count
        var events: [ReceiverEvent] = []
        if case .helloAck(let ack) = packet.message, let sentAt = hellos[ack.nonce] {
            hellos.removeAll()
            helloPending = false
            let wasConnected = isConnected
            isConnected = true
            if roundTrip == nil || ack.report.roundTripMicros == 0 { roundTrip = now - sentAt }
            shortestRoundTrip.add(now - sentAt, now: now)
            apply(ack.report, now: now, events: &events)
            if !wasConnected { events.append(.connected(roundTrip: now - sentAt, path: ack.report.path)) }
        } else if !isConnected {
            // The answer was lost but the stream is here: the path works all the same.
            isConnected = true
            events.append(.connected(roundTrip: 0, path: report?.path ?? .unknown))
        }
        switch packet.message {
        case .keepalive(let keepalive):
            if let report = keepalive.report { apply(report, now: now, events: &events) }
        case .video(let fragment):
            stats.videoPackets += 1
            if fragment.flags.contains(.retransmission) { stats.retransmissionsReceived += 1 }
            noteVideoArrival(now)
            nack.received(fragment.sequence, now: now, deadline: now + assembler.settings.frameDeadline,
                          wait: parityWait(after: fragment))
            noteSent(through: fragment.firstSequence &+ UInt32(fragment.count) &- 1)
            apply(assembler.add(fragment, now: now), now: now, events: &events)
        case .parity(let parity):
            stats.parityPackets += 1
            noteVideoArrival(now)
            noteSent(through: parity.firstSequence &+ UInt32(parity.count) &- 1)
            apply(assembler.add(parity, now: now), now: now, events: &events)
        case .audio(let bundle):
            stats.audioPackets += 1
            let frames = audio.unpack(bundle)
            if !frames.isEmpty {
                stats.audioFrames += frames.count
                stats.audioFramesFromRedundancy += frames.reduce(0) { $0 + ($1.fromRedundancy ? 1 : 0) }
                events.append(.audio(frames))
            }
        case .app(let message):
            events.append(.appMessage(message))
        case .probe:
            stats.probePackets += 1
        default:
            break
        }
        return events
    }

    // MARK: Out

    /// The datagrams due now (hello repeats, resend requests, arrival reports, keepalives) and frames given up.
    public func poll(now: Int64) -> TransportOutput<ReceiverEvent> {
        var output = TransportOutput<ReceiverEvent>()
        if helloPending, let last = lastHello, now - last >= settings.helloInterval, let hello = makeHello(now: now) {
            output.datagrams.append(hello)
        }
        apply(assembler.expire(now: now), now: now, events: &output.events)
        // Pieces the hub sent that haven't come, once the stream paused longer than its usual spacing: a lost tail.
        if tailMissing, let lastArrival = lastVideoArrival, now >= lastArrival + tailWait, let expected = expectedVideo {
            nack.expect(through: expected, now: now, wait: 0, deadline: now + assembler.settings.frameDeadline)
        }
        // Always run the generator so its timers move on; send only while the hub honours resends.
        let due = nack.due(now: now, roundTrip: roundTrip ?? 100_000)
        if nackEnabled {
            var start = 0
            while start < due.count {
                let chunk = Array(due[start..<min(start + 150, due.count)])
                if let datagram = seal(.nack(TransportNack(stream: 0, sequences: chunk)), now: now) {
                    output.datagrams.append(datagram)
                    stats.nackPacketsSent += 1
                }
                start += 150
            }
        }
        if feedback.isDue(now: now, interval: feedbackInterval) {
            for report in feedback.build(now: now) {
                guard let datagram = seal(.feedback(report), now: now) else { continue }
                output.datagrams.append(datagram)
                stats.feedbackSent += 1
            }
        }
        if isConnected, lastSend.map({ now - $0 >= settings.keepaliveInterval }) ?? true,
           let datagram = seal(.keepalive(TransportKeepalive()), now: now) {
            output.datagrams.append(datagram)
        }
        return output
    }

    /// When `poll` next has something to do.
    public func nextWakeup(now: Int64) -> Int64 {
        var times: [Int64] = []
        if helloPending, let last = lastHello { times.append(last + settings.helloInterval) }
        if let deadline = assembler.nextDeadline { times.append(deadline) }
        if tailMissing, let lastArrival = lastVideoArrival { times.append(lastArrival + tailWait) }
        if let wakeup = nack.nextWakeup { times.append(wakeup) }
        if let due = feedback.nextDue(interval: feedbackInterval) { times.append(due) }
        if isConnected { times.append((lastSend ?? now) + settings.keepaliveInterval) }
        return max(now, times.min() ?? now + 1_000_000)
    }

    // MARK: Inside

    private var feedbackInterval: Int64 {
        Int64(PathProfile.profile(for: report?.path ?? .unknown).feedbackIntervalMs * 1000)
    }

    /// Wait this long after the last picture packet before calling the rest of a frame lost: a few typical spacings.
    private var tailWait: Int64 {
        min(max(nack.settings.reorderWait, Int64(3 * videoSpacing)), 20_000)
    }

    /// For a frame with parity, a gap isn't asked about until the rest of the frame and its parity (sent after its
    /// pieces; up to ≈30% of them) have had time to arrive and maybe rebuild it; capped at 30 ms.
    private func parityWait(after fragment: VideoFragment) -> Int64? {
        guard fragment.fecBlockSize > 0 else { return nil }
        let pieces = Int(fragment.count)
        let remaining = pieces - 1 - Int(fragment.index) + (pieces * 3 + 9) / 10
        return min(nack.settings.reorderWait + Int64(Double(remaining) * videoSpacing), 30_000)
    }

    private var tailMissing: Bool {
        guard let expected = expectedVideo, let highest = nack.highest else { return false }
        return SerialNumber.isBefore(highest, expected)
    }

    private func makeHello(now: Int64) -> Data? {
        let nonce = UInt32.random(in: 1...UInt32.max)
        hellos[nonce] = now
        if hellos.count > 16, let oldest = hellos.min(by: { $0.value < $1.value })?.key { hellos[oldest] = nil }
        lastHello = now
        return seal(.hello(TransportHello(nonce: nonce, network: network, wantsVideo: settings.wantsVideo,
                                          wantsAudio: settings.wantsAudio)), now: now)
    }

    private func seal(_ message: TransportMessage, now: Int64) -> Data? {
        guard let sealed = try? sealer.seal(message, sendTime: TransportClock.wire(now)) else { return nil }
        lastSend = now
        return sealed.datagram
    }

    private func apply(_ report: SenderReport, now: Int64, events: inout [ReceiverEvent]) {
        let changed = self.report.map {
            $0.path != report.path || $0.nack != report.nack || $0.frameDeadlineMicros != report.frameDeadlineMicros
        } ?? true
        self.report = report
        if report.roundTripMicros > 0 {
            roundTrip = Int64(report.roundTripMicros)
            shortestRoundTrip.add(Int64(report.roundTripMicros), now: now)
        }
        if let trip = shortestTrip.value, let shortest = shortestRoundTrip.value {
            let offset = trip &- UInt32(clamping: shortest / 2)
            if offset != hubClockOffset || lastClockEvent.map({ now - $0 >= 1_000_000 }) ?? true {
                events.append(.clock(hubClockOffset: offset))
                lastClockEvent = now
            }
            hubClockOffset = offset
        }
        nackEnabled = report.nack
        if report.frameDeadlineMicros > 0 { assembler.settings.frameDeadline = Int64(report.frameDeadlineMicros) }
        if let last = report.lastVideoSequence { noteSent(through: last) }
        if let frameID = report.lastFrameID { apply(assembler.announce(lastFrameID: frameID, now: now), now: now, events: &events) }
        if changed { events.append(.report(report)) }
    }

    private func apply(_ assembled: [FrameAssembler.Event], now: Int64, events: inout [ReceiverEvent]) {
        for event in assembled {
            switch event {
            case .frame(var frame):
                nack.forget(through: frame.lastSequence)
                stats.framesDelivered += 1
                frame.hubClockOffset = hubClockOffset
                events.append(.frame(frame))
            case .lost(let frameID, let lastSequence):
                if let lastSequence { nack.forget(through: lastSequence) }
                stats.framesLost += 1
                events.append(.frameLost(frameID: frameID))
            case .skipped(let frameID, let lastSequence):
                if let lastSequence { nack.forget(through: lastSequence) }
                stats.framesSkipped += 1
                events.append(.frameSkipped(frameID: frameID))
            case .recovered(let sequences):
                stats.fecRecovered += sequences.count
                for sequence in sequences {
                    nack.received(sequence, now: now, deadline: now + assembler.settings.frameDeadline)
                }
            }
        }
    }

    private func noteSent(through sequence: UInt32) {
        if expectedVideo.map({ SerialNumber.isBefore($0, sequence) }) ?? true { expectedVideo = sequence }
    }

    private func noteVideoArrival(_ now: Int64) {
        if let last = lastVideoArrival, now - last < 50_000 {
            videoSpacing += (Double(now - last) - videoSpacing) * 0.1
        }
        lastVideoArrival = now
    }
}

/// The smallest of a 32-bit counter that wraps (trip times on two unrelated clocks), over the current and the previous
/// window. Values compare by their difference, so the wrap doesn't matter while they're within 2³¹ of each other.
nonisolated struct ModularMinimum: Sendable {
    let window: Int64
    private var current: (value: UInt32, since: Int64)?
    private var previous: UInt32?

    init(window: Int64) {
        self.window = window
    }

    var value: UInt32? {
        guard let current else { return previous }
        guard let previous else { return current.value }
        return Self.isLess(previous, current.value) ? previous : current.value
    }

    mutating func add(_ value: UInt32, now: Int64) {
        guard let current, now - current.since < window else {
            previous = self.current?.value
            self.current = (value, now)
            return
        }
        if Self.isLess(value, current.value) { self.current = (value, current.since) }
    }

    static func isLess(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
}
