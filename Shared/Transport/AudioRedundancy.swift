import Foundation

// Sound packets carry the newest Opus frame and copies of the one or two before it (on relays, DERP and cellular), so a
// lost packet's sound usually arrives 10 ms later in the next one, music included. Opus's own in-band error correction
// only works in its speech modes, and music at these bitrates is coded in CELT, which has none; a copy costs one more
// frame's bytes (≈120–160) per packet.

/// Numbers sound frames and bundles each with copies of the ones before it.
nonisolated public struct AudioPacketizer: Sendable {
    public static let maxRedundancy = 3

    public let stream: UInt8
    /// Earlier frames copied into each packet (0...3).
    public var redundancy: Int
    public private(set) var nextSequence: UInt32
    /// Newest first.
    private var recent: [Data] = []

    public init(stream: UInt8 = 1, redundancy: Int = 0, firstSequence: UInt32 = 1) {
        self.stream = stream
        self.redundancy = redundancy
        nextSequence = firstSequence
    }

    /// Nil for an empty frame or one too large for a packet.
    public mutating func packetize(_ frame: Data, timestamp: UInt64, duration: UInt16) -> AudioBundle? {
        var size = AudioBundle.headerSize + 2 + frame.count
        guard !frame.isEmpty, size <= TransportWire.maxPayloadSize else { return nil }
        let sequence = nextSequence
        nextSequence &+= 1
        var frames = [frame]
        for earlier in recent.prefix(min(max(redundancy, 0), Self.maxRedundancy)) {
            guard size + 2 + earlier.count <= TransportWire.maxPayloadSize else { break }
            frames.append(earlier)
            size += 2 + earlier.count
        }
        recent.insert(frame, at: 0)
        if recent.count > Self.maxRedundancy { recent.removeLast(recent.count - Self.maxRedundancy) }
        return AudioBundle(stream: stream, sequence: sequence, timestamp: timestamp, duration: duration, frames: frames)
    }
}

nonisolated public struct ReceivedAudioFrame: Sendable, Equatable {
    public var sequence: UInt32
    /// Media time: µs on the Mac's host clock.
    public var timestamp: UInt64
    /// µs.
    public var duration: UInt16
    public var data: Data
    /// It came as a copy in a later packet: its own was lost (or is late).
    public var fromRedundancy: Bool
}

/// Turns sound bundles back into frames, each once, oldest first.
nonisolated public struct AudioDepacketizer: Sendable {
    /// Frames further behind the newest than this are ignored (10 s of 10 ms frames).
    public static let window: Int64 = 1000

    private var newest: UInt32?
    private var seen = Set<UInt32>()

    public init() {}

    public mutating func unpack(_ bundle: AudioBundle) -> [ReceivedAudioFrame] {
        var frames: [ReceivedAudioFrame] = []
        for (age, data) in bundle.frames.enumerated().reversed() {
            let sequence = bundle.sequence &- UInt32(age)
            if let newest, SerialNumber.distance(from: sequence, to: newest) >= Self.window { continue }
            guard seen.insert(sequence).inserted else { continue }
            let timestamp = bundle.timestamp &- UInt64(age) &* UInt64(bundle.duration)
            frames.append(ReceivedAudioFrame(sequence: sequence, timestamp: timestamp, duration: bundle.duration,
                                             data: data, fromRedundancy: age > 0))
            if newest.map({ SerialNumber.isBefore($0, sequence) }) ?? true { newest = sequence }
        }
        if seen.count > Int(2 * Self.window), let newest {
            seen = seen.filter { SerialNumber.distance(from: $0, to: newest) < Self.window }
        }
        return frames
    }
}
