import Foundation

// The UDP media transport's packets, version 1: picture and sound from the hub to the phone, and the phone's
// feedback, inside Tailscale. Every datagram is at most 1,200 bytes, which fits Tailscale's 1,280-byte tunnel MTU with
// room for the IPv6 and UDP headers, so nothing is ever fragmented on the way.
//
//   clear header, 13 bytes (authenticated, not encrypted): version 1 · session id 4 · packet number 8
//   sealed body: kind 1 · send time 4 (µs on the sender's clock, wrapping) · payload
//   tag, 16 bytes: ChaCha20-Poly1305 over the body, with the clear header as associated data
//
// The packet number counts every datagram one side sends under the session's key, from 1. It is the nonce, the replay
// counter and the transport-wide sequence the phone's arrival reports refer to, so a resend is a new packet with a new
// number. All numbers are big-endian.

nonisolated public enum TransportWire {
    public static let version: UInt8 = 1
    public static let maxDatagramSize = 1200
    public static let clearHeaderSize = 13
    public static let bodyHeaderSize = 5
    public static let tagSize = 16
    public static let overhead = clearHeaderSize + bodyHeaderSize + tagSize
    /// The most one message's payload can hold: 1,166 bytes.
    public static let maxPayloadSize = maxDatagramSize - overhead

    /// The session a datagram claims to belong to, read without opening it (the hub routes by it); nil for anything
    /// that isn't a version 1 transport packet.
    public static func sessionID(of datagram: Data) -> UInt32? {
        guard datagram.count >= overhead, datagram.count <= maxDatagramSize,
              datagram[datagram.startIndex] == version else { return nil }
        let bytes = [UInt8](datagram.prefix(clearHeaderSize))
        return WireBytes.u32(bytes, 1)
    }
}

/// What a packet carries. The values are part of the wire format.
nonisolated public enum TransportKind: UInt8, Sendable, CaseIterable {
    /// Phone → hub: here I am (first, and after every network change).
    case hello = 1
    /// Hub → phone: the answer to a hello.
    case helloAck = 2
    /// Either way, when nothing else went out for 20 ms; the hub's carries its report.
    case keepalive = 3
    /// Hub → phone: padding sent in a burst to measure the path's capacity.
    case probe = 4
    /// Hub → phone: one piece of an encoded picture.
    case video = 16
    /// Hub → phone: Reed–Solomon parity over a block of a picture's pieces.
    case parity = 17
    /// Hub → phone: Opus frames, the newest with copies of the ones before it.
    case audio = 18
    /// Phone → hub: please resend these picture pieces.
    case nack = 32
    /// Phone → hub: when each packet arrived, for the delay-based rate control.
    case feedback = 33
    /// Either way: a small application message (`ScreenFeedback`, the pointer...), unreliable, latest wins.
    case app = 48
}

/// The phone's network, from its own path monitor: cellular gets error correction even on a direct path.
nonisolated public enum PhoneNetwork: String, Codable, Sendable, CaseIterable {
    case wifi, cellular, wired, other

    var code: UInt8 {
        switch self {
        case .other: 0
        case .wifi: 1
        case .cellular: 2
        case .wired: 3
        }
    }

    init(code: UInt8) {
        switch code {
        case 1: self = .wifi
        case 2: self = .cellular
        case 3: self = .wired
        default: self = .other
        }
    }
}

// MARK: Payloads

/// The phone's hello. Being sealed with the session's key is what proves it comes from the phone that asked for the
/// session over the WebSocket; the hub learns the phone's current address and port from it.
nonisolated public struct TransportHello: Sendable, Equatable {
    /// Echoed in the answer, so the phone can match it to this attempt and time the round trip.
    public var nonce: UInt32
    public var network: PhoneNetwork
    public var wantsVideo: Bool
    public var wantsAudio: Bool

    public init(nonce: UInt32, network: PhoneNetwork, wantsVideo: Bool = true, wantsAudio: Bool = true) {
        self.nonce = nonce
        self.network = network
        self.wantsVideo = wantsVideo
        self.wantsAudio = wantsAudio
    }

    static let size = 6

    func encode(into data: inout Data) {
        WireBytes.append(nonce, to: &data)
        data.append(network.code)
        data.append((wantsVideo ? 1 : 0) | (wantsAudio ? 2 : 0))
    }

    static func decode(_ reader: inout ByteReader) -> TransportHello? {
        guard let nonce = reader.u32(), let network = reader.u8(), let flags = reader.u8() else { return nil }
        return TransportHello(nonce: nonce, network: PhoneNetwork(code: network), wantsVideo: flags & 1 != 0,
                              wantsAudio: flags & 2 != 0)
    }
}

