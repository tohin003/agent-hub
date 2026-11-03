import Foundation

/// The live picture and the Mac's sound over UDP inside Tailscale (`Shared/Transport`). There is one socket, on the
/// Mac's tailnet address only. Each phone connection that asks (`screen.transport`, on its screen or sound
/// connection) gets a session with a fresh key, handed over that authenticated WebSocket. Each phone gets one
/// Tailscale path monitor, whose direct / peer relay / DERP answer sets the session's profile.
///
/// Everything else (taps, typing, pointer shapes) stays on the WebSocket. A phone that can't reach the socket within
/// a second, an older phone, or a session that goes quiet keeps or gets its picture and sound there as before.
@MainActor
final class MediaTransport {
    /// The phone's first hello: its media goes over UDP from now on.
    var onStarted: ((ClientConnection) -> Void)?
    /// Encoder targets and app messages from a session that has started.
    var onEvent: ((SenderEvent, ClientConnection) -> Void)?
    /// A started session ended (it went quiet, the phone turned it off, or a newer one replaced it): media goes over the
    /// WebSocket again.
    var onEnded: ((ClientConnection) -> Void)?

    private var server: UDPMediaServer?
    /// The address asked for, and the one the socket is on (nil while it's down).
    private var requestedHost: String?
    private var host: String?
    private var port: UInt16?
    private var starting: Task<Void, Never>?
    /// The path monitor for each phone address, and the sessions it steers.
    private var watches: [String: PathWatch] = [:]
    /// The last path seen to each phone address, for the next session's starting profile.
    private var lastPaths: [String: PathKind] = [:]

    private final class PathWatch {
        let monitor: TailscalePathMonitor?
        var path: PathKind?
        var clients: [UUID: ClientConnection] = [:]

        init(monitor: TailscalePathMonitor?) {
            self.monitor = monitor
        }
    }

    /// Listens on the Mac's tailnet IPv4 address, again when it changes; nil (Tailscale is down) closes the socket.
    /// Sessions on an old socket end, and their phones fall back and ask again.
    func listen(on host: String?) {
        requestedHost = host
        guard host != self.host || (host != nil && server == nil) else { return }
        server?.stop()
        server = nil
        port = nil
        self.host = host
        starting?.cancel()
        starting = nil
        guard let host else { return }
        let server = UDPMediaServer(host: host, policy: .tailnetOrLoopback)
        self.server = server
        starting = Task {
            do {
                let port = try await server.start()
                guard self.server === server else { return }
                self.port = port
                Log.info("transport: UDP for the live screen and sound on \(host):\(port)")
            } catch {
                guard self.server === server else { return }
                Log.warn("transport: UDP didn't start on \(host): \(error.localizedDescription)")
                self.server = nil
                self.host = nil
            }
        }
    }

    func stop() {
        listen(on: nil)
    }

    /// A phone asks for a session on this connection (a second ask replaces the first). Throws `no_udp` when the
    /// socket isn't up: the phone stays on the WebSocket.
    func negotiate(_ ask: ScreenTransportParams, for client: ClientConnection) async throws -> ScreenTransportResult {
        end(client)
        guard ask.versions.contains(Int(TransportWire.version)) else {
            throw WireError(code: "no_udp", message: "This Mac speaks another version of the UDP transport.")
        }
        // The socket failed to start earlier: try again now.
        if server == nil, let requestedHost { listen(on: requestedHost) }
        await starting?.value
        guard !client.isClosed else { throw WireError(code: "stopped", message: "The connection closed.") }
        guard let server, let host, let port else {
            throw WireError(code: "no_udp", message: "UDP isn't available on this Mac right now.")
        }
        let (sessionID, key) = TransportKeys.generate()
        guard let keys = TransportKeys(sessionID: sessionID, sessionKey: key) else {
            throw WireError.failed("The UDP session couldn't be set up.")
        }
        let path = lastPaths[client.remote] ?? .unknown
        let profile = PathProfile.profile(for: path)
        let session = server.makeSession(keys: keys, profile: profile)
        client.mediaSession = session
        client.mediaActive = false
        client.mediaTarget = nil
        session.setEventHandler { [weak self, weak client] event in
            // In order, on the main thread (a Task wouldn't keep the order).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let client, client.mediaSession === session else { return }
                    self.handle(event, from: client)
                }
            }
        }
        let audio = ask.audio && client.channel == .audio && ask.audioCodecs.contains(TransportAudioFormat.opus.codec)
        Log.info("transport: \(client.device) asked for UDP (\(client.channel.rawValue), \(ask.network.rawValue)); "
            + "starting on the \(path.rawValue) profile")
        // The key goes only to this phone, over its authenticated WebSocket; it's never logged.
        return ScreenTransportResult(host: host, port: Int(port), sessionId: sessionID, key: key, path: path,
                                     profile: profile, audio: audio ? .opus : nil)
    }

    /// Ends a connection's session, if it has one (the phone turned it off or went away).
    func end(_ client: ClientConnection) {
        guard let session = client.mediaSession else { return }
        let wasActive = client.mediaActive
        client.mediaSession = nil
        client.mediaActive = false
        client.mediaTarget = nil
        session.close()
        unwatch(client)
        if wasActive { onEnded?(client) }
    }

    private func handle(_ event: SenderEvent, from client: ClientConnection) {
        switch event {
        case .hello(let hello):
            if !client.mediaActive {
                client.mediaActive = true
                Log.info("transport: \(client.device) is on UDP (\(client.channel.rawValue), \(hello.network.rawValue))")
                watch(client)
                onStarted?(client)
            } else {
                // A new network, so maybe a new way through Tailscale: look now, not at the next tick.
                watches[client.remote]?.monitor?.checkNow()
            }
        case .silent:
            Log.warn("transport: nothing from \(client.device) over UDP for 3 s: back to the WebSocket")
            end(client)
        case .encoderTarget(let target):
            client.mediaTarget = target
            onEvent?(event, client)
        case .appMessage:
            onEvent?(event, client)
        }
    }

    // MARK: Paths

    private func watch(_ client: ClientConnection) {
        let address = client.remote
        let watch: PathWatch
        if let existing = watches[address] {
            watch = existing
        } else {
            let monitor = TailscalePathMonitor(peerAddress: address) { [weak self] path in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.pathChanged(path, for: address) }
                }
            }
            watch = PathWatch(monitor: monitor)
            watches[address] = watch
            monitor?.start()
        }
        watch.clients[client.id] = client
        if let path = watch.path { client.mediaSession?.setPath(path) }
    }

    private func unwatch(_ client: ClientConnection) {
        guard let watch = watches[client.remote], watch.clients.removeValue(forKey: client.id) != nil,
              watch.clients.isEmpty else { return }
        watch.monitor?.stop()
        watches[client.remote] = nil
    }

    private func pathChanged(_ peer: TailscalePeerPath, for address: String) {
        guard let watch = watches[address] else { return }
        let changed = watch.path != peer.kind
        watch.path = peer.kind
        lastPaths[address] = peer.kind
        guard changed else { return }
        Log.info("transport: Tailscale reaches \(address) \(peer.kind.rawValue)\(peer.via.map { " (\($0))" } ?? "")")
        for client in watch.clients.values { client.mediaSession?.setPath(peer.kind) }
    }
}
