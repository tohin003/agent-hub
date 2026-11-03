import Foundation
import Network

/// One connected phone. A phone opens up to three of these: "control" (requests, events), "screen" (the live picture:
/// JPEG or video frames, the pointer, keepalive ticks) and "audio" (the Mac's sound), so large frames never hold up a
/// tap, a keystroke or the sound.
@MainActor
final class ClientConnection {
    enum Channel: String {
        case unknown, control, screen, audio
    }

    let id = UUID()
    let remote: String
    private let connection: NWConnection
    private(set) var channel: Channel = .unknown
    private(set) var device = "iPhone"
    private(set) var subscriptions: Set<String> = []
    private(set) var terminalSubscriptions: Set<String> = []
    var onFrame: ((ClientConnection, ClientFrame) -> Void)?
    var onClose: ((ClientConnection) -> Void)?
    private var closed = false
    var isClosed: Bool { closed }
    private var helloTimer: Task<Void, Never>?

    // Screen frames: one in flight, the newest waiting; older ones are dropped on a slow link.
    private var frameInFlight = false
    private var pendingFrame: Data?
    // Video frames and the pointer: every byte handed to the connection counts until the connection has taken it, so
    // the screen service can tell how far behind the link is.
    private(set) var screenBacklog = 0
    /// The part of `screenBacklog` that is keyframes.
    private(set) var keyframeBacklog = 0
    /// A screen message left: the backlog went down.
    var onScreenSent: ((ClientConnection) -> Void)?
    // Pointer positions: one in flight, the newest waiting.
    private var pointerInFlight = false
    private var pendingPointer: Data?
    /// While the phone watches: fires 20 ms after the last thing sent, for a keepalive tick.
    private var keepalive: DispatchSourceTimer?
    // Sound: a few messages may wait (a fraction of a second); past that, a slow link drops sound instead of
    // falling further behind.
    private var audioInFlight = 0
    private static let audioBacklog = 12
    var screenDisplay: UInt32?
    var screenSettings = ScreenStartParams(displayId: nil)
    /// The phone's UDP session for this connection's picture or sound (`MediaTransport`), once it asked for one.
    var mediaSession: UDPServerSession?
    /// The session's phone said hello: the picture (or sound) goes over UDP now, until the session ends.
    var mediaActive = false
    /// The session's newest target for the video encoder.
    var mediaTarget: EncoderTarget?

    /// The UDP session, while it carries this connection's media.
    var udp: UDPServerSession? { mediaActive ? mediaSession : nil }