/// What the hub tells the phone in every hello answer and keepalive: the path and the recovery settings in force, and
/// the newest picture and sound it has sent, so the phone notices a loss at the end of a burst without waiting for the
/// next frame.
nonisolated public struct SenderReport: Sendable, Equatable {
    public var path: PathKind
    /// The phone should ask for resends (the round trip is short enough for them to arrive in time).
    public var nack: Bool
    /// The hub's smoothed round trip, 0 while unknown.
    public var roundTripMicros: UInt32
    /// How long the phone should wait for a picture before giving up on it.
    public var frameDeadlineMicros: UInt32
    /// Everything the hub may send per second, in bits.
    public var targetBitrate: UInt32
    /// The newest picture piece and picture sent; nil before the first.
    public var lastVideoSequence: UInt32?
    public var lastFrameID: UInt32?
    /// The newest sound frame sent; nil before the first.
    public var lastAudioSequence: UInt32?

    public init(path: PathKind, nack: Bool, roundTripMicros: UInt32, frameDeadlineMicros: UInt32, targetBitrate: UInt32,
                lastVideoSequence: UInt32? = nil, lastFrameID: UInt32? = nil, lastAudioSequence: UInt32? = nil) {
        self.path = path
        self.nack = nack
        self.roundTripMicros = roundTripMicros
        self.frameDeadlineMicros = frameDeadlineMicros
        self.targetBitrate = targetBitrate
        self.lastVideoSequence = lastVideoSequence
        self.lastFrameID = lastFrameID
        self.lastAudioSequence = lastAudioSequence
    }

    static let size = 26

    func encode(into data: inout Data) {
        let hasVideo = lastVideoSequence != nil && lastFrameID != nil
        data.append(path.code)
        data.append((nack ? 1 : 0) | (hasVideo ? 2 : 0) | (lastAudioSequence != nil ? 4 : 0))
        WireBytes.append(roundTripMicros, to: &data)
        WireBytes.append(frameDeadlineMicros, to: &data)
        WireBytes.append(targetBitrate, to: &data)
        WireBytes.append(hasVideo ? lastVideoSequence ?? 0 : 0, to: &data)
        WireBytes.append(hasVideo ? lastFrameID ?? 0 : 0, to: &data)
        WireBytes.append(lastAudioSequence ?? 0, to: &data)
    }

    static func decode(_ reader: inout ByteReader) -> SenderReport? {
        guard let path = reader.u8(), let flags = reader.u8(), let rtt = reader.u32(), let deadline = reader.u32(),
              let bitrate = reader.u32(), let videoSequence = reader.u32(), let frameID = reader.u32(),
              let audioSequence = reader.u32() else { return nil }
        let hasVideo = flags & 2 != 0
        return SenderReport(path: PathKind(code: path), nack: flags & 1 != 0, roundTripMicros: rtt,
                            frameDeadlineMicros: deadline, targetBitrate: bitrate,
                            lastVideoSequence: hasVideo ? videoSequence : nil, lastFrameID: hasVideo ? frameID : nil,
                            lastAudioSequence: flags & 4 != 0 ? audioSequence : nil)
    }
}

nonisolated public struct TransportHelloAck: Sendable, Equatable {
    public var nonce: UInt32
    public var report: SenderReport

    public init(nonce: UInt32, report: SenderReport) {
        self.nonce = nonce
        self.report = report
    }
}

nonisolated public struct TransportKeepalive: Sendable, Equatable {
    /// The hub's; the phone's keepalives carry nothing.
    public var report: SenderReport?

    public init(report: SenderReport? = nil) {
        self.report = report
    }
}

