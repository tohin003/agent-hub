import Foundation
import Network
import Testing

/// The real sockets on localhost: the hello handshake, picture and sound one way, reports and app messages both ways,
/// strangers refused, the fallback when nobody answers, a re-hello moving the session, and silence noticed.
@Suite("UDP transport on loopback", .serialized)
struct UDPTransportTests {
    static func keys() throws -> TransportKeys {
        let (sessionID, key) = TransportKeys.generate()
        return try #require(TransportKeys(sessionID: sessionID, sessionKey: key))
    }

    @Test(.timeLimit(.minutes(1)))
    func pictureSoundAndReportsTravel() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let keys = try Self.keys()
        let session = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let hub = Inbox<SenderEvent>()
        session.setEventHandler { hub.append($0) }
        let client = UDPMediaClient(host: "127.0.0.1", port: port, keys: keys, network: .wifi)
        defer { client.close() }
        let phone = Inbox<ReceiverEvent>()
        let failures = Inbox<TransportError>()
        client.setHandlers(onEvent: { phone.append($0) }, onFailure: { failures.append($0) })
        let start = ContinuousClock.now
        try await client.connect(timeout: 1)
        let handshake = ContinuousClock.now - start
        #expect(hub.all.contains { $0.hello?.network == .wifi })

        let frame = Data((0..<30_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        #expect(session.sendVideo(frame, refresh: true) == .sent(frameID: 1))
        for index in 0..<10 {
            session.sendAudio(Data(repeating: UInt8(index), count: 160), timestamp: UInt64(index) * 10_000, duration: 10_000)
        }
        #expect(await eventually {
            phone.all.compactMap(\.assembledFrame).count == 1 && phone.all.flatMap(\.soundFrames).count == 10
        })
        #expect(phone.all.compactMap(\.assembledFrame).first?.data == frame)
        #expect(phone.all.flatMap(\.soundFrames).map(\.sequence) == Array(1...10))
        #expect(await eventually { session.snapshot.stats.feedbackReceived > 0 && session.snapshot.roundTrip != nil },
                "the phone's arrival reports reach the hub")

        try client.sendAppMessage(AppMessage(channel: 1, data: Data(#"{"refresh":true}"#.utf8)))
        let pointer = CursorPositionMessage(displayID: 1, x: 0.5, y: 0.25, visible: true, shapeID: 3)
        try session.sendAppMessage(AppMessage(channel: 2, data: pointer.encoded()))
        #expect(await eventually { hub.all.contains { $0.appMessage?.channel == 1 } })
        #expect(await eventually { phone.all.contains { $0.appMessage.flatMap { CursorPositionMessage.parse($0.data) } == pointer } })

        // Nothing else flowing: both sides still send at least every 20 ms (keepalives, reports).
        let fromPhone = session.snapshot.stats.packetsReceived
        let toPhone = client.snapshot.stats.packetsReceived
        try await Task.sleep(for: .milliseconds(400))
        let phoneSent = session.snapshot.stats.packetsReceived - fromPhone
        let hubSent = client.snapshot.stats.packetsReceived - toPhone
        reportMetric("loopback: hello answered in \(handshake); in 400 quiet ms the phone sent \(phoneSent) packets and the hub \(hubSent)")
        #expect(phoneSent >= 16 && hubSent >= 16, "at least one packet per 20 ms each way (\(phoneSent), \(hubSent))")
        #expect(failures.all.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func strangersAreIgnored() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let keys = try Self.keys()
        let session = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let raw = try await Self.rawConnection(port: port)
        defer { raw.cancel() }
        raw.send(content: Data("hello?".utf8), completion: .idempotent)
        var stranger = PacketSealer(keys: try #require(TransportKeys(sessionID: keys.sessionID &+ 1, sessionKey: Data(count: 32))),
                                    direction: .phoneToHub)
        raw.send(content: try stranger.seal(.hello(TransportHello(nonce: 1, network: .wifi)), sendTime: 0).datagram,
                 completion: .idempotent)
        var forger = PacketSealer(keys: try #require(TransportKeys(sessionID: keys.sessionID, sessionKey: Data(repeating: 9, count: 32))),
                                  direction: .phoneToHub)
        raw.send(content: try forger.seal(.hello(TransportHello(nonce: 2, network: .wifi)), sendTime: 0).datagram,
                 completion: .idempotent)
        var phone = PacketSealer(keys: keys, direction: .phoneToHub)
        let hello = try phone.seal(.hello(TransportHello(nonce: 3, network: .cellular)), sendTime: 0).datagram
        raw.send(content: hello, completion: .idempotent)
        #expect(await eventually { session.snapshot.connected })
        raw.send(content: hello, completion: .idempotent)
        #expect(await eventually {
            let stats = session.snapshot.stats
            return stats.rejected[.unauthenticated] == 1 && stats.rejected[.replayed] == 1 && server.counters.unrouted == 2
        })
        #expect(session.snapshot.network == .cellular, "only the genuine hello counted")
        #expect(session.snapshot.stats.packetsReceived == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func noAnswerFallsBackWithinASecond() async throws {
        // A hub socket that doesn't know the session: every hello goes unanswered.
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let client = UDPMediaClient(host: "127.0.0.1", port: port, keys: try Self.keys(), network: .wifi)
        let start = ContinuousClock.now
        await #expect(throws: TransportError.noAnswer) { try await client.connect(timeout: 1) }
        let waited = ContinuousClock.now - start
        reportMetric("no answer: the phone gave up on UDP after \(waited), having said hello \(server.counters.unrouted) times")
        #expect(waited >= .milliseconds(950) && waited < .milliseconds(1_500))
        #expect(server.counters.unrouted >= 5, "a hello every 200 ms")
    }

    @Test(.timeLimit(.minutes(1)))
    func aTailnetOnlyHubRefusesLoopback() async throws {
        let server = UDPMediaServer(host: "127.0.0.1", policy: .tailnet)
        let port = try await server.start()
        defer { server.stop() }
        let keys = try Self.keys()
        _ = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let client = UDPMediaClient(host: "127.0.0.1", port: port, keys: keys, network: .wifi)
        await #expect(throws: TransportError.noAnswer) { try await client.connect(timeout: 0.5) }
        #expect(server.counters.refused >= 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewNetworkMovesTheSessionToTheNewSocket() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let keys = try Self.keys()
        let session = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let client = UDPMediaClient(host: "127.0.0.1", port: port, keys: keys, network: .wifi)
        defer { client.close() }
        let phone = Inbox<ReceiverEvent>()
        client.setHandlers(onEvent: { phone.append($0) }, onFailure: { _ in })
        try await client.connect(timeout: 1)
        let first = try #require(session.snapshot.peer)
        client.networkChanged(to: .cellular)
        #expect(await eventually { session.snapshot.network == .cellular && session.snapshot.peer != first })
        let moved = session.snapshot.peer
        #expect(session.sendVideo(Data(repeating: 5, count: 5_000), refresh: true) == .sent(frameID: 1))
        #expect(await eventually { phone.all.compactMap(\.assembledFrame).count == 1 })
        reportMetric("re-hello moved the session from \(first) to \(moved ?? "nowhere")")
    }

    /// The hub's session ends (its socket stays open, as over Tailscale, where nothing answers a closed port): the
    /// phone notices after 3 s without a packet.
    @Test(.timeLimit(.minutes(1)))
    func silenceIsReported() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let keys = try Self.keys()
        let session = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let client = UDPMediaClient(host: "127.0.0.1", port: port, keys: keys, network: .wifi)
        defer { client.close() }
        let failures = Inbox<TransportError>()
        client.setHandlers(onEvent: { _ in }, onFailure: { failures.append($0) })
        try await client.connect(timeout: 1)
        let stopped = ContinuousClock.now
        session.close()
        #expect(await eventually(within: 6) { failures.all == [.silent] })
        let noticed = ContinuousClock.now - stopped
        reportMetric("the hub went quiet: the phone noticed after \(noticed)")
        #expect(noticed >= .milliseconds(2_900) && noticed < .milliseconds(4_500))
    }

    /// A plain UDP socket to the hub, ready to send.
    static func rawConnection(port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .udp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    connection?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.raw"))
        }
        return connection
    }
}

/// Collects what arrives on another queue.
final class Inbox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Polls a condition every 10 ms until it holds or the time is up.
func eventually(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

extension ReceiverEvent {
    var assembledFrame: FrameAssembler.AssembledFrame? {
        if case .frame(let frame) = self { return frame }
        return nil
    }

    var soundFrames: [ReceivedAudioFrame] {
        if case .audio(let frames) = self { return frames }
        return []
    }

    var appMessage: AppMessage? {
        if case .appMessage(let message) = self { return message }
        return nil
    }
}

extension SenderEvent {
    var appMessage: AppMessage? {
        if case .appMessage(let message) = self { return message }
        return nil
    }

    var hello: TransportHello? {
        if case .hello(let hello) = self { return hello }
        return nil
    }
}
