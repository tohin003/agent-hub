import Foundation
import Network

// The sockets around `MediaSender` (hub) and `MediaReceiver` (phone): Network.framework UDP, one serial queue each, a
// timer that wakes when the state machine next has something to do. Every packet is sealed, so the address a phone's
// hello comes from is where its picture goes, until a newer hello (after a network change) moves it.

// MARK: Hub

/// The hub's UDP socket: listens on the Mac's tailnet address only, drops anything not from a tailnet device (or
/// loopback, as the WebSocket server allows), and routes each datagram to its session by the session id in its clear
/// header. A session's phone is whoever sent its latest authenticated hello.
nonisolated public final class UDPMediaServer: @unchecked Sendable {
    nonisolated public enum AddressPolicy: Sendable {
        /// Tailscale's ranges only.
        case tailnet
        /// Tailscale's ranges and loopback.
        case tailnetOrLoopback

        func allows(_ address: String) -> Bool {
            switch self {
            case .tailnet: TailnetAddress.isTailnet(address)
            case .tailnetOrLoopback: TailnetAddress.isTailnet(address) || TailnetAddress.isLoopback(address)
            }
        }
    }

    public let host: String
    let queue = DispatchQueue(label: "agenthub.transport.hub", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let requestedPort: UInt16
    private let policy: AddressPolicy
    // Everything below is touched only on `queue`.
    private var listener: NWListener?
    private var starting: CheckedContinuation<UInt16, Error>?
    private var sessions: [UInt32: UDPServerSession] = [:]
    private var connections: [ObjectIdentifier: Tracked] = [:]
    private var sweep: DispatchSourceTimer?
    private var unrouted = 0
    private var refused = 0

    nonisolated private struct Tracked {
        let connection: NWConnection
        var lastActive: Int64
    }

    /// `host` is the Mac's tailnet address (from `TailnetGuard`); port 0 picks a free one.
    public init(host: String, port: UInt16 = 0, policy: AddressPolicy = .tailnetOrLoopback) {
        self.host = host
        requestedPort = port
        self.policy = policy
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { self.listen(continuation) }
        }
    }

    public func stop() {
        perform {
            for session in sessions.values { session.shutDown() }
            sessions.removeAll()
            for tracked in connections.values { tracked.connection.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            sweep?.cancel()
            sweep = nil
            starting?.resume(throwing: TransportError.closed)
            starting = nil
        }
    }

    /// A session for a phone that just asked for one over the WebSocket (`screen.transport`).
    public func makeSession(keys: TransportKeys, profile: PathProfile,
                            settings: MediaSender.Settings = MediaSender.Settings()) -> UDPServerSession {
        let session = UDPServerSession(sender: MediaSender(keys: keys, profile: profile, settings: settings), server: self)
        perform { sessions[keys.sessionID] = session }
        return session
    }

    /// Datagrams for no known session, and connections refused for their address.
    public var counters: (unrouted: Int, refused: Int) { perform { (unrouted, refused) } }

    func perform<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    func remove(_ session: UDPServerSession) {
        perform {
            if sessions[session.sessionID] === session { sessions[session.sessionID] = nil }
        }
    }

    private func listen(_ continuation: CheckedContinuation<UInt16, Error>) {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                     port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: TransportError.socket(error.localizedDescription))
            return
        }
        starting = continuation
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.starting?.resume(returning: listener?.port?.rawValue ?? 0)
                self.starting = nil
            case .failed(let error):
                self.starting?.resume(throwing: TransportError.socket(error.localizedDescription))
                self.starting = nil
            case .cancelled:
                self.starting?.resume(throwing: TransportError.closed)
                self.starting = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        startSweep()
    }

    private func accept(_ connection: NWConnection) {
        guard let address = Self.address(of: connection.endpoint), policy.allows(address) else {
            refused += 1
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = Tracked(connection: connection, lastActive: TransportClock.now())
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if let content, !content.isEmpty { self.route(content, from: connection) }
            if error == nil, self.connections[ObjectIdentifier(connection)] != nil { self.receive(on: connection) }
        }
    }

    private func route(_ datagram: Data, from connection: NWConnection) {
        guard let id = TransportWire.sessionID(of: datagram), let session = sessions[id] else {
            unrouted += 1
            return
        }
        connections[ObjectIdentifier(connection)]?.lastActive = TransportClock.now()
        session.handle(datagram, from: connection)
    }

    /// Every 10 s, closes flows silent for 30 s that no session sends to (a phone's old address after it moved).
    private func startSweep() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = TransportClock.now()
            for (id, tracked) in self.connections where now - tracked.lastActive > 30_000_000 {
                guard !self.sessions.values.contains(where: { $0.isPeer(tracked.connection) }) else { continue }
                tracked.connection.cancel()
                self.connections[id] = nil
            }
        }
        timer.resume()
        sweep = timer
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
        case .ipv6(let address): return "\(address)".components(separatedBy: "%").first
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}