/// Padding in a probe cluster: the hub sends a burst of these at a chosen rate and the phone's arrival times show
/// whether the path kept up.
nonisolated public struct TransportProbe: Sendable, Equatable {
    public var cluster: UInt16
    /// Zero bytes after the cluster id.
    public var paddingSize: Int

    public init(cluster: UInt16, paddingSize: Int) {
        self.cluster = cluster
        self.paddingSize = max(0, min(paddingSize, TransportWire.maxPayloadSize - 2))
    }
}

/// Per-frame and per-packet flags on picture pieces.
nonisolated public struct FrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The frame decodes without any unacknowledged frame before it: a keyframe, or one that refers only to an
    /// acknowledged long-term reference. The phone restarts from such a frame after a loss.
    public static let refresh = FrameFlags(rawValue: 1 << 0)
    /// This piece is a resend (per packet).
    public static let retransmission = FrameFlags(rawValue: 1 << 7)

    /// The flags that describe the frame rather than the packet.
    var frameOnly: FrameFlags { subtracting(.retransmission) }
}

/// One piece of an encoded picture (the bytes of a `VideoFrameMessage`). Pieces of a frame have consecutive sequence
/// numbers, so the phone knows every piece's number once it has any of them.
nonisolated public struct VideoFragment: Sendable, Equatable {
    public static let headerSize = 15
    /// Largest piece: small enough that a parity packet over a block of full pieces still fits a datagram.
    public static let maxPayloadSize = TransportWire.maxPayloadSize - ParityFragment.headerSize - 2

    public var stream: UInt8
    /// Per stream; resends repeat it. A gap means a piece went missing.
    public var sequence: UInt32
    public var frameID: UInt32
    public var index: UInt16
    public var count: UInt16
    public var flags: FrameFlags
    /// Pieces per error-correction block (0: the frame has no parity).
    public var fecBlockSize: UInt8
    public var payload: Data

    public init(stream: UInt8, sequence: UInt32, frameID: UInt32, index: UInt16, count: UInt16, flags: FrameFlags,
                fecBlockSize: UInt8, payload: Data) {
        self.stream = stream
        self.sequence = sequence
        self.frameID = frameID
        self.index = index
        self.count = count
        self.flags = flags
        self.fecBlockSize = fecBlockSize
        self.payload = payload
    }

    /// The sequence number of the frame's first piece.
    public var firstSequence: UInt32 { sequence &- UInt32(index) }

    func encode(into data: inout Data) {
        data.append(stream)
        WireBytes.append(sequence, to: &data)
        WireBytes.append(frameID, to: &data)
        WireBytes.append(index, to: &data)
        WireBytes.append(count, to: &data)
        data.append(flags.rawValue)
        data.append(fecBlockSize)
        data.append(payload)
    }

    static func decode(_ reader: inout ByteReader) -> VideoFragment? {
        guard let stream = reader.u8(), let sequence = reader.u32(), let frameID = reader.u32(), let index = reader.u16(),
              let count = reader.u16(), let flags = reader.u8(), let blockSize = reader.u8(),
              count > 0, index < count else { return nil }
        return VideoFragment(stream: stream, sequence: sequence, frameID: frameID, index: index, count: count,
                             flags: FrameFlags(rawValue: flags), fecBlockSize: blockSize, payload: reader.rest())
    }
}