    init(connection: NWConnection, remote: String) {
        self.connection = connection
        self.remote = remote
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .failed(let error):
                    Log.warn("client \(self.remote): failed: \(error)")
                    self.close()
                case .cancelled:
                    self.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        helloTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.channel == .unknown else { return }
            Log.warn("client \(self.remote): no hello within 10 s")
            self.close()
        }
    }

    func identify(channel: Channel, device: String) {
        self.channel = channel
        self.device = device
        helloTimer?.cancel()
    }

    func subscribe(_ sessionId: String, terminal: Bool) {
        subscriptions.insert(sessionId)
        if terminal { terminalSubscriptions.insert(sessionId) } else { terminalSubscriptions.remove(sessionId) }
    }

    func unsubscribe(_ sessionId: String) {
        subscriptions.remove(sessionId)
        terminalSubscriptions.remove(sessionId)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    Log.info("client \(self.remote): receive ended: \(error)")
                    self.close()
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                switch metadata?.opcode {
                case .close?:
                    self.close()
                    return
                case .text?, .binary?:
                    if let content, !content.isEmpty { self.handle(content) }
                default:
                    break
                }
                if !self.closed { self.receive() }
            }
        }
    }

    private func handle(_ data: Data) {
        do {
            let frame = try WireCoding.decoder.decode(ClientFrame.self, from: data)
            onFrame?(self, frame)
        } catch {
            Log.warn("client \(remote): unreadable frame: \(error)")
        }
    }

    // MARK: Sending

    func respond(_ id: Int?, result: JSONValue) {
        guard let id else { return }
        send(ServerFrame(id: id, result: result))
    }

    func respond<T: Encodable>(_ id: Int?, _ value: T) {
        guard let id else { return }
        do {
            send(ServerFrame(id: id, result: try JSONValue(encoding: value)))
        } catch {
            send(ServerFrame(id: id, error: .failed("Couldn't encode the reply: \(error)")))
        }
    }

    func fail(_ id: Int?, _ error: Error) {
        guard let id else { return }
        let wire = (error as? WireError) ?? .failed(error.localizedDescription)
        send(ServerFrame(id: id, error: wire))
    }

    func emit<T: Encodable>(_ event: String, _ value: T) {
        guard let data = try? JSONValue(encoding: value) else { return }
        send(ServerFrame(event: event, data: data))
    }

    private func send(_ frame: ServerFrame) {
        guard !closed, let data = try? WireCoding.encoder.encode(frame) else { return }
        armKeepalive()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { Log.warn("send failed: \(error)") }
        })
    }

    /// Sends a screen frame unless one is still on its way; then the newest frame waits and older ones are dropped.
    func sendScreenFrame(_ data: Data) {
        guard !closed else { return }
        if frameInFlight {
            pendingFrame = data
            return
        }
        frameInFlight = true
        armKeepalive()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameInFlight = false
                if let next = self.pendingFrame {
                    self.pendingFrame = nil
                    self.sendScreenFrame(next)
                }
            }
        })
    }

    /// Sends a binary screen message (a video frame, a pointer shape, a keepalive tick) right away, counting its bytes
    /// in the backlog until the connection has taken them.
    func sendScreen(_ data: Data, keyframe: Bool = false) {
        guard !closed else { return }
        screenBacklog += data.count
        if keyframe { keyframeBacklog += data.count }
        armKeepalive()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "screen", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenBacklog -= data.count
                if keyframe { self.keyframeBacklog -= data.count }
                self.onScreenSent?(self)
            }
        })
    }

    /// Sends where the pointer is: one position on its way at a time, and only the newest waits behind it.
    func sendPointer(_ data: Data) {
        guard !closed else { return }
        if pointerInFlight {
            pendingPointer = data
            return
        }
        pointerInFlight = true
        screenBacklog += data.count
        armKeepalive()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "pointer", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenBacklog -= data.count
                self.pointerInFlight = false
                if let next = self.pendingPointer {
                    self.pendingPointer = nil
                    self.sendPointer(next)
                }
            }
        })
    }

    /// While the phone watches, a one-byte tick (`StreamKeepalive`) goes out whenever nothing else did for 20 ms, so
    /// the iPhone's Wi-Fi never dozes between frames.
    func startScreenKeepalive() {
        guard keepalive == nil, !closed else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sendScreen(StreamKeepalive.message) }
        }
        keepalive = timer
        armKeepalive()
        timer.resume()
    }

    func stopScreenKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    private static let keepaliveInterval = DispatchTimeInterval.milliseconds(20)

    /// Something went out: the next tick is due 20 ms from now.
    private func armKeepalive() {
        keepalive?.schedule(deadline: .now() + Self.keepaliveInterval, repeating: .never, leeway: .milliseconds(2))
    }

    /// Sends a sound message, unless the link is already that far behind.
    func sendAudio(_ data: Data) {
        guard !closed, audioInFlight < Self.audioBacklog else { return }
        audioInFlight += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "sound", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.audioInFlight -= 1 }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        helloTimer?.cancel()
        stopScreenKeepalive()
        connection.cancel()
        onClose?(self)
        // After the services let go of it: a session nobody watches any more.
        mediaSession?.close()
        mediaSession = nil
        mediaActive = false
    }
}
