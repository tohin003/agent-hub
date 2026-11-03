import Foundation
import Testing

/// Resend requests (when, how often, when to stop), the hub's resend buffer, the policy that picks resends and/or
/// parity per path, and sound copies.
@Suite("Loss recovery")
struct LossRecoveryTests {
    static let deadline: Int64 = 500_000

    /// A gap is asked about after the reorder wait, twice 4 ms apart, then again a round trip (× 1.25 + 5 ms) later.
    @Test func aGapIsAskedAboutOnTimeAndAgainARoundTripLater() {
        var nack = NackGenerator()
        for sequence: UInt32 in [1, 2, 5] { nack.received(sequence, now: 0, deadline: Self.deadline) }
        #expect(nack.missingCount == 2)
        #expect(nack.due(now: 2_999, roundTrip: 40_000).isEmpty, "packets reordered by a few ms aren't lost")
        #expect(nack.due(now: 3_000, roundTrip: 40_000) == [3, 4])
        #expect(nack.due(now: 6_999, roundTrip: 40_000).isEmpty)
        #expect(nack.due(now: 7_000, roundTrip: 40_000) == [3, 4], "the second copy")
        // Next round: 7 ms + (40 × 1.25 + 5 − 4) ms = 58 ms.
        #expect(nack.nextWakeup == 58_000)
        #expect(nack.due(now: 57_999, roundTrip: 40_000).isEmpty)
        nack.received(3, now: 50_000, deadline: Self.deadline)
        #expect(nack.due(now: 58_000, roundTrip: 40_000) == [4], "3 came back")
        #expect(nack.stats.requested == 5)
    }

    @Test func givesUpAfterItsRoundsOrTheDeadline() {
        var nack = NackGenerator()
        nack.received(10, now: 0, deadline: 1_000_000)
        nack.received(12, now: 0, deadline: 1_000_000)
        var rounds = 0
        var now: Int64 = 0
        while let wakeup = nack.nextWakeup, rounds < 100 {
            now = wakeup
            if !nack.due(now: now, roundTrip: 20_000).isEmpty { rounds += 1 }
        }
        #expect(rounds == 8, "4 rounds of 2 copies")
        #expect(nack.stats.gaveUp == 1 && nack.missingCount == 0)

        var short = NackGenerator()
        short.received(1, now: 0, deadline: 30_000)
        short.received(3, now: 0, deadline: 30_000)
        #expect(short.due(now: 3_000, roundTrip: 100_000) == [2])
        #expect(short.due(now: 30_000, roundTrip: 100_000).isEmpty, "past the frame's deadline")
        #expect(short.missingCount == 0 && short.stats.gaveUp == 1)
    }

    @Test func theTailOfAFrameIsFoundFromItsSize() {
        var nack = NackGenerator()
        nack.received(100, now: 0, deadline: Self.deadline)
        nack.received(101, now: 1_000, deadline: Self.deadline)
        // The frame has pieces up to 104; nothing more came.
        nack.expect(through: 104, now: 10_000, wait: 0, deadline: Self.deadline)
        #expect(nack.due(now: 10_000, roundTrip: 30_000) == [102, 103, 104])
        nack.expect(through: 103, now: 11_000, wait: 0, deadline: Self.deadline)
        #expect(nack.missingCount == 3, "already known")
        nack.forget(through: 103)
        #expect(nack.missingCount == 1 && nack.isMissing(104))
    }

    @Test func anOutageIsNotAskedAboutPieceByPiece() {
        var nack = NackGenerator()
        nack.received(1, now: 0, deadline: Self.deadline)
        nack.received(3, now: 0, deadline: Self.deadline)
        nack.received(5_000, now: 0, deadline: Self.deadline)
        #expect(nack.missingCount == 0 && nack.highest == 5_000)
    }

    @Test func sequenceNumbersWrap() {
        var nack = NackGenerator()
        nack.received(0xFFFF_FFFE, now: 0, deadline: Self.deadline)
        nack.received(1, now: 0, deadline: Self.deadline)
        #expect(nack.due(now: 3_000, roundTrip: 30_000) == [0xFFFF_FFFF, 0])
        nack.received(0xFFFF_FFFF, now: 4_000, deadline: Self.deadline)
        nack.forget(through: 0)
        #expect(nack.missingCount == 0)
    }

    @Test func theHubResendsOncePerRoundTripAndNotPastTheDeadline() {
        var buffer = RetransmitBuffer()
        let piece = VideoFragment(stream: 0, sequence: 7, frameID: 2, index: 0, count: 1, flags: .refresh, fecBlockSize: 0,
                                  payload: Data(repeating: 1, count: 1000))
        buffer.store(piece, sentAt: 0, deadline: 200_000)
        #expect(buffer.resends(for: [7], now: 20_000, roundTrip: 40_000).isEmpty, "sooner than ¾ of a round trip")
        let first = buffer.resends(for: [7, 8], now: 45_000, roundTrip: 40_000)
        #expect(first.count == 1 && first[0].fragment.flags == [.refresh, .retransmission] && first[0].deadline == 200_000)
        #expect(buffer.resends(for: [7], now: 49_000, roundTrip: 40_000).isEmpty, "the request's second copy")
        #expect(buffer.resends(for: [7], now: 100_000, roundTrip: 40_000).count == 1)
        #expect(buffer.resends(for: [7], now: 200_000, roundTrip: 40_000).isEmpty, "the phone gave up on it")
    }

