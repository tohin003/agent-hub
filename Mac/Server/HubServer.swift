import Foundation
import Network

/// The WebSocket server the iPhone connects to. It listens only on the Mac's tailnet address and on localhost
/// (plus the LAN when the config asks), checks the pairing token in the upgrade request, and hands each connection
/// to a `ClientConnection`.
@MainActor
final class HubServer {
    private var listeners: [String: NWListener] = [:]
    private let port: NWEndpoint.Port
    private let token: String
    private let tailnet: TailnetGuard
    var onConnection: ((ClientConnection) -> Void)?
    private(set) var boundHosts: [String] = []

    init(port: Int, token: String, tailnet: TailnetGuard) {
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 7860
        self.token = token
        self.tailnet = tailnet
    }

    /// Binds to every address in `hosts` not yet bound, and drops listeners for addresses that went away.
    func bind(hosts: [String]) {
        for (host, listener) in listeners where !hosts.contains(host) {
            listener.cancel()
            listeners[host] = nil
            Log.info("server: stopped listening on \(host)")
        }
        for host in hosts where listeners[host] == nil {
            do {
                listeners[host] = try makeListener(host: host)
            } catch {
                Log.error("server: couldn't listen on \(host):\(port.rawValue): \(error)")
            }
        }
        boundHosts = listeners.keys.sorted()
    }

    func stop() {
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
    }

    private func makeListener(host: String) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
        }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 32 * 1024 * 1024
        let expected = "Bearer \(token)"
        websocket.setClientRequestHandler(.main) { _, headers in
            let value = headers.first { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
            let accepted = value.map { Self.constantTimeEquals($0, expected) } ?? false
            if !accepted { Log.warn("server: refused a connection with a wrong or missing token") }
            return NWProtocolWebSocket.Response(status: accepted ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.info("server: listening on \(host):\(listener.port?.rawValue ?? 0)")
            case .failed(let error): Log.error("server: listener on \(host) failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection, via: host)
            }
        }
        listener.start(queue: .main)
        return listener
    }

    private func accept(_ connection: NWConnection, via host: String) {
        let remote = Self.remoteAddress(connection.endpoint)
        guard let remote, tailnet.isAllowedAddress(remote, listenerHost: host) else {
            Log.warn("server: refused \(remote ?? "an unknown address"): not on this Mac's tailnet")
            connection.cancel()
            return
        }
        let client = ClientConnection(connection: connection, remote: remote)
        Task { @MainActor in
            // Checks that the tailnet device belongs to the same person as this Mac (tailscale whois).
            guard await tailnet.isAllowedPeer(remote) else {
                Log.warn("server: refused \(remote): a tailnet device signed in as someone else")
                connection.cancel()
                return
            }
            onConnection?(client)
            client.start()
        }
    }

    nonisolated static func remoteAddress(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
        case .ipv6(let address): return "\(address)".components(separatedBy: "%").first
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
