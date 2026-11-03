import Foundation

/// The Mac's sound for the phones that asked for it, each on a connection of its own so sound never waits behind a
/// screen frame. A phone whose sound connection set up UDP gets Opus in 10 ms frames over its session (sent ahead of
/// any picture). The rest get it over the WebSocket: AAC-ELD with each packet's capture time for phones from step 2
/// on (`ScreenAudioParams`), AAC-LC as before for older ones. One capture serves them all; it stops when the last one
/// leaves or the live screen is turned off.
@MainActor
final class AudioService {
    /// Opus over UDP: 48 kHz stereo, 10 ms frames, no magic cookie.
    static let opusFormat = MacAudioFormat(codec: TransportAudioFormat.opus.codec, sampleRate: Double(OpusFormat.sampleRate),
                                           channels: OpusFormat.channels, framesPerPacket: OpusFormat.frameSamples,
                                           magicCookie: Data())

    private var streamer: AudioStreamer?
    /// Each WebSocket codec's format, while capturing.
    private var formats: [String: MacAudioFormat]?
    private var starting: Task<[String: MacAudioFormat], Error>?
    /// AAC over the WebSocket, each with the codec it takes and whether it takes capture times.
    private var listeners: [UUID: (client: ClientConnection, codec: String, timed: Bool)] = [:]
    private var sequence: UInt32 = 0
    /// Opus over UDP.
    private var opusListeners: [UUID: ClientConnection] = [:]
    private let outputs = AudioOutputs()

    /// Follows the live screen's switch: while it's off, no sound is captured either.
    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }

    private var everyone: Bool { !listeners.isEmpty || !opusListeners.isEmpty }

    /// Starts sending the Mac's sound to a phone's sound connection; answers with how it's encoded: Opus when the
    /// connection's UDP session is up, else the best AAC the phone asked for (`ask`; nil from older phones: AAC-LC).
    func listen(client: ClientConnection, ask: ScreenAudioParams? = nil) async throws -> MacAudioFormat {
        guard enabled else {
            throw WireError(code: "screen_off", message: "The live screen is turned off in Agent Hub.")
        }
        guard ScreenService.screenRecordingAllowed else {
            ScreenService.requestScreenRecording()
            throw WireError(code: "screen_recording",
                            message: "Allow Agent Hub in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
        if let session = client.udp {
            listeners[client.id] = nil
            opusListeners[client.id] = client
            let snapshot = session.snapshot
            outputs.setOpus(client.id, session: session, path: snapshot.path, plan: snapshot.plan)
        } else {
            opusListeners[client.id] = nil
            outputs.removeOpus(client.id)
            // Until the capture says which codecs it has: the phone's first choice, else AAC-LC.
            listeners[client.id] = (client, ask?.codecs.first ?? MacAudioCodec.aacLC, ask?.timed == true)
            outputs.setCodecs(Set(listeners.values.map(\.codec)))
        }
        let formats: [String: MacAudioFormat]
        do {
            formats = try await capture()
        } catch {
            forget(client)
            throw error
        }
        if opusListeners[client.id] != nil {
            Log.info("sound: \(client.device) gets Opus over UDP")
            return Self.opusFormat
        }
        let codec = (ask?.codecs ?? [MacAudioCodec.aacLC]).first { formats[$0] != nil } ?? MacAudioCodec.aacLC
        guard var format = formats[codec] else { throw WireError.failed("The Mac's sound encoder couldn't start.") }
        let timed = ask?.timed == true
        format.timed = timed ? true : nil
        if listeners[client.id] != nil { listeners[client.id] = (client, codec, timed) }
        outputs.setCodecs(Set(listeners.values.map(\.codec)))
        if ask != nil { Log.info("sound: \(client.device) gets \(codec)\(timed ? " with capture times" : "") over the WebSocket") }
        return format
    }

    /// The capture, started if it isn't running; answers its codecs' formats.
    private func capture() async throws -> [String: MacAudioFormat] {
        if let formats, streamer != nil { return formats }
        if let starting { return try await starting.value }
        let streamer = AudioStreamer(outputs: outputs)
        streamer.onPackets = { [weak self] packets in
            Task { @MainActor in self?.deliver(packets) }
        }
        streamer.onStop = { [weak self, weak streamer] _ in
            Task { @MainActor in self?.stopped(streamer) }
        }
        let start = Task { try await streamer.start() }
        starting = start
        defer { starting = nil }
        do {
            let formats = try await start.value
            // Everyone left, or the live screen was turned off, while it started.
            guard enabled, everyone else {
                await streamer.stop()
                throw WireError(code: "stopped", message: "The Mac's sound was turned off.")
            }
            self.streamer = streamer
            self.formats = formats
            return formats
        } catch {
            if let wire = error as? WireError { throw wire }
            throw WireError.failed("The Mac's sound couldn't be captured: \(error.localizedDescription)")
        }
    }

    func stopListening(client: ClientConnection) {
        guard forget(client), !everyone else { return }
        stopCapture()
    }

    /// Takes a phone off both lists; true if it was on one.
    @discardableResult
    private func forget(_ client: ClientConnection) -> Bool {
        let wasAAC = listeners.removeValue(forKey: client.id) != nil
        let wasOpus = opusListeners.removeValue(forKey: client.id) != nil
        outputs.removeOpus(client.id)
        outputs.setCodecs(Set(listeners.values.map(\.codec)))
        return wasAAC || wasOpus
    }

    /// The live screen was turned off: the phones see that and stop asking.
    func stopAll() {
        listeners.removeAll()
        opusListeners.removeAll()
        outputs.removeAll()
        stopCapture()
    }

    private func stopCapture() {
        formats = nil
        guard let streamer else { return }
        self.streamer = nil
        Task { await streamer.stop() }
    }

    /// The capture ended on its own: closing the phones' sound connections makes them ask again.
    private func stopped(_ streamer: AudioStreamer?) {
        guard let streamer, streamer === self.streamer else { return }
        self.streamer = nil
        formats = nil
        let gone = listeners.values.map(\.client) + Array(opusListeners.values)
        listeners.removeAll()
        opusListeners.removeAll()
        outputs.removeAll()
        for client in gone { client.close() }
    }

    /// One codec's packets to the phones taking it: as a timed message to those that asked for capture times, as the
    /// old untimed one to the rest.
    private func deliver(_ packets: AudioStreamer.Packets) {
        sequence &+= 1
        var timed: Data?
        var untimed: Data?
        for listener in listeners.values where listener.codec == packets.codec {
            if listener.timed, let captureTime = packets.captureTime {
                if timed == nil {
                    timed = TimedAudioMessage.make(sequence: sequence, captureTime: captureTime, packets: packets.packets)
                }
                if let timed { listener.client.sendAudio(timed) }
            } else {
                if untimed == nil { untimed = AudioPacketMessage.make(sequence: sequence, packets: packets.packets) }
                if let untimed { listener.client.sendAudio(untimed) }
            }
        }
    }

    // MARK: UDP

    /// A new target from a listener's session: its path or loss may have changed, and Opus follows.
    func mediaEvent(_ event: SenderEvent, from client: ClientConnection) {
        guard case .encoderTarget = event, opusListeners[client.id] === client, let session = client.udp else { return }
        let snapshot = session.snapshot
        outputs.setOpus(client.id, session: session, path: snapshot.path, plan: snapshot.plan)
    }

    /// A listener's UDP session ended: its sound has nowhere to go, so its connection closes and the phone asks again
    /// (over UDP if that works by then, else for AAC).
    func mediaEnded(_ client: ClientConnection) {
        guard opusListeners[client.id] === client else { return }
        client.close()
    }
}
