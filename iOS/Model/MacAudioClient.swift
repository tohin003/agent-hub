import AVFoundation
import Observation
import Synchronization
import UIKit

/// The Mac's sound, played on this iPhone: a connection of its own (so sound never waits behind a screen frame). The
/// hub captures it before the Mac's own volume and mute. It keeps playing with the iPhone locked, like any audio app.
///
/// A current hub sets up UDP on this connection (`screen.transport`): Opus in 10 ms frames, rebuilt from in-band FEC or
/// concealed when one is lost (`OpusPlayback`). Otherwise, or if UDP doesn't answer within a second, AAC comes over the
/// WebSocket: AAC-ELD in 10 ms packets with each one's capture time from a hub of step 2 on, AAC-LC without from an
/// older one. Either way `SoundOutput` plays it, with a buffer that follows the measured jitter from the path's floor
/// and steers by playing 1–2% faster or slower, and that keeps the sound from getting ahead of the picture.
@Observable
final class MacAudioClient {
    private(set) var playing = false
    private(set) var error: String?

    /// While the Mac's sound is on, Stay Connected leaves the shared audio session alone.
    private(set) static var isActive = false

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var output: SoundOutput?
    @ObservationIgnored private var decoder: MacAudioDecoder?
    @ObservationIgnored private var opus: OpusPlayback?
    /// UDP failed lately: ask for AAC straight away until then.
    @ObservationIgnored private var udpRetryAfter = ContinuousClock.now
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// `mac.clock` requests in flight on the AAC connection: id → when sent.
    @ObservationIgnored private var clockRequests: [Int: Int64] = [:]
    @ObservationIgnored private var clockExchanges = 0
    @ObservationIgnored private var nextClockExchange: Int64 = 0

    /// AAC over the WebSocket with capture times: the least buffer, before the measured jitter (TCP's is larger than
    /// UDP's, and a resend shows as a burst).
    private static let webSocketFloorMs = 30.0
    /// Without capture times (an older hub) the jitter can't be measured: what the old playback held.
    private static let untimedFloorMs = 120.0
    /// The audio IO buffer asked for: the buffer the sound needs is a few of these, and each adds to the delay.
    private static let ioBufferDuration = 0.005


    func start(settings: HubSettings, host: String) {
        stop()
        generation += 1
        let attempt = generation
        Self.isActive = true
        error = nil
        MacClock.shared.use(hub: host)
        Task { await run(settings: settings, host: host, attempt: attempt) }
    }