/// Reed–Solomon parity over one block of a frame's pieces. It carries everything needed to rebuild any piece of the
/// block, even when none of them arrived: each data shard is the piece's length (2 bytes) and bytes, zero-padded to the
/// block's longest.
nonisolated public struct ParityFragment: Sendable, Equatable {
    public static let headerSize = 17

    public var stream: UInt8
    public var frameID: UInt32
    public var firstSequence: UInt32
    /// Pieces in the frame.
    public var count: UInt16
    public var flags: FrameFlags
    public var fecBlockSize: UInt8
    public var block: UInt16
    public var parityIndex: UInt8
    public var parityCount: UInt8
    public var shard: Data

    public init(stream: UInt8, frameID: UInt32, firstSequence: UInt32, count: UInt16, flags: FrameFlags,
                fecBlockSize: UInt8, block: UInt16, parityIndex: UInt8, parityCount: UInt8, shard: Data) {
        self.stream = stream
        self.frameID = frameID
        self.firstSequence = firstSequence
        self.count = count
        self.flags = flags
        self.fecBlockSize = fecBlockSize
        self.block = block
        self.parityIndex = parityIndex
        self.parityCount = parityCount
        self.shard = shard
    }

    func encode(into data: inout Data) {
        data.append(stream)
        WireBytes.append(frameID, to: &data)
        WireBytes.append(firstSequence, to: &data)
        WireBytes.append(count, to: &data)
        data.append(flags.rawValue)
        data.append(fecBlockSize)
        WireBytes.append(block, to: &data)
        data.append(parityIndex)
        data.append(parityCount)
        data.append(shard)
    }

    static func decode(_ reader: inout ByteReader) -> ParityFragment? {
        guard let stream = reader.u8(), let frameID = reader.u32(), let firstSequence = reader.u32(),
              let count = reader.u16(), let flags = reader.u8(), let blockSize = reader.u8(), let block = reader.u16(),
              let parityIndex = reader.u8(), let parityCount = reader.u8(),
              count > 0, blockSize > 0, parityCount > 0, parityIndex < parityCount,
              Int(block) * Int(blockSize) < Int(count), reader.remaining >= 2 else { return nil }
        return ParityFragment(stream: stream, frameID: frameID, firstSequence: firstSequence, count: count,
                              flags: FrameFlags(rawValue: flags), fecBlockSize: blockSize, block: block,
                              parityIndex: parityIndex, parityCount: parityCount, shard: reader.rest())
    }
}

/// Sound: the newest Opus frame and copies of the ones just before it, newest first, so a lost packet's sound usually
/// arrives in the next one.
nonisolated public struct AudioBundle: Sendable, Equatable {
    public static let headerSize = 16

    public var stream: UInt8
    /// The newest frame's; the copies are `sequence - 1`, `sequence - 2`...
    public var sequence: UInt32
    /// The newest frame's media time: µs on the Mac's host clock.
    public var timestamp: UInt64
    /// Each frame's length in µs.
    public var duration: UInt16
    public var frames: [Data]

    public init(stream: UInt8, sequence: UInt32, timestamp: UInt64, duration: UInt16, frames: [Data]) {
        self.stream = stream
        self.sequence = sequence
        self.timestamp = timestamp
        self.duration = duration
        self.frames = frames
    }

    var payloadSize: Int { Self.headerSize + frames.reduce(0) { $0 + 2 + $1.count } }

    func encode(into data: inout Data) {
        data.append(stream)
        WireBytes.append(sequence, to: &data)
        WireBytes.append(timestamp, to: &data)
        WireBytes.append(duration, to: &data)
        data.append(UInt8(clamping: frames.count))
        for frame in frames.prefix(255) {
            WireBytes.append(UInt16(clamping: frame.count), to: &data)
            data.append(frame)
        }
    }

    static func decode(_ reader: inout ByteReader) -> AudioBundle? {
        guard let stream = reader.u8(), let sequence = reader.u32(), let timestamp = reader.u64(),
              let duration = reader.u16(), let count = reader.u8(), count > 0 else { return nil }
        var frames: [Data] = []
        for _ in 0..<count {
            guard let length = reader.u16(), let frame = reader.data(Int(length)) else { return nil }
            frames.append(frame)
        }
        return AudioBundle(stream: stream, sequence: sequence, timestamp: timestamp, duration: duration, frames: frames)
    }
}

