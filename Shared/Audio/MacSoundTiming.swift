import Foundation

// Step 2: the Mac's sound and picture on one clock. Every video frame already carries its capture time on the Mac's
// host clock; sound gets the same, on the WebSocket (`TimedAudioMessage`) as over UDP (Opus). The phone maps that clock
// onto its own (`MacClock`), from UDP packets' send times when the transport is up, else from `mac.clock` exchanges.
// Times are µs on the host clock (mach_absolute_time, as `TransportClock` and ScreenCaptureKit read it).

nonisolated extension Method {
    /// The Mac's host clock now (`MacClockResult`): with the request's round trip, the phone places the Mac's clock
    /// on its own.
    public static let macClock = "mac.clock"
}

nonisolated public struct MacClockResult: Codable, Sendable, Equatable {
    /// µs on the Mac's host clock when the hub answered.
    public var hostTime: Int64

    public init(hostTime: Int64) {
        self.hostTime = hostTime
    }
}

/// `screen.audio`'s parameters from a phone that knows step 2 (older phones send none and get AAC-LC, untimed).
nonisolated public struct ScreenAudioParams: Codable, Sendable, Equatable {
    /// The codecs the phone decodes, best first: `MacAudioCodec.aacELD`, `MacAudioCodec.aacLC`.
    public var codecs: [String]
    /// It takes `TimedAudioMessage` (each with its capture time).
    public var timed: Bool

    public init(codecs: [String] = [MacAudioCodec.aacELD, MacAudioCodec.aacLC], timed: Bool = true) {
        self.codecs = codecs
        self.timed = timed
    }
}

/// Kind 6, sound on the WebSocket with its capture time, for phones that asked for it (older ones get kind 2,
/// `AudioPacketMessage`). byte 0: kind (6); 1–4: sequence number; 5–12: the capture time of the first sample the
/// decoder gives for the first packet (µs on the Mac's host clock, Int64; the encoder's own delay is already taken
/// off); 13–14: packet count; then each packet as its length (UInt16) and its bytes. All numbers big-endian.
nonisolated public enum TimedAudioMessage {
    public static let kind: UInt8 = 6
    public static let headerSize = 15

    public struct Parsed: Sendable, Equatable {
        public var sequence: UInt32
        public var captureTime: Int64
        public var packets: [Data]
    }

    public static func make(sequence: UInt32, captureTime: Int64, packets: [Data]) -> Data {
        let usable = packets.prefix(Int(UInt16.max)).filter { !$0.isEmpty && $0.count <= Int(UInt16.max) }
        var data = Data(capacity: headerSize + usable.reduce(0) { $0 + 2 + $1.count })
        data.append(kind)
        WireBytes.append(sequence, to: &data)
        WireBytes.append(UInt64(bitPattern: captureTime), to: &data)
        WireBytes.append(UInt16(usable.count), to: &data)
        for packet in usable {
            WireBytes.append(UInt16(packet.count), to: &data)
            data.append(packet)
        }
        return data
    }

    /// Nil for anything that isn't a whole timed sound message.
    public static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, bytes[0] == kind else { return nil }
        let count = Int(WireBytes.u16(bytes, 13))
        var packets: [Data] = []
        packets.reserveCapacity(count)
        var offset = headerSize
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(WireBytes.u16(bytes, offset))
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            packets.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        guard offset == bytes.count else { return nil }
        return Parsed(sequence: WireBytes.u32(bytes, 1), captureTime: Int64(bitPattern: WireBytes.u64(bytes, 5)),
                      packets: packets)
    }
}

/// Which capture time each sample an encoder gives back stands for, from its input buffers' timestamps: sample `n` of
/// the decoded stream is input sample `n − leadingFrames` (the encoder's priming, which the decoder plays first). A
/// gap or jump in the input (the capture paused) re-anchors the count, so times stay true across it.
nonisolated public struct SampleClock: Sendable {
    public let sampleRate: Double
    /// The encoder's delay in samples: AAC-LC's 2,112, AAC-ELD's 240 (at 480 frames a packet), Opus's look-ahead.
    public let leadingFrames: Int
    /// Input samples counted so far, and the capture time of sample 0 on that count.
    private var inputSamples = 0
    private var anchor: Int64?

    public init(sampleRate: Double, leadingFrames: Int) {
        self.sampleRate = sampleRate
        self.leadingFrames = leadingFrames
    }

    /// An input buffer of `frames` samples whose first was captured at `captureTime` (µs).
    public mutating func input(frames: Int, captureTime: Int64) {
        let expected = anchor.map { $0 + Int64(Double(inputSamples) * 1e6 / sampleRate) }
        // More than 20 ms off where the count puts it: the capture skipped or stalled; count from here.
        if expected.map({ abs($0 - captureTime) > 20_000 }) ?? true {
            anchor = captureTime - Int64(Double(inputSamples) * 1e6 / sampleRate)
        }
        inputSamples += frames
    }

    /// The capture time of decoded sample `index` (µs); nil before any input.
    public func captureTime(ofDecodedSample index: Int) -> Int64? {
        guard let anchor else { return nil }
        return anchor + Int64(Double(index - leadingFrames) * 1e6 / sampleRate)
    }
}
