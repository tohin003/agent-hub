import CryptoKit
import Foundation
import Testing

/// The UDP transport's packets: every kind through sealing and opening, the 1,200-byte limit, and the refusal of
/// changed, foreign and replayed packets.
@Suite("Transport packets")
struct TransportPacketTests {
    static func keys(_ sessionID: UInt32 = 0x1234_5678, seed: UInt8 = 7) throws -> TransportKeys {
        try #require(TransportKeys(sessionID: sessionID, sessionKey: Data((0..<32).map { UInt8($0) &* 13 &+ seed })))
    }

    static func report() -> SenderReport {
        SenderReport(path: .peerRelay, nack: true, roundTripMicros: 41_250, frameDeadlineMicros: 110_000,
                     targetBitrate: 4_500_000, lastVideoSequence: 0xFFFF_FFFE, lastFrameID: 77, lastAudioSequence: 9)
    }

    static func feedback() -> TransportFeedback {
        var builder = FeedbackBuilder()
        for (index, number) in [10, 11, 13, 14, 15, 19].enumerated() {
            builder.record(number: UInt64(number), arrival: 5_000_000 + Int64(index) * 1_337 + (index == 4 ? 90_000 : 0))
        }
        return builder.build(now: 6_000_000)[0]
    }

    static func everyKind() -> [TransportMessage] {
        [
            .hello(TransportHello(nonce: 0xABCD_0123, network: .cellular, wantsVideo: true, wantsAudio: false)),
            .helloAck(TransportHelloAck(nonce: 0xABCD_0123, report: report())),
            .keepalive(TransportKeepalive()),
            .keepalive(TransportKeepalive(report: report())),
            .probe(TransportProbe(cluster: 3, paddingSize: 900)),
            .video(VideoFragment(stream: 0, sequence: 0xFFFF_FFFF, frameID: 12, index: 2, count: 5, flags: [.refresh, .retransmission],
                                 fecBlockSize: 5, payload: Data((0..<700).map { UInt8(truncatingIfNeeded: $0) }))),
            .parity(ParityFragment(stream: 0, frameID: 12, firstSequence: 0xFFFF_FFFD, count: 5, flags: .refresh, fecBlockSize: 5,
                                   block: 0, parityIndex: 1, parityCount: 2, shard: Data(repeating: 0xA5, count: 702))),
            .audio(AudioBundle(stream: 1, sequence: 400, timestamp: 0x0102_0304_0506_0708, duration: 10_000,
                               frames: [Data(repeating: 1, count: 160), Data(repeating: 2, count: 150)])),
            .nack(TransportNack(stream: 0, sequences: [0xFFFF_FFF0, 0xFFFF_FFF1, 0xFFFF_FFFF, 0, 3, 40, 41, 1_000])),
            .feedback(feedback()),
            .app(AppMessage(channel: 1, data: Data(#"{"refresh":true}"#.utf8))),
        ]
    }

    @Test func everyKindRoundTrips() throws {
        let keys = try Self.keys()
        var sealer = PacketSealer(keys: keys, direction: .hubToPhone)
        var opener = PacketOpener(keys: keys, direction: .hubToPhone)
        for (index, message) in Self.everyKind().enumerated() {
            let sealed = try sealer.seal(message, sendTime: 0xFFFF_FF00 &+ UInt32(index))
            #expect(sealed.datagram.count == message.datagramSize, "the size is known before sealing")
            #expect(TransportWire.sessionID(of: sealed.datagram) == keys.sessionID)
            let opened = try opener.open(sealed.datagram).get()
            #expect(opened == TransportPacket(number: UInt64(index + 1), sendTime: 0xFFFF_FF00 &+ UInt32(index), message: message))
        }
    }

    @Test func nacksAndFeedbackKeepTheirNumbers() throws {
        let nack = TransportNack(stream: 0, sequences: [41, 3, 0, 0xFFFF_FFF1, 1_000, 40, 0xFFFF_FFF0, 0xFFFF_FFFF, 3])
        #expect(nack.sequences == [0xFFFF_FFF0, 0xFFFF_FFF1, 0xFFFF_FFFF, 0, 3, 40, 41, 1_000], "serial order across the wrap")
        #expect(nack.pairs.count == 4, "a number and the 16 after it per pair: FFF0–0, 3, 40–41, 1000")
        let run = TransportNack(stream: 0, sequences: Array(100...150))
        #expect(run.pairs.count == 3)

        let feedback = Self.feedback()
        #expect(feedback.baseNumber == 10)
        #expect(feedback.arrivals.count == 10)
        #expect(feedback.arrivals.map { $0 == nil } == [false, false, true, false, false, false, true, true, true, false])
        // Number 15 arrived 90 ms late, after 19: a negative delta, carried in two bytes.
        let exact: [Int64] = [5_000_000, 5_001_337, 5_002_674, 5_004_011, 5_095_348, 5_006_685]
        let reported = feedback.arrivals.compactMap { $0 }
        for (time, arrival) in zip(exact, reported) {
            #expect(abs(time - arrival) <= 125, "arrival times keep 250 µs")
        }
    }

    @Test func nothingExceedsTwelveHundredBytes() throws {
        let keys = try Self.keys()
        var sealer = PacketSealer(keys: keys, direction: .hubToPhone)
        let fullPiece = Data(repeating: 9, count: VideoFragment.maxPayloadSize)
        var packetizer = VideoPacketizer()
        let packetized = packetizer.packetize(Data(repeating: 3, count: VideoFragment.maxPayloadSize * 40), refresh: false,
                                              fec: FECSettings(ratio: 0.2))
        let frame = try #require(packetized)
        var sizes: [Int] = []
        for message in frame.fragments.map(TransportMessage.video) + frame.parity.map(TransportMessage.parity) {
            sizes.append(try sealer.seal(message, sendTime: 0).datagram.count)
        }
        #expect(sizes.max() == TransportWire.maxDatagramSize, "full pieces and their parity fill a datagram exactly")
        var feedbackBuilder = FeedbackBuilder()
        for number in 0..<UInt64(FeedbackBuilder.maxPacketsPerFeedback) {
            feedbackBuilder.record(number: number, arrival: Int64(number) * 70_000)
        }
        let fullReports = feedbackBuilder.build(now: 0)
        let largest: [TransportMessage] = [
            .video(VideoFragment(stream: 0, sequence: 1, frameID: 1, index: 0, count: 1, flags: [], fecBlockSize: 0,
                                 payload: fullPiece)),
            .probe(TransportProbe(cluster: 1, paddingSize: Int.max)),
            .app(AppMessage(channel: 2, data: Data(count: AppMessage.maxDataSize))),
            .nack(TransportNack(stream: 0, sequences: (0..<UInt32(TransportNack.maxPairs)).map { $0 * 20 })),
            .feedback(try #require(fullReports.first)),
        ]
        for message in largest {
            #expect(try sealer.seal(message, sendTime: 0).datagram.count <= TransportWire.maxDatagramSize)
        }
        #expect(throws: TransportError.tooLarge) {
            try sealer.seal(.app(AppMessage(channel: 2, data: Data(count: AppMessage.maxDataSize + 1))), sendTime: 0)
        }
        var opener = PacketOpener(keys: keys, direction: .hubToPhone)
        #expect(opener.open(Data(count: TransportWire.overhead - 1)) == .failure(.malformed))
        #expect(opener.open(Data(count: TransportWire.maxDatagramSize + 1)) == .failure(.malformed))
    }

    /// Every single-bit change anywhere in a packet is refused, and nothing is accepted from it.
    @Test func changedPacketsAreRefused() throws {
        let keys = try Self.keys()
        var sealer = PacketSealer(keys: keys, direction: .phoneToHub)
        let original = try sealer.seal(.app(AppMessage(channel: 1, data: Data("tap at 0.25, 0.75".utf8))), sendTime: 99).datagram
        var refused: [PacketRejection: Int] = [:]
        for index in 0..<original.count {
            for bit in [0, 3, 7] {
                var changed = original
                changed[changed.startIndex + index] ^= 1 << UInt8(bit)
                var opener = PacketOpener(keys: keys, direction: .phoneToHub)
                switch opener.open(changed) {
                case .success:
                    Issue.record("a changed packet was accepted (byte \(index), bit \(bit))")
                case .failure(let rejection):
                    refused[rejection, default: 0] += 1
                }
            }
        }
        // The version byte (3 flips), the session id (4 bytes × 3), packet number 1 turned into 0 (malformed), and
        // everything else fails the tag.
        #expect(refused[.wrongVersion] == 3 && refused[.foreignSession] == 12 && refused[.malformed] == 1)
        #expect(refused[.unauthenticated] == original.count * 3 - 16)
        var opener = PacketOpener(keys: keys, direction: .phoneToHub)
        #expect((try? opener.open(original).get()) != nil, "the untouched packet still opens")
    }

    @Test func foreignKeysSessionsAndDirectionsAreRefused() throws {
        let keys = try Self.keys()
        var mine = PacketOpener(keys: keys, direction: .phoneToHub)
        var otherKey = PacketSealer(keys: try Self.keys(seed: 8), direction: .phoneToHub)
        #expect(mine.open(try otherKey.seal(.keepalive(TransportKeepalive()), sendTime: 0).datagram) == .failure(.unauthenticated))
        var otherSession = PacketSealer(keys: try Self.keys(0x0BAD_F00D), direction: .phoneToHub)
        #expect(mine.open(try otherSession.seal(.keepalive(TransportKeepalive()), sendTime: 0).datagram) == .failure(.foreignSession))
        // The hub's own packet reflected back at it.
        var hub = PacketSealer(keys: keys, direction: .hubToPhone)
        #expect(mine.open(try hub.seal(.keepalive(TransportKeepalive()), sendTime: 0).datagram) == .failure(.unauthenticated))
        #expect(TransportKeys(sessionID: 0, sessionKey: Data(count: 32)) == nil)
        #expect(TransportKeys(sessionID: 1, sessionKey: Data(count: 16)) == nil)
    }

    @Test func replaysAreRefused() throws {
        let keys = try Self.keys()
        var sealer = PacketSealer(keys: keys, direction: .hubToPhone)
        let packets = try (0..<6000).map { _ in try sealer.seal(.keepalive(TransportKeepalive()), sendTime: 0).datagram }
        var opener = PacketOpener(keys: keys, direction: .hubToPhone)
        #expect((try? opener.open(packets[10]).get()) != nil)
        #expect(opener.open(packets[10]) == .failure(.replayed))
        #expect((try? opener.open(packets[3]).get()) != nil, "late but not seen: accepted")
        #expect(opener.open(packets[3]) == .failure(.replayed))
        #expect((try? opener.open(packets[5999]).get()) != nil)
        #expect(opener.open(packets[5999 - Int(ReplayWindow.size)]) == .failure(.tooOld))
        #expect((try? opener.open(packets[5999 - Int(ReplayWindow.size) + 1]).get()) != nil, "the window's oldest number")
        #expect(opener.open(packets[10]) == .failure(.tooOld))

        var window = ReplayWindow()
        for number: UInt64 in [5, 1, 4, 4096, 9000] where window.check(number) == .fresh { window.accept(number) }
        #expect(window.check(5) == .tooOld && window.check(4096) == .tooOld, "9000 moved the window past them")
        #expect(window.check(9000) == .duplicate && window.check(8999) == .fresh && window.check(9001) == .fresh)
    }

    /// The cost of sealing and opening a full datagram with ChaCha20-Poly1305 (debug build, so an upper bound).
    @Test func sealingAFullPacketIsCheap() throws {
        let keys = try Self.keys()
        var sealer = PacketSealer(keys: keys, direction: .hubToPhone)
        var opener = PacketOpener(keys: keys, direction: .hubToPhone)
        let message = TransportMessage.video(VideoFragment(stream: 0, sequence: 1, frameID: 1, index: 0, count: 1, flags: [],
                                                           fecBlockSize: 0, payload: Data(repeating: 7, count: VideoFragment.maxPayloadSize)))
        let count = 20_000
        var datagrams: [Data] = []
        datagrams.reserveCapacity(count)
        let sealStart = ContinuousClock.now
        for _ in 0..<count { datagrams.append(try sealer.seal(message, sendTime: 0).datagram) }
        let sealTime = ContinuousClock.now - sealStart
        let openStart = ContinuousClock.now
        var opened = 0
        for datagram in datagrams where (try? opener.open(datagram).get()) != nil { opened += 1 }
        let openTime = ContinuousClock.now - openStart
        let sealMicros = sealTime / count / .microseconds(1)
        let openMicros = openTime / count / .microseconds(1)
        reportMetric(String(format: "ChaCha20-Poly1305, 1,200-byte packets: seal %.2f µs, open %.2f µs (debug build)",
                            sealMicros, openMicros))
        #expect(opened == count)
        #expect(sealMicros < 50 && openMicros < 50, "≈1,000 packets/s at 10 Mbit/s costs well under 5% of a core")
    }

    @Test func negotiationTravelsAsJSON() throws {
        #expect(Method.screenTransport == "screen.transport")
        let (sessionID, key) = TransportKeys.generate()
        #expect(sessionID != 0 && key.count == 32)
        #expect(TransportKeys.generate().sessionKey != key, "a new key every time")
        let params = ScreenTransportParams(network: .cellular)
        let decodedParams = try WireCoding.decoder.decode(ScreenTransportParams.self, from: WireCoding.encoder.encode(params))
        #expect(decodedParams == params && params.versions == [1] && params.audioCodecs == ["opus"])
        let result = ScreenTransportResult(host: "100.101.102.105", port: 50_000, sessionId: sessionID, key: key, path: .derp,
                                           profile: .profile(for: .derp), audio: .opus)
        let json = try JSONValue(encoding: result)
        #expect(json["key"]?.stringValue == key.base64EncodedString())
        let decoded = try json.decode(ScreenTransportResult.self)
        #expect(decoded == result)
        #expect(decoded.keys?.sessionID == sessionID)
    }
}