/// Picture pieces to resend, as RTCP's generic NACK writes them: a sequence number and a bitmask of the 16 after it.
nonisolated public struct TransportNack: Sendable, Equatable {
    public static let headerSize = 3
    public static let pairSize = 6
    public static let maxPairs = (TransportWire.maxPayloadSize - headerSize) / pairSize

    public var stream: UInt8
    /// Ascending (in serial order), without repeats.
    public var sequences: [UInt32]

    public init(stream: UInt8, sequences: [UInt32]) {
        self.stream = stream
        self.sequences = Self.normalized(sequences)
    }

    static func normalized(_ sequences: [UInt32]) -> [UInt32] {
        guard let first = sequences.first else { return [] }
        // Serial order relative to the oldest: numbers within 2^31 of each other sort correctly across the wrap.
        let base = sequences.reduce(first) { SerialNumber.isBefore($1, $0) ? $1 : $0 }
        var seen = Set<UInt32>()
        return sequences.filter { seen.insert($0).inserted }.sorted { $0 &- base < $1 &- base }
    }

    /// (first, bitmask) pairs.
    var pairs: [(UInt32, UInt16)] {
        var pairs: [(UInt32, UInt16)] = []
        var index = 0
        while index < sequences.count {
            let first = sequences[index]
            var mask: UInt16 = 0
            index += 1
            while index < sequences.count {
                let distance = sequences[index] &- first
                guard distance >= 1, distance <= 16 else { break }
                mask |= 1 << (distance - 1)
                index += 1
            }
            pairs.append((first, mask))
        }
        return pairs
    }

    var payloadSize: Int { Self.headerSize + pairs.count * Self.pairSize }

    func encode(into data: inout Data) {
        let pairs = pairs
        data.append(stream)
        WireBytes.append(UInt16(clamping: pairs.count), to: &data)
        for (first, mask) in pairs {
            WireBytes.append(first, to: &data)
            WireBytes.append(mask, to: &data)
        }
    }

    static func decode(_ reader: inout ByteReader) -> TransportNack? {
        guard let stream = reader.u8(), let count = reader.u16() else { return nil }
        var sequences: [UInt32] = []
        for _ in 0..<count {
            guard let first = reader.u32(), let mask = reader.u16() else { return nil }
            sequences.append(first)
            for bit in 0..<16 where mask & (1 << bit) != 0 { sequences.append(first &+ UInt32(bit) &+ 1) }
        }
        return TransportNack(stream: stream, sequences: sequences)
    }
}

/// When the phone received each packet from a run of the hub's packet numbers, as transport-wide congestion control
/// feedback writes it: two status bits per packet (not received, small delta, large delta), then each received
/// packet's arrival as a delta from the one before in 250 µs units (one byte up to 63.75 ms, else two, signed).
nonisolated public struct TransportFeedback: Sendable, Equatable {
    public static let headerSize = 20
    public static let tick: Int64 = 250

    public var feedbackSequence: UInt16
    public var baseNumber: UInt64
    /// µs on the phone's clock: when the first received packet in the run arrived.
    public var referenceTime: Int64
    /// One per packet number from `baseNumber`: when it arrived (µs on the phone's clock, to the 250 µs the wire
    /// keeps), nil if it didn't.
    public var arrivals: [Int64?]

    /// Built by `FeedbackBuilder`, which keeps each delta within what the wire can carry.
    init(feedbackSequence: UInt16, baseNumber: UInt64, referenceTime: Int64, arrivals: [Int64?]) {
        self.feedbackSequence = feedbackSequence
        self.baseNumber = baseNumber
        self.referenceTime = referenceTime
        self.arrivals = arrivals
    }

    var payloadSize: Int {
        var size = Self.headerSize + (arrivals.count + 3) / 4
        var previous = referenceTime
        for arrival in arrivals {
            guard let arrival else { continue }
            let delta = (arrival - previous) / Self.tick
            size += (0...255).contains(delta) ? 1 : 2
            previous = arrival
        }
        return size
    }

    func encode(into data: inout Data) {
        WireBytes.append(feedbackSequence, to: &data)
        WireBytes.append(baseNumber, to: &data)
        WireBytes.append(UInt16(clamping: arrivals.count), to: &data)
        WireBytes.append(UInt64(bitPattern: referenceTime), to: &data)
        var statuses = [UInt8](repeating: 0, count: (arrivals.count + 3) / 4)
        var deltas = Data()
        var previous = referenceTime
        for (index, arrival) in arrivals.enumerated() {
            guard let arrival else { continue }
            let delta = (arrival - previous) / Self.tick
            let status: UInt8
            if (0...255).contains(delta) {
                status = 1
                deltas.append(UInt8(delta))
            } else {
                status = 2
                WireBytes.append(UInt16(bitPattern: Int16(clamping: delta)), to: &deltas)
            }
            statuses[index / 4] |= status << (6 - 2 * UInt8(index % 4))
            previous += delta * Self.tick
        }
        data.append(contentsOf: statuses)
        data.append(deltas)
    }

    static func decode(_ reader: inout ByteReader) -> TransportFeedback? {
        guard let sequence = reader.u16(), let base = reader.u64(), let count = reader.u16(),
              let reference = reader.u64(), let statuses = reader.data((Int(count) + 3) / 4) else { return nil }
        let statusBytes = [UInt8](statuses)
        var arrivals: [Int64?] = []
        arrivals.reserveCapacity(Int(count))
        var time = Int64(bitPattern: reference)
        for index in 0..<Int(count) {
            switch (statusBytes[index / 4] >> (6 - 2 * UInt8(index % 4))) & 3 {
            case 0:
                arrivals.append(nil)
            case 1:
                guard let delta = reader.u8() else { return nil }
                time += Int64(delta) * tick
                arrivals.append(time)
            case 2:
                guard let delta = reader.u16() else { return nil }
                time += Int64(Int16(bitPattern: delta)) * tick
                arrivals.append(time)
            default:
                return nil
            }
        }
        return TransportFeedback(feedbackSequence: sequence, baseNumber: base, referenceTime: Int64(bitPattern: reference),
                                 arrivals: arrivals)
    }
}