/// What the hub's readout shows about one session.
nonisolated public struct SenderSnapshot: Sendable {
    public var connected: Bool
    /// The phone's address and port the session sends to.
    public var peer: String?
    public var path: PathKind
    public var network: PhoneNetwork
    public var targetBitrate: Int
    public var pacingRate: Int
    public var roundTrip: Int64?
    public var lossRate: Double
    public var encoderTarget: EncoderTarget
    /// A frame would be taken now (see `MediaSender.hasRoom`).
    public var hasRoom: Bool
    public var plan: RecoveryPlan
    public var stats: SenderStats
    public var pacer: Pacer.Stats
    /// The delay detector's state, what the phone's reports say got through, and whether the encoder sends well under
    /// the target: why the target is where it is.
    public var usage: BandwidthUsage
    public var acknowledgedBitrate: Int?
    public var applicationLimited: Bool
}

/// One phone's session on the hub's socket. Thread-safe: every call hops onto the server's queue; events arrive on it
/// too (hop off before doing real work).
nonisolated public final class UDPServerSession: @unchecked Sendable {
    public let sessionID: UInt32
    private weak var server: UDPMediaServer?
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private let sender: MediaSender
    private var peer: NWConnection?
    private var timer: DispatchSourceTimer?
    private var eventHandler: (@Sendable (SenderEvent) -> Void)?
    private var closed = false

    init(sender: MediaSender, server: UDPMediaServer) {
        sessionID = sender.sessionID
        self.sender = sender
        self.server = server
        queue = server.queue
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
    }

    /// Hellos, encoder targets and the phone's app messages, on the transport's queue.
    public func setEventHandler(_ handler: @escaping @Sendable (SenderEvent) -> Void) {
        perform { eventHandler = handler }
    }

    /// Queues a frame now, or refuses it (then the next frame must be a refresh frame). Synchronous, so the encoder
    /// knows before it encodes the next frame.
    public func sendVideo(_ frame: Data, refresh: Bool) -> VideoAdmission {
        perform {
            guard !closed else { return .dropped(.notConnected) }
            let admission = sender.sendVideo(frame, refresh: refresh, now: TransportClock.now())
            pump()
            return admission
        }
    }

    /// One Opus frame; `timestamp` is its media time (µs, the Mac's host clock), `duration` its length in µs.
    public func sendAudio(_ frame: Data, timestamp: UInt64, duration: UInt16) {
        queue.async {
            guard !self.closed else { return }
            self.sender.sendAudio(frame, timestamp: timestamp, duration: duration, now: TransportClock.now())
            self.pump()
        }
    }

    public func sendAppMessage(_ message: AppMessage) throws {
        guard message.data.count <= AppMessage.maxDataSize else { throw TransportError.tooLarge }
        queue.async {
            guard !self.closed else { return }
            _ = try? self.sender.sendAppMessage(message, now: TransportClock.now())
            self.pump()
        }
    }

    /// The path monitor saw Tailscale's path to the phone change.
    public func setPath(_ path: PathKind) {
        queue.async {
            guard !self.closed else { return }
            self.sender.setPath(path, now: TransportClock.now())
            self.pump()
        }
    }

    /// A frame would be taken now (`MediaSender.hasRoom`): what the encoder waits for before making a refresh frame.
    public var hasRoom: Bool {
        perform { !closed && sender.hasRoom }
    }

    /// µs for a frame this size to reach the phone and its feedback to return (`MediaSender.deliveryTime`).
    public func deliveryTime(bytes: Int) -> Int64 {
        perform { sender.deliveryTime(bytes: bytes) }
    }

    public var snapshot: SenderSnapshot {
        perform {
            SenderSnapshot(connected: sender.isConnected, peer: peer.map { "\($0.endpoint)" }, path: sender.profile.path,
                           network: sender.network,
                           targetBitrate: sender.targetBitrate, pacingRate: sender.pacingRate, roundTrip: sender.roundTrip,
                           lossRate: sender.lossRate, encoderTarget: sender.encoderTarget, hasRoom: sender.hasRoom,
                           plan: sender.plan,
                           stats: sender.stats, pacer: sender.pacerStats, usage: sender.bandwidthUsage,
                           acknowledgedBitrate: sender.acknowledgedBitrate, applicationLimited: sender.applicationLimited)
        }
    }

    public func close() {
        perform { shutDown() }
        server?.remove(self)
    }

    func shutDown() {
        closed = true
        timer?.cancel()
        timer = nil
        peer = nil
        eventHandler = nil
    }

    func isPeer(_ connection: NWConnection) -> Bool { peer === connection }

    /// On the queue: a datagram for this session.
    func handle(_ datagram: Data, from connection: NWConnection) {
        guard !closed else { return }
        for event in sender.receive(datagram, now: TransportClock.now()) {
            // Only an authenticated, fresh hello moves the session to a new address.
            if case .hello = event { peer = connection }
            eventHandler?(event)
        }
        pump()
    }

    private func pump() {
        guard !closed else { return }
        let output = sender.poll(now: TransportClock.now())
        if let peer, !output.datagrams.isEmpty {
            peer.batch {
                for datagram in output.datagrams { peer.send(content: datagram, completion: .idempotent) }
            }
        }
        for event in output.events { eventHandler?(event) }
        let delay = max(0, sender.nextWakeup(now: TransportClock.now()) - TransportClock.now())
        timer?.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .microseconds(250))
    }

    private func perform<T>(_ work: () throws -> T) rethrows -> T {
        if let server { return try server.perform(work) }
        return try queue.sync(execute: work)
    }
}

