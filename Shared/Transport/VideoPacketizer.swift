import Foundation

/// Error correction for one frame: Reed–Solomon parity per block of up to `maxBlockSize` pieces.
nonisolated public struct FECSettings: Sendable, Equatable {
    /// Parity pieces per picture piece (0.2 = 20%); 0 turns error correction off.
    public var ratio: Double
    public var maxBlockSize: Int
    /// A block gets at least this many parity pieces while the ratio isn't 0 (a one-piece frame gets one).
    public var minimumParity: Int

    public init(ratio: Double, maxBlockSize: Int = 32, minimumParity: Int = 1) {
        self.ratio = max(0, ratio)
        self.maxBlockSize = min(max(maxBlockSize, 1), 128)
        self.minimumParity = max(minimumParity, 1)
    }

    public static let none = FECSettings(ratio: 0)

    public var isEnabled: Bool { ratio > 0 }

    /// Parity pieces for a block of `pieces`: the ratio rounded up, at least `minimumParity`, and never so many that
    /// the block passes 255 shards.
    public func parityCount(forBlockOf pieces: Int) -> Int {
        guard isEnabled, pieces > 0 else { return 0 }
        // The small allowance keeps 5 × 0.2 at 1 despite floating point.
        let wanted = Int((Double(pieces) * ratio - 1e-9).rounded(.up))
        return max(0, min(max(wanted, minimumParity), 255 - pieces))
    }
}

/// Splits encoded frames (a `VideoFrameMessage`'s bytes) into numbered pieces that fit a datagram, evenly sized so
/// parity wastes little on padding, and adds Reed–Solomon parity per block.
nonisolated public struct VideoPacketizer: Sendable {
    /// Larger frames are refused (a 4:4:4 keyframe is a few hundred KB).
    public static let maxFrameSize = 8 << 20

    public let stream: UInt8
    public private(set) var nextSequence: UInt32
    public private(set) var nextFrameID: UInt32

    public init(stream: UInt8 = 0, firstSequence: UInt32 = 1, firstFrameID: UInt32 = 1) {
        self.stream = stream
        nextSequence = firstSequence
        nextFrameID = firstFrameID
    }

    public struct Packetized: Sendable {
        public var frameID: UInt32
        public var fragments: [VideoFragment]
        public var parity: [ParityFragment]

        public var firstSequence: UInt32 { fragments.first?.sequence ?? 0 }
        public var lastSequence: UInt32 { fragments.last?.sequence ?? 0 }
        public var parityBytes: Int { parity.reduce(0) { $0 + $1.shard.count } }
    }

    /// Nil for an empty or oversized frame.
    public mutating func packetize(_ frame: Data, refresh: Bool, fec: FECSettings) -> Packetized? {
        guard !frame.isEmpty, frame.count <= Self.maxFrameSize else { return nil }
        let pieceLimit = VideoFragment.maxPayloadSize
        let count = (frame.count + pieceLimit - 1) / pieceLimit
        guard count <= Int(UInt16.max) else { return nil }
        let frameID = nextFrameID
        nextFrameID &+= 1
        let firstSequence = nextSequence
        nextSequence &+= UInt32(count)
        let flags: FrameFlags = refresh ? .refresh : []
        let blockSize = fec.isEnabled ? Self.blockSize(pieces: count, limit: fec.maxBlockSize) : 0

        var fragments: [VideoFragment] = []
        fragments.reserveCapacity(count)
        let base = frame.count / count
        let extra = frame.count % count
        var offset = frame.startIndex
        for index in 0..<count {
            let size = base + (index < extra ? 1 : 0)
            fragments.append(VideoFragment(stream: stream, sequence: firstSequence &+ UInt32(index), frameID: frameID,
                                           index: UInt16(index), count: UInt16(count), flags: flags,
                                           fecBlockSize: UInt8(blockSize), payload: Data(frame[offset..<offset + size])))
            offset += size
        }

        var parity: [ParityFragment] = []
        if blockSize > 0 {
            let blocks = (count + blockSize - 1) / blockSize
            for block in 0..<blocks {
                let pieces = fragments[(block * blockSize)..<min((block + 1) * blockSize, count)]
                let parityCount = fec.parityCount(forBlockOf: pieces.count)
                guard parityCount > 0, let code = ReedSolomon(dataShards: pieces.count, parityShards: parityCount) else { continue }
                let length = pieces.map(\.payload.count).max() ?? 0
                guard let shards = code.encode(pieces.map { VideoFEC.shard($0.payload, length: length) }) else { continue }
                for (index, shard) in shards.enumerated() {
                    parity.append(ParityFragment(stream: stream, frameID: frameID, firstSequence: firstSequence,
                                                 count: UInt16(count), flags: flags, fecBlockSize: UInt8(blockSize),
                                                 block: UInt16(block), parityIndex: UInt8(index),
                                                 parityCount: UInt8(parityCount), shard: Data(shard)))
                }
            }
        }
        return Packetized(frameID: frameID, fragments: fragments, parity: parity)
    }

    /// Blocks as even as possible: 33 pieces with a limit of 32 make blocks of 17 and 16, not 32 and 1.
    static func blockSize(pieces: Int, limit: Int) -> Int {
        let blocks = (pieces + limit - 1) / limit
        return min((pieces + blocks - 1) / blocks, 255)
    }
}

/// A picture piece as an error-correction shard: its length (2 bytes), its bytes, then zeros, so pieces of different
/// lengths share one block and a rebuilt piece knows its own length.
nonisolated enum VideoFEC {
    /// `length` is the block's longest piece; callers never pass a longer one (it would be cut).
    static func shard(_ payload: Data, length: Int) -> [UInt8] {
        let size = min(payload.count, length)
        var shard = [UInt8](repeating: 0, count: length + 2)
        shard[0] = UInt8(truncatingIfNeeded: size >> 8)
        shard[1] = UInt8(truncatingIfNeeded: size)
        shard.replaceSubrange(2..<2 + size, with: payload.prefix(size))
        return shard
    }

    static func payload(fromShard shard: [UInt8]) -> Data? {
        guard shard.count >= 2 else { return nil }
        let length = Int(shard[0]) << 8 | Int(shard[1])
        guard length <= shard.count - 2 else { return nil }
        return Data(shard[2..<2 + length])
    }
}