/// A small application message, unreliable: `ScreenFeedback` from the phone, the pointer's position from the hub.
/// Anything bigger than a datagram (a pointer shape's PNG) stays on the WebSocket.
nonisolated public struct AppMessage: Sendable, Equatable {
    public static let maxDataSize = TransportWire.maxPayloadSize - 1

    public var channel: UInt8
    public var data: Data

    public init(channel: UInt8, data: Data) {
        self.channel = channel
        self.data = data
    }
}

// MARK: Messages and packets

nonisolated public enum TransportMessage: Sendable, Equatable {
    case hello(TransportHello)
    case helloAck(TransportHelloAck)
    case keepalive(TransportKeepalive)
    case probe(TransportProbe)
    case video(VideoFragment)
    case parity(ParityFragment)
    case audio(AudioBundle)
    case nack(TransportNack)
    case feedback(TransportFeedback)
    case app(AppMessage)

    public var kind: TransportKind {
        switch self {
        case .hello: .hello
        case .helloAck: .helloAck
        case .keepalive: .keepalive
        case .probe: .probe
        case .video: .video
        case .parity: .parity
        case .audio: .audio
        case .nack: .nack
        case .feedback: .feedback
        case .app: .app
        }
    }

    public var payloadSize: Int {
        switch self {
        case .hello: TransportHello.size
        case .helloAck: 4 + SenderReport.size
        case .keepalive(let keepalive): 1 + (keepalive.report == nil ? 0 : SenderReport.size)
        case .probe(let probe): 2 + probe.paddingSize
        case .video(let fragment): VideoFragment.headerSize + fragment.payload.count
        case .parity(let parity): ParityFragment.headerSize + parity.shard.count
        case .audio(let bundle): bundle.payloadSize
        case .nack(let nack): nack.payloadSize
        case .feedback(let feedback): feedback.payloadSize
        case .app(let message): 1 + message.data.count
        }
    }

    /// The datagram's size once sealed.
    public var datagramSize: Int { TransportWire.overhead + payloadSize }

    func encodePayload(into data: inout Data) {
        switch self {
        case .hello(let hello):
            hello.encode(into: &data)
        case .helloAck(let ack):
            WireBytes.append(ack.nonce, to: &data)
            ack.report.encode(into: &data)
        case .keepalive(let keepalive):
            if let report = keepalive.report {
                data.append(1)
                report.encode(into: &data)
            } else {
                data.append(0)
            }
        case .probe(let probe):
            WireBytes.append(probe.cluster, to: &data)
            data.append(Data(count: probe.paddingSize))
        case .video(let fragment):
            fragment.encode(into: &data)
        case .parity(let parity):
            parity.encode(into: &data)
        case .audio(let bundle):
            bundle.encode(into: &data)
        case .nack(let nack):
            nack.encode(into: &data)
        case .feedback(let feedback):
            feedback.encode(into: &data)
        case .app(let message):
            data.append(message.channel)
            data.append(message.data)
        }
    }

    static func decode(_ kind: TransportKind, _ reader: inout ByteReader) -> TransportMessage? {
        switch kind {
        case .hello:
            return TransportHello.decode(&reader).map(TransportMessage.hello)
        case .helloAck:
            guard let nonce = reader.u32(), let report = SenderReport.decode(&reader) else { return nil }
            return .helloAck(TransportHelloAck(nonce: nonce, report: report))
        case .keepalive:
            guard let flag = reader.u8() else { return nil }
            guard flag != 0 else { return .keepalive(TransportKeepalive()) }
            return SenderReport.decode(&reader).map { .keepalive(TransportKeepalive(report: $0)) }
        case .probe:
            guard let cluster = reader.u16() else { return nil }
            let padding = reader.remaining
            reader.skip(padding)
            return .probe(TransportProbe(cluster: cluster, paddingSize: padding))
        case .video:
            return VideoFragment.decode(&reader).map(TransportMessage.video)
        case .parity:
            return ParityFragment.decode(&reader).map(TransportMessage.parity)
        case .audio:
            return AudioBundle.decode(&reader).map(TransportMessage.audio)
        case .nack:
            return TransportNack.decode(&reader).map(TransportMessage.nack)
        case .feedback:
            return TransportFeedback.decode(&reader).map(TransportMessage.feedback)
        case .app:
            guard let channel = reader.u8() else { return nil }
            return .app(AppMessage(channel: channel, data: reader.rest()))
        }
    }
}

