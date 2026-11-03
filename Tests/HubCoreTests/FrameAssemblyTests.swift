import Foundation
import Testing

/// Pictures split into pieces on the hub and put back together on the phone: reordering, repeats, losses, parity,
/// deadlines, and never a frame shown on top of a lost one.
@Suite("Frame assembly")
struct FrameAssemblyTests {
    static func bytes(_ seed: Int, _ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ seed &* 101) })
    }

    /// Frames of the given sizes; `refresh` holds the indexes of refresh frames.
    static func frames(_ sizes: [Int], refresh: Set<Int> = [0], fec: FECSettings = .none) throws -> [VideoPacketizer.Packetized] {
        var packetizer = VideoPacketizer()
        return try sizes.enumerated().map { index, size -> VideoPacketizer.Packetized in
            let frame = packetizer.packetize(bytes(index, size), refresh: refresh.contains(index), fec: fec)
            return try #require(frame)
        }
    }

    static func assembler(deadline: Int64 = 100_000) -> FrameAssembler {
        var settings = FrameAssembler.Settings()
        settings.frameDeadline = deadline
        return FrameAssembler(settings: settings)
    }

    @Test func piecesComeBackAsTheFrame() throws {
        let limit = VideoFragment.maxPayloadSize
        for size in [1, limit, limit + 1, 50_000, 300_000] {
            var packetizer = VideoPacketizer()
            let data = Self.bytes(size, size)
            let packetized = packetizer.packetize(data, refresh: true, fec: .none)
            let frame = try #require(packetized)
            let lengths = frame.fragments.map(\.payload.count)
            #expect(frame.fragments.count == (size + limit - 1) / limit)
            #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1, "pieces are even")
            #expect(frame.fragments.map(\.sequence) == Array(1...UInt32(frame.fragments.count)))
            let assembler = FrameAssembler()
            let events = frame.fragments.flatMap { assembler.add($0, now: 0) }
            #expect(events.count == 1 && events.first?.frame?.data == data)
            #expect(assembler.pendingFrames == 0 && !assembler.awaitingRefresh)
        }
        var packetizer = VideoPacketizer()
        #expect(packetizer.packetize(Data(), refresh: true, fec: .none) == nil)
        #expect(packetizer.packetize(Data(count: VideoPacketizer.maxFrameSize + 1), refresh: true, fec: .none) == nil)
    }

    @Test func reorderedAndRepeatedPiecesMakeEachFrameOnce() throws {
        let frames = try Self.frames([20_000, 7_000, 15_000, 3_000])
        var pieces = frames.flatMap(\.fragments)
        pieces += pieces.filter { $0.index % 3 == 0 }
        var random = SeededGenerator(seed: 21)
        pieces.shuffle(using: &random)
        let assembler = FrameAssembler()
        let events = pieces.flatMap { assembler.add($0, now: 0) }
        let shown = events.compactMap(\.frame)
        #expect(shown.map(\.frameID) == [1, 2, 3, 4], "in order, once each")
        #expect(shown.map(\.data) == (0..<4).map { Self.bytes($0, [20_000, 7_000, 15_000, 3_000][$0]) })
    }

    @Test func aLaterFrameWaitsForTheOneBefore() throws {
        let frames = try Self.frames([5_000, 5_000, 5_000])
        let assembler = FrameAssembler()
        #expect(frames[0].fragments.flatMap { assembler.add($0, now: 0) }.compactMap(\.frame).map(\.frameID) == [1])
        #expect(frames[2].fragments.flatMap { assembler.add($0, now: 1_000) }.isEmpty, "frame 3 needs frame 2")
        let events = frames[1].fragments.flatMap { assembler.add($0, now: 2_000) }
        #expect(events.compactMap(\.frame).map(\.frameID) == [2, 3])
    }

    /// Frame 2 misses a piece: at its deadline it's lost, frames 3 and 4 (which need it) are skipped, and frame 5, a
    /// refresh frame, starts the picture again.
    @Test func aLostFrameHoldsEverythingUntilARefreshFrame() throws {
        let frames = try Self.frames([3_000, 6_000, 3_000, 3_000, 4_000], refresh: [0, 4])
        let assembler = Self.assembler(deadline: 100_000)
        #expect(frames[0].fragments.flatMap { assembler.add($0, now: 0) }.compactMap(\.frame).count == 1)
        var events = frames[1].fragments.dropLast().flatMap { assembler.add($0, now: 10_000) }
        events += frames[2].fragments.flatMap { assembler.add($0, now: 20_000) }
        events += frames[3].fragments.flatMap { assembler.add($0, now: 30_000) }
        #expect(events.isEmpty)
        #expect(assembler.nextDeadline == 110_000)
        #expect(assembler.expire(now: 109_999).isEmpty)
        let expired = assembler.expire(now: 110_000)
        #expect(expired == [.lost(frameID: 2, lastSequence: frames[1].lastSequence),
                            .skipped(frameID: 3, lastSequence: frames[2].lastSequence),
                            .skipped(frameID: 4, lastSequence: frames[3].lastSequence)])
        #expect(assembler.awaitingRefresh)
        let refreshed = frames[4].fragments.flatMap { assembler.add($0, now: 120_000) }
        #expect(refreshed.compactMap(\.frame).map(\.frameID) == [5])
        #expect(!assembler.awaitingRefresh)
        #expect(assembler.stats == FrameAssembler.Stats(delivered: 2, lost: 1, skipped: 2, recoveredFragments: 0))
    }

    @Test func aCompleteRefreshFrameEndsTheWaitAtOnce() throws {
        let frames = try Self.frames([3_000, 6_000, 4_000], refresh: [0, 2])
        let assembler = Self.assembler()
        _ = frames[0].fragments.flatMap { assembler.add($0, now: 0) }
        _ = frames[1].fragments.dropFirst().flatMap { assembler.add($0, now: 5_000) }
        let events = frames[2].fragments.flatMap { assembler.add($0, now: 6_000) }
        #expect(events.map(\.summary) == ["skipped 2", "frame 3"], "no waiting for frame 2's deadline")
        #expect(assembler.stats.lost == 0 && !assembler.awaitingRefresh)
        #expect(frames[1].fragments.flatMap { assembler.add($0, now: 7_000) }.isEmpty, "late pieces of a skipped frame")
    }

    /// 8 pieces with 25% parity (2 shards): every pair of lost pieces is rebuilt, three are not.
    @Test func parityRebuildsAnyTwoOfEightPieces() throws {
        let frame = try #require(try Self.frames([8 * VideoFragment.maxPayloadSize - 100], fec: FECSettings(ratio: 0.25)).first)
        #expect(frame.fragments.count == 8 && frame.parity.count == 2)
        let original = Self.bytes(0, 8 * VideoFragment.maxPayloadSize - 100)
        for first in 0..<8 {
            for second in (first + 1)..<8 {
                let assembler = Self.assembler()
                var events: [FrameAssembler.Event] = []
                for fragment in frame.fragments where fragment.index != first && fragment.index != second {
                    events += assembler.add(fragment, now: 0)
                }
                for parity in frame.parity { events += assembler.add(parity, now: 1_000) }
                #expect(events.compactMap(\.frame).first?.data == original, "lost \(first) and \(second)")
                #expect(events.compactMap(\.frame).first?.recoveredFragments == 2)
                #expect(events.contains(.recovered(sequences: [UInt32(first + 1), UInt32(second + 1)])))
            }
        }
        let assembler = Self.assembler()
        var events = frame.fragments.dropFirst(3).flatMap { assembler.add($0, now: 0) }
        events += frame.parity.flatMap { assembler.add($0, now: 0) }
        #expect(events.isEmpty, "three losses are one too many")
        #expect(assembler.expire(now: 100_000).first == .lost(frameID: 1, lastSequence: 8))
    }

    @Test func parityAloneRebuildsAOnePieceFrame() throws {
        let frame = try #require(try Self.frames([600], fec: FECSettings(ratio: 0.1)).first)
        #expect(frame.fragments.count == 1 && frame.parity.count == 1, "the minimum one parity piece")
        let assembler = FrameAssembler()
        let events = frame.parity.flatMap { assembler.add($0, now: 0) }
        #expect(events.compactMap(\.frame).first?.data == Self.bytes(0, 600))
    }

    @Test func blocksAreEven() throws {
        let limit = VideoFragment.maxPayloadSize
        let fec = FECSettings(ratio: 0.2)
        let thirtyThree = try #require(try Self.frames([33 * limit], fec: fec).first)
        #expect(thirtyThree.fragments.first?.fecBlockSize == 17, "17 + 16, not 32 + 1")
        #expect(thirtyThree.parity.filter { $0.block == 0 }.count == 4 && thirtyThree.parity.filter { $0.block == 1 }.count == 4)
        let thirtyTwo = try #require(try Self.frames([32 * limit], fec: fec).first)
        #expect(thirtyTwo.fragments.first?.fecBlockSize == 32 && thirtyTwo.parity.count == 7)
        #expect(fec.parityCount(forBlockOf: 5) == 1, "5 × 20% is one, despite floating point")
        #expect(FECSettings(ratio: 0.1).parityCount(forBlockOf: 3) == 1)
        #expect(FECSettings.none.parityCount(forBlockOf: 10) == 0)
        // Every block of the 33-piece frame survives losing its parity count of pieces.
        let assembler = FrameAssembler()
        var events: [FrameAssembler.Event] = []
        for fragment in thirtyThree.fragments where ![0, 5, 9, 16, 17, 20, 30, 32].contains(Int(fragment.index)) {
            events += assembler.add(fragment, now: 0)
        }
        for parity in thirtyThree.parity { events += assembler.add(parity, now: 0) }
        #expect(events.compactMap(\.frame).first?.data == Self.bytes(0, 33 * limit))
    }

    /// A large frame trickling in on a slow path isn't given up while its pieces keep coming (up to 2 s); one that
    /// stops is, a deadline after its last piece.
    @Test func theDeadlineFollowsProgress() throws {
        let frames = try Self.frames([30 * VideoFragment.maxPayloadSize, 3_000], refresh: [0, 1])
        let assembler = Self.assembler(deadline: 100_000)
        var events: [FrameAssembler.Event] = []
        for (index, fragment) in frames[0].fragments.enumerated() {
            let now = Int64(index) * 60_000
            events += assembler.expire(now: now)
            events += assembler.add(fragment, now: now)
        }
        #expect(events.compactMap(\.frame).map(\.frameID) == [1], "1.74 s of pieces, 60 ms apart, all waited for")
        let stalled = frames[1].fragments.dropLast()
        _ = stalled.flatMap { assembler.add($0, now: 3_000_000) }
        #expect(assembler.expire(now: 3_099_999).isEmpty)
        #expect(assembler.expire(now: 3_100_000).first == .lost(frameID: 2, lastSequence: frames[1].lastSequence))

        // Past the 2 s cap, steady progress no longer keeps a frame.
        let slow = try Self.frames([40 * VideoFragment.maxPayloadSize])
        let capped = Self.assembler(deadline: 100_000)
        var lost: Int64?
        for (index, fragment) in slow[0].fragments.enumerated() {
            let now = Int64(index) * 60_000
            if lost == nil, capped.expire(now: now).contains(where: \.isLost) { lost = now }
            _ = capped.add(fragment, now: now)
        }
        #expect(lost == 2_040_000, "given up at the first check after 2 s")
    }

    @Test func aFrameNeverSeenGetsADeadlineFromTheReport() throws {
        let frames = try Self.frames([3_000])
        let assembler = Self.assembler(deadline: 100_000)
        _ = frames[0].fragments.flatMap { assembler.add($0, now: 0) }
        #expect(assembler.announce(lastFrameID: 2, now: 10_000).isEmpty)
        #expect(assembler.announce(lastFrameID: 1, now: 10_000).isEmpty, "an old frame changes nothing")
        #expect(assembler.expire(now: 110_000) == [.lost(frameID: 2, lastSequence: nil)])
    }

    @Test func theFirstFramesMayArriveOutOfOrder() throws {
        let frames = try Self.frames([4_000, 4_000])
        let assembler = FrameAssembler()
        var events = assembler.add(frames[1].fragments[0], now: 0)
        events += frames[0].fragments.flatMap { assembler.add($0, now: 1_000) }
        events += frames[1].fragments.dropFirst().flatMap { assembler.add($0, now: 2_000) }
        #expect(events.compactMap(\.frame).map(\.frameID) == [1, 2])
    }

    @Test func piecesThatContradictTheirFrameAreIgnored() throws {
        let frames = try Self.frames([5_000])
        let assembler = FrameAssembler()
        var forged = frames[0].fragments[1]
        forged.count = 9
        #expect(assembler.add(frames[0].fragments[0], now: 0).isEmpty)
        #expect(assembler.add(forged, now: 0).isEmpty)
        let events = frames[0].fragments.dropFirst().flatMap { assembler.add($0, now: 0) }
        #expect(events.compactMap(\.frame).first?.data == Self.bytes(0, 5_000))
    }

    @Test func aLongOutageGivesUpTheFramesOutsideTheWindow() throws {
        var settings = FrameAssembler.Settings()
        settings.maxPendingFrames = 8
        let assembler = FrameAssembler(settings: settings)
        let frames = try Self.frames(Array(repeating: 2_000, count: 30))
        _ = frames[0].fragments.flatMap { assembler.add($0, now: 0) }
        let events = frames[29].fragments.flatMap { assembler.add($0, now: 0) }
        #expect(events.filter(\.isLost).count == 21, "frames 2–22 fall outside the 8-frame window ending at 30")
        #expect(assembler.pendingFrames <= 8 && assembler.awaitingRefresh)
    }
}

extension FrameAssembler.Event {
    var frame: FrameAssembler.AssembledFrame? {
        if case .frame(let frame) = self { return frame }
        return nil
    }

    var isLost: Bool {
        if case .lost = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .frame(let frame): "frame \(frame.frameID)"
        case .lost(let frameID, _): "lost \(frameID)"
        case .skipped(let frameID, _): "skipped \(frameID)"
        case .recovered(let sequences): "recovered \(sequences)"
        }
    }
}