    @Test func theResendBufferKeepsASecondAndAtMostFourMegabytes() {
        var buffer = RetransmitBuffer()
        for sequence in 0..<UInt32(5000) {
            buffer.store(VideoFragment(stream: 0, sequence: sequence, frameID: sequence, index: 0, count: 1, flags: [],
                                       fecBlockSize: 0, payload: Data(count: 1000)),
                         sentAt: Int64(sequence) * 100, deadline: 10_000_000)
        }
        #expect(buffer.bytes <= 4 << 20 && buffer.count == 4194)
        // The newest went out at 499.9 ms, the one before at 499.8 ms.
        buffer.evict(now: 1_499_900)
        #expect(buffer.count == 1, "only the newest is at most a second old")
    }

    @Test func thePolicyPicksResendsOrParityByPath() {
        let direct = PathProfile.profile(for: .direct)
        let relay = PathProfile.profile(for: .peerRelay)
        let derp = PathProfile.profile(for: .derp)

        let home = RecoveryPolicy.plan(profile: direct, network: .wifi, roundTripMs: 30, lossRate: 0.03)
        #expect(home.nack && home.fec.ratio == 0 && home.audioRedundancy == 0, "direct: resend, no parity")
        #expect(home.frameDeadline == 85_000)
        let phoneOnCellular = RecoveryPolicy.plan(profile: direct, network: .cellular, roundTripMs: 60, lossRate: 0.01)
        #expect(phoneOnCellular.fec.ratio == 0.10 && phoneOnCellular.audioRedundancy == 1)

        let relayed = RecoveryPolicy.plan(profile: relay, network: .wifi, roundTripMs: 60, lossRate: 0.02)
        #expect(relayed.nack && relayed.fec.ratio == 0.10 && relayed.frameDeadline == 150_000)
        let lossyRelay = RecoveryPolicy.plan(profile: relay, network: .wifi, roundTripMs: 60, lossRate: 0.10)
        #expect(lossyRelay.fec.ratio == 0.20 && lossyRelay.opusExpectedLossPercent == 10, "parity follows the loss, up to 20%")
        let farRelay = RecoveryPolicy.plan(profile: relay, network: .wifi, roundTripMs: 250, lossRate: 0)
        #expect(!farRelay.nack && farRelay.frameDeadline == 80_000, "resends would come too late: wait only for reordering")

        let viaDerp = RecoveryPolicy.plan(profile: derp, network: .wifi, roundTripMs: 300, lossRate: 0.05)
        #expect(!viaDerp.nack && viaDerp.audioRedundancy == 2)
        #expect(viaDerp.fec.ratio == 0.30, "no resends: parity follows 6× the loss (5% → 30%)")
        #expect(RecoveryPolicy.plan(profile: derp, network: .wifi, roundTripMs: 300, lossRate: 0.01).fec.ratio == 0.20)
        #expect(viaDerp.frameDeadline == 120_000, "no resends: the deadline only covers reordering and jitter")
        #expect(RecoveryPolicy.plan(profile: derp, network: .wifi, roundTripMs: 300, lossRate: 0.4).fec.ratio == 0.30)
        let nearDerp = RecoveryPolicy.plan(profile: derp, network: .wifi, roundTripMs: 100, lossRate: 0)
        #expect(nearDerp.nack && nearDerp.frameDeadline == 210_000, "a close DERP server: resends fit, 1.5 round trips + 60 ms")
        #expect(!RecoveryPolicy.plan(profile: derp, network: .wifi, roundTripMs: nil, lossRate: 0).nack,
                "300 ms assumed until measured")
    }

    /// 10% of sound packets lost (some back to back): with one copy per packet almost every frame still arrives, each
    /// once, with its own time.
    @Test(arguments: [0, 1, 2])
    func soundCopiesStandInForLostPackets(redundancy: Int) throws {
        var packetizer = AudioPacketizer(redundancy: redundancy)
        var depacketizer = AudioDepacketizer()
        var random = SeededGenerator(seed: 31)
        var received: [ReceivedAudioFrame] = []
        let total = 2000
        for index in 0..<total {
            let packetized = packetizer.packetize(Data(repeating: UInt8(index % 251), count: 120),
                                                  timestamp: 1_000_000 + UInt64(index) * 10_000, duration: 10_000)
            let bundle = try #require(packetized)
            #expect(bundle.frames.count == min(index, redundancy) + 1)
            guard !random.chance(0.10) else { continue }
            received += depacketizer.unpack(bundle)
        }
        let sequences = received.map(\.sequence)
        #expect(Set(sequences).count == sequences.count, "each frame once")
        for frame in received {
            #expect(frame.data.first == UInt8(Int(frame.sequence - 1) % 251))
            #expect(frame.timestamp == 1_000_000 + UInt64(frame.sequence - 1) * 10_000)
        }
        let share = Double(received.count) / Double(total)
        let copies = received.filter(\.fromRedundancy).count
        reportMetric("sound with \(redundancy) earlier frame(s) copied into each packet, 10% of packets lost: "
            + String(format: "%.1f%% of frames arrive (%ld from copies)", share * 100, copies))
        #expect(share >= [0.88, 0.985, 0.997][redundancy])
    }

    @Test func soundTooLargeForAPacketIsRefused() {
        var packetizer = AudioPacketizer(redundancy: 2)
        #expect(packetizer.packetize(Data(count: TransportWire.maxPayloadSize), timestamp: 0, duration: 10_000) == nil)
        #expect(packetizer.packetize(Data(), timestamp: 0, duration: 10_000) == nil)
        let big = Data(count: 600)
        _ = packetizer.packetize(big, timestamp: 0, duration: 10_000)
        let bundle = packetizer.packetize(big, timestamp: 10_000, duration: 10_000)
        #expect(bundle?.frames.count == 1, "a copy that wouldn't fit is left out")
        #expect(bundle?.sequence == 2, "a refused frame takes no number")
    }
}