// MARK: Phone

/// What the phone's readout shows about its UDP session.
nonisolated public struct ReceiverSnapshot: Sendable {
    public var connected: Bool
    public var report: SenderReport?
    public var roundTrip: Int64?
    public var awaitingRefresh: Bool
    public var stats: ReceiverStats
}

/// The phone's UDP socket to the hub. `connect` says hello and waits up to a second for the answer; if none comes it
/// throws `TransportError.noAnswer` and the caller stays on the WebSocket. Once connected, a network change (reported
/// by the app, or seen on the connection's path) moves to a fresh socket and says hello again from it; 3 s without a
/// packet from the hub (which sends at least every 20 ms) is reported as `.silent`. Thread-safe; events arrive on the
/// transport's queue.
nonisolated public final class UDPMediaClient: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let silenceTimeout: Int64 = 3_000_000
    private let queue = DispatchQueue(label: "agenthub.transport.phone", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    // Touched only on `queue`.
    private let receiver: MediaReceiver
    private var connection: NWConnection?
    private var retiring: [NWConnection] = []
    private var timer: DispatchSourceTimer?
    private var eventHandler: (@Sendable (ReceiverEvent) -> Void)?
    private var failureHandler: (@Sendable (TransportError) -> Void)?
    private var connecting: CheckedContinuation<Void, Error>?
    private var lastReceive: Int64?
    private var interfaces: [String] = []
    private var closed = false

    /// `video: false` for a session that carries only sound.
    public init(host: String, port: UInt16, keys: TransportKeys, network: PhoneNetwork, video: Bool = true,
                audio: Bool = true) {
        self.host = host
        self.port = port
        var settings = MediaReceiver.Settings()
        settings.wantsVideo = video
        settings.wantsAudio = audio
        receiver = MediaReceiver(keys: keys, network: network, settings: settings)
        queue.setSpecific(key: queueKey, value: 1)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
    }

    /// Frames, sound and app messages (`onEvent`), and the end of the session (`onFailure`: fall back to the
    /// WebSocket), on the transport's queue.
    public func setHandlers(onEvent: @escaping @Sendable (ReceiverEvent) -> Void,
                            onFailure: @escaping @Sendable (TransportError) -> Void) {
        perform {
            eventHandler = onEvent
            failureHandler = onFailure
        }
    }

    /// Says hello and waits up to `timeout` seconds for the hub's answer. Throws `TransportError.noAnswer` (stay on
    /// the WebSocket) or `.socket`; the client is closed when it throws.
    public func connect(timeout: TimeInterval = 1) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: TransportError.closed)
                    return
                }
                self.connecting = continuation
                self.open()
                self.sayHello()
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let waiting = self.connecting else { return }
                    self.connecting = nil
                    self.shutDown()
                    waiting.resume(throwing: TransportError.noAnswer)
                }
            }
        }
    }

    /// The phone's network changed (from the app's path monitor): a fresh socket, and hello again from it.
    public func networkChanged(to network: PhoneNetwork) {
        queue.async {
            guard !self.closed else { return }
            self.receiver.network = network
            self.migrate()
        }
    }

    public func sendAppMessage(_ message: AppMessage) throws {
        guard message.data.count <= AppMessage.maxDataSize else { throw TransportError.tooLarge }
        queue.async {
            guard !self.closed, let connection = self.connection,
                  let datagram = try? self.receiver.appMessage(message, now: TransportClock.now()) else { return }
            connection.send(content: datagram, completion: .idempotent)
        }
    }

    public var snapshot: ReceiverSnapshot {
        perform {
            ReceiverSnapshot(connected: receiver.isConnected, report: receiver.report, roundTrip: receiver.roundTrip,
                             awaitingRefresh: receiver.awaitingRefresh, stats: receiver.stats)
        }
    }

    public func close() {
        perform { shutDown() }
    }

    private func perform<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    private func open() {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
                                      using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                // A hello sent while it was still preparing may not have gone.
                if !self.receiver.isConnected || self.connecting != nil { self.sayHello() }
            case .failed(let error):
                self.fail(.socket(error.localizedDescription))
            default:
                break
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            guard let self, let connection, connection === self.connection, path.status == .satisfied else { return }
            let names = path.availableInterfaces.map(\.name)
            defer { self.interfaces = names }
            if !self.interfaces.isEmpty, names != self.interfaces { self.sayHello() }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] better in
            guard let self, let connection, connection === self.connection, better else { return }
            self.migrate()
        }
        connection.start(queue: queue)
        receive(on: connection)
        self.connection = connection
    }

    /// A fresh socket (a new local port), hello from it; the old one keeps receiving for 2 s while the hub moves over.
    private func migrate() {
        guard let old = connection else { return }
        retiring.append(old)
        open()
        sayHello()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            old.cancel()
            self?.retiring.removeAll { $0 === old }
        }
    }

    private func sayHello() {
        guard let connection, let datagram = receiver.hello(now: TransportClock.now()) else { return }
        connection.send(content: datagram, completion: .idempotent)
        schedule(receiver.nextWakeup(now: TransportClock.now()))
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection, !self.closed else { return }
            if let content, !content.isEmpty { self.handle(content) }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handle(_ datagram: Data) {
        let now = TransportClock.now()
        let accepted = receiver.stats.packetsReceived
        let events = receiver.receive(datagram, now: now)
        if receiver.stats.packetsReceived != accepted { lastReceive = now }
        if receiver.isConnected, let waiting = connecting {
            connecting = nil
            waiting.resume()
        }
        for event in events { eventHandler?(event) }
        pump()
    }

    private func pump() {
        guard !closed else { return }
        let now = TransportClock.now()
        let output = receiver.poll(now: now)
        if let connection, !output.datagrams.isEmpty {
            connection.batch {
                for datagram in output.datagrams { connection.send(content: datagram, completion: .idempotent) }
            }
        }
        for event in output.events { eventHandler?(event) }
        if receiver.isConnected, let lastReceive, now - lastReceive > silenceTimeout {
            fail(.silent)
            return
        }
        var next = receiver.nextWakeup(now: now)
        if receiver.isConnected, let lastReceive { next = min(next, lastReceive + silenceTimeout + 1_000) }
        schedule(next)
    }

    private func schedule(_ time: Int64) {
        let delay = max(0, time - TransportClock.now())
        timer?.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .milliseconds(1))
    }

    private func fail(_ error: TransportError) {
        guard !closed else { return }
        let handler = failureHandler
        if let waiting = connecting {
            connecting = nil
            waiting.resume(throwing: error)
        } else {
            handler?(error)
        }
        shutDown()
    }

    private func shutDown() {
        closed = true
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        for old in retiring { old.cancel() }
        retiring.removeAll()
        if let waiting = connecting {
            connecting = nil
            waiting.resume(throwing: TransportError.closed)
        }
    }
}