/// An opened packet.
nonisolated public struct TransportPacket: Sendable, Equatable {
    public var number: UInt64
    /// µs on the sender's clock, wrapping every 71 minutes.
    public var sendTime: UInt32
    public var message: TransportMessage

    public init(number: UInt64, sendTime: UInt32, message: TransportMessage) {
        self.number = number
        self.sendTime = sendTime
        self.message = message
    }
}

// MARK: Helpers

/// Sequence numbers that wrap: `a` comes before `b` when it's less than half the number space behind it.
nonisolated public enum SerialNumber {
    public static func isBefore(_ a: UInt32, _ b: UInt32) -> Bool { a != b && (b &- a) < 0x8000_0000 }
    public static func isBefore(_ a: UInt16, _ b: UInt16) -> Bool { a != b && (b &- a) < 0x8000 }
    /// How far `b` is ahead of `a` (negative when behind).
    public static func distance(from a: UInt32, to b: UInt32) -> Int64 { Int64(Int32(bitPattern: b &- a)) }
}

/// Bounds-checked big-endian reading: every read returns nil instead of running past the end.
nonisolated struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return WireBytes.u16(bytes, offset)
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return WireBytes.u32(bytes, offset)
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        return WireBytes.u64(bytes, offset)
    }

    mutating func data(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func rest() -> Data { data(remaining) ?? Data() }

    mutating func skip(_ count: Int) {
        offset += max(0, min(count, remaining))
    }
}

/// Time for the transport: µs on a monotonic clock. Every state machine takes the time as a parameter, so the tests
/// drive them with a simulated clock and the sockets pass `now()`.
nonisolated public enum TransportClock {
    public static let millisecond: Int64 = 1000
    public static let second: Int64 = 1_000_000

    public static func now() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000) }

    /// The 32-bit send time a packet carries.
    static func wire(_ time: Int64) -> UInt32 { UInt32(truncatingIfNeeded: time) }

    /// Milliseconds since `hubTime` (µs on the hub's clock, such as a frame's capture time), on this device's clock,
    /// mapped through `hubClockOffset` (`MediaReceiver.hubClockOffset`). Exact to the wrap of 32 bits (71 minutes).
    public static func milliseconds(since hubTime: Int64, hubClockOffset: UInt32, now: Int64 = now()) -> Double {
        Double(Int32(bitPattern: wire(now) &- (wire(hubTime) &+ hubClockOffset))) / 1000
    }
}