    func stop() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        stopPlayback()
        playing = false
        Self.isActive = false
    }

    /// Listens until stopped, connecting again after a dropped connection.
    private func run(settings: HubSettings, host: String, attempt: Int) async {
        var failures = 0
        while attempt == generation {
            do {
                // UDP failed while playing: AAC over the WebSocket at once.
                if try await listen(settings: settings, host: host, attempt: attempt) { continue }
                failures = 0
            } catch {
                guard attempt == generation else { return }
                self.error = HubClient.describe(error)
                // Retrying can't fix these: the live screen is off, a permission is missing, or the Mac's hub is older.
                if let wire = error as? WireError, ["screen_off", "screen_recording", "bad_request", "version"].contains(wire.code) {
                    return
                }
                failures += 1
            }
            guard attempt == generation else { return }
            try? await Task.sleep(for: .seconds(min(2.0 * Double(failures + 1), 10)))
        }
    }

    /// One connection, from hello until it ends. True when it ended because UDP failed, so the next one should start
    /// at once (on AAC).
    private func listen(settings: HubSettings, host: String, attempt: Int) async throws -> Bool {
        guard let url = URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(settings.port)/") else {
            throw WireError.failed("The Mac's address isn't valid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: WireProtocol.authorizationHeader)
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if self.task === task { self.task = nil }
            if attempt == generation {
                stopPlayback()
                playing = false
            }
        }
        let _: HelloResult = try await call(task, Method.hello, HelloParams(channel: "audio", device: UIDevice.current.name))
        let transport = await openTransport(task)
        let format: MacAudioFormat
        do {
            // AAC-ELD with capture times if the hub has them; an older hub ignores the ask and sends AAC-LC.
            format = try await call(task, Method.screenAudio, ScreenAudioParams())
        } catch {
            transport?.client.close()
            throw error
        }
        guard attempt == generation else {
            transport?.client.close()
            return false
        }
        if format.codec == TransportAudioFormat.opus.codec, let transport {
            return try await playOpus(transport, task: task, attempt: attempt)
        }
        if let transport {
            // The hub sends AAC after all: let the session go.
            transport.client.close()
            try? await send(task, Method.screenTransport, ScreenTransportParams(versions: [], network: .other))
        }
        try startPlayback(format)
        error = nil
        playing = true
        let timed = format.timed == true
        clockRequests = [:]
        clockExchanges = 0
        nextClockExchange = 0
        while attempt == generation {
            let message = try await task.receive()
            guard attempt == generation else { return false }
            switch message {
            case .data(let data):
                if data.first == TimedAudioMessage.kind, let sound = TimedAudioMessage.parse(data) {
                    play(sound.packets, captureTime: sound.captureTime)
                } else if let sound = AudioPacketMessage.parse(data) {
                    play(sound.packets, captureTime: nil)
                }
            case .string(let text):
                clockAnswered(text)
            @unknown default:
                break
            }
            if timed { askClockIfDue(task) }
        }
        return false
    }

    /// Asks the Mac for its host clock now and then while AAC plays (a few times at first, then every 5 s), so the
    /// sound's delay is known without the Screen tab. The answers come between the sound (`clockAnswered`).
    private func askClockIfDue(_ task: URLSessionWebSocketTask) {
        let now = TransportClock.now()
        guard now >= nextClockExchange else { return }
        nextClockExchange = now + (clockExchanges < 5 ? 300_000 : 5_000_000)
        clockExchanges += 1
        let id = nextId
        nextId += 1
        guard let data = try? WireCoding.encoder.encode(ClientFrame(id: id, method: Method.macClock,
                                                                    params: try JSONValue(encoding: Empty()))) else { return }
        clockRequests = clockRequests.filter { now - $0.value < 10_000_000 }
        clockRequests[id] = now
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func clockAnswered(_ text: String) {
        let received = TransportClock.now()
        guard let reply = try? WireCoding.decoder.decode(ServerFrame.self, from: Data(text.utf8)), let id = reply.id,
              let sent = clockRequests.removeValue(forKey: id) else { return }
        if reply.error != nil {
            // A hub that sends capture times knows the request; if not, stop asking.
            nextClockExchange = .max
            return
        }
        guard let result = try? reply.result?.decode(MacClockResult.self) else { return }
        MacClock.shared.exchange(sent: sent, hostTime: result.hostTime, received: received)
    }

    // MARK: UDP

    /// A UDP session on this sound connection, its failures, and where its events go once playback starts.
    private struct Transport {
        var client: UDPMediaClient
        var profile: PathProfile
        var failures: AsyncStream<TransportError>
        var sink: OpusSink
    }

    /// Asks for UDP and says hello on it; nil (AAC, then) for an older hub, one without UDP, or no answer within a
    /// second.
    private func openTransport(_ task: URLSessionWebSocketTask) async -> Transport? {
        guard ContinuousClock.now >= udpRetryAfter else { return nil }
        let network = PhoneNetworkMonitor.shared.current
        let ask = ScreenTransportParams(network: network, video: false, audio: true)
        guard let result: ScreenTransportResult = try? await call(task, Method.screenTransport, ask) else { return nil }
        guard result.audio?.codec == TransportAudioFormat.opus.codec, let keys = result.keys,
              let port = UInt16(exactly: result.port) else {
            try? await send(task, Method.screenTransport, ScreenTransportParams(versions: [], network: network))
            return nil
        }
        let client = UDPMediaClient(host: result.host, port: port, keys: keys, network: network, video: false)
        let sink = OpusSink()
        let (failures, failed) = AsyncStream<TransportError>.makeStream()
        client.setHandlers(onEvent: { event in sink.handle(event) },
                           onFailure: { error in
                               failed.yield(error)
                               failed.finish()
                           })
        do {
            try await client.connect(timeout: 1)
        } catch {
            try? await send(task, Method.screenTransport, ScreenTransportParams(versions: [], network: network))
            udpRetryAfter = .now + .seconds(60)
            return nil
        }
        return Transport(client: client, profile: result.profile, failures: failures, sink: sink)
    }

    /// Plays Opus from the session until the WebSocket or the session ends; true when the session did (UDP failed).
    private func playOpus(_ transport: Transport, task: URLSessionWebSocketTask, attempt: Int) async throws -> Bool {
        let networkObserver = PhoneNetworkMonitor.shared.observe { network in transport.client.networkChanged(to: network) }
        defer {
            PhoneNetworkMonitor.shared.stopObserving(networkObserver)
            transport.sink.set(nil)
            transport.client.close()
        }
        try startOpusPlayback(profile: transport.profile)
        transport.sink.set(opus)
        error = nil
        playing = true
        let failures = transport.failures
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { while true { _ = try await task.receive() } }
                group.addTask {
                    for await failure in failures { throw failure }
                    throw TransportError.closed
                }
                defer {
                    task.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                }
                try await group.next()
            }
        } catch is TransportError where attempt == generation {
            // The session went quiet or its socket failed: AAC over the WebSocket for a while.
            udpRetryAfter = .now + .seconds(30)
            return true
        }
        return false
    }

    /// A request on this connection with no answer to wait for.
    private func send<P: Encodable>(_ task: URLSessionWebSocketTask, _ method: String, _ params: P) async throws {
        let data = try WireCoding.encoder.encode(ClientFrame(id: nil, method: method, params: try JSONValue(encoding: params)))
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// A request on this connection; nothing else arrives on it until the sound starts.
    private func call<P: Encodable, R: Decodable>(_ task: URLSessionWebSocketTask, _ method: String, _ params: P) async throws -> R {
        let id = nextId
        nextId += 1
        let data = try WireCoding.encoder.encode(ClientFrame(id: id, method: method, params: try JSONValue(encoding: params)))
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            guard case .string(let text) = try await task.receive(),
                  let reply = try? WireCoding.decoder.decode(ServerFrame.self, from: Data(text.utf8)), reply.id == id
            else { continue }
            if let error = reply.error { throw error }
            guard let result = reply.result else { throw WireError.failed("The Mac sent an empty reply.") }
            return try result.decode(R.self)
        }
    }

    // MARK: Playback

    /// AAC over the WebSocket: its decoder, and the output with the least buffer for how it comes.
    private func startPlayback(_ format: MacAudioFormat) throws {
        let decoder = try MacAudioDecoder(format: format)
        try startOutput(format: decoder.pcmFormat, floorMs: format.timed == true ? Self.webSocketFloorMs : Self.untimedFloorMs)
        self.decoder = decoder
    }

    /// The output for Opus, and the playback the session's frames go to.
    private func startOpusPlayback(profile: PathProfile) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(OpusFormat.sampleRate),
                                         channels: AVAudioChannelCount(OpusFormat.channels)) else {
            throw WireError.failed("This iPhone can't play the Mac's sound (Opus).")
        }
        try startOutput(format: format, floorMs: PlayoutController.Settings.forPath(bufferMs: profile.audioBufferMs).floorMs)
        guard let output else { return }
        opus = try OpusPlayback(output: output)
    }

    private func startOutput(format: AVAudioFormat, floorMs: Double) throws {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(Self.ioBufferDuration)
        try session.setActive(true)
        let output = SoundOutput(format: format, floorMs: floorMs)
        try output.start()
        self.output = output
        observe(output.audioEngine)
    }

    private func stopPlayback() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        opus?.stop()
        opus = nil
        output?.stop()
        output = nil
        decoder = nil
    }

    private func play(_ packets: [Data], captureTime: Int64?) {
        guard let decoder, let output, let pcm = decoder.decode(packets) else { return }
        output.enqueue(pcm, captureTime: captureTime)
    }

    /// Headphones coming and going, or a call, stop the engine: start it again.
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartEngine() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                MainActor.assumeIsolated { self?.restartEngine() }
            },
        ]
    }

    private func restartEngine() {
        guard let output else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        output.restart()
        opus?.rebuffer()
    }
}

/// Where a UDP session's events go: the Opus playback, once it has started (the session is up before that).
nonisolated final class OpusSink: Sendable {
    private let playback = Mutex<OpusPlayback?>(nil)

    func set(_ playback: OpusPlayback?) {
        self.playback.withLock { $0 = playback }
    }

    func handle(_ event: ReceiverEvent) {
        playback.withLock { $0 }?.handle(event)
    }
}

/// A frame count shared with the audio thread. A stopped player reports its dropped buffers late, from its own
/// thread; the epoch keeps those from counting against the buffers scheduled after a reset.
nonisolated final class FrameCount: Sendable {
    private let state = Mutex((epoch: 0, frames: 0))

    var value: Int { state.withLock { max($0.frames, 0) } }

    /// Counts frames in; returns the epoch they belong to.
    func add(_ frames: Int) -> Int {
        state.withLock { state in
            state.frames += frames
            return state.epoch
        }
    }

    func remove(_ frames: Int, epoch: Int) {
        state.withLock { state in
            if state.epoch == epoch { state.frames -= frames }
        }
    }

    func reset() {
        state.withLock { state in
            state.epoch += 1
            state.frames = 0
        }
    }
}
