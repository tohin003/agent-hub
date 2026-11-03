import AVFAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the Mac's sound, every app's, before the output volume and mute (so a muted Mac still sends it), and
/// encodes it for the phones listening (`AudioOutputs`): AAC-ELD (10 ms packets, 5 ms of encoder delay) over the
/// WebSocket for phones from step 2 on, AAC-LC for older ones, and Opus in 10 ms frames for those on UDP. Each
/// encoder runs only while someone takes it. Every packet is stamped with the capture time of the first sample its
/// decoder gives back (`SampleClock`, with the encoder's own delay taken off), on the same host clock as the picture's
/// frames. ScreenCaptureKit captures sound only alongside a display, so the stream also takes the smallest, slowest
/// picture, which nothing reads.
final class AudioStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let sampleRate = 48_000
    static let channels = 2

    /// Packets for the WebSocket, with the capture time (µs on the host clock) of the first decoded sample of the
    /// first one.
    struct Packets {
        var codec: String
        var packets: [Data]
        var captureTime: Int64?
    }

    /// Which encodings the phones listening need, and where Opus frames go.
    let outputs: AudioOutputs
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "agenthub.sound", qos: .userInitiated)
    // Used on `queue` only:
    private var encoders: [String: (encoder: MacAudioEncoder, clock: SampleClock, packets: Int)] = [:]
    private var opus: OpusAudioEncoder?
    private var opusClock: SampleClock?
    private var opusPackets = 0
    /// The `AudioOutputs` configuration the Opus encoder runs with.
    private var opusVersion = -1
    /// Called on the capture queue with each batch of AAC packets.
    var onPackets: ((Packets) -> Void)?
    var onStop: ((Error?) -> Void)?

    init(outputs: AudioOutputs) {
        self.outputs = outputs
    }

    /// Starts capturing; answers each WebSocket codec's format (its magic cookie is fixed per encoder).
    func start() async throws -> [String: MacAudioFormat] {
        var formats: [String: MacAudioFormat] = [:]
        var made: [String: MacAudioEncoder] = [:]
        for codec in [MacAudioCodec.aacELD, MacAudioCodec.aacLC] {
            do {
                let encoder = try MacAudioEncoder(codec: codec, sampleRate: Double(Self.sampleRate), channels: Self.channels)
                made[codec] = encoder
                formats[codec] = encoder.format
            } catch {
                Log.warn("sound: no \(codec) encoder: \(error.localizedDescription)")
            }
        }
        guard made[MacAudioCodec.aacLC] != nil else { throw WireError.failed("The Mac's sound encoder couldn't start.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw WireError.notFound("The Mac has no display to capture its sound with.") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = Self.channels
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // The picture nobody reads still needs somewhere to go.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            encoders = made.mapValues { encoder in
                (encoder, SampleClock(sampleRate: Double(Self.sampleRate), leadingFrames: encoder.leadingFrames), 0)
            }
            opus = nil
        }
        try await stream.startCapture()
        self.stream = stream
        Log.info("sound: capturing the Mac's sound (AAC-ELD, AAC-LC and Opus, \(Self.sampleRate / 1000) kHz)")
        return formats
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Log.info("sound: stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcm(sampleBuffer) else { return }
        let captureTime = Int64(max(sampleBuffer.presentationTimeStamp.seconds, 0) * 1_000_000)
        let wanted = outputs.current()
        for codec in wanted.codecs {
            encode(pcm, at: captureTime, codec: codec)
        }
        if wanted.opus.isEmpty {
            // Nobody on UDP: the next listener starts a fresh encoder.
            opus = nil
        } else {
            sendOpus(pcm, at: captureTime, to: wanted)
        }
    }

    /// One AAC codec's packets for this buffer, stamped.
    private func encode(_ pcm: AVAudioPCMBuffer, at captureTime: Int64, codec: String) {
        guard var entry = encoders[codec] else { return }
        entry.clock.input(frames: Int(pcm.frameLength), captureTime: captureTime)
        let packets = entry.encoder.encode(pcm)
        let first = entry.clock.captureTime(ofDecodedSample: entry.packets * MacAudioCodec.framesPerPacket(codec))
        entry.packets += packets.count
        encoders[codec] = entry
        guard !packets.isEmpty else { return }
        onPackets?(Packets(codec: codec, packets: packets, captureTime: first))
    }

    /// Encodes 10 ms Opus frames and hands each to every UDP session, stamped with the capture time of its first
    /// decoded sample (µs).
    private func sendOpus(_ pcm: AVAudioPCMBuffer, at captureTime: Int64, to wanted: AudioOutputs.Snapshot) {
        if opus == nil {
            opus = try? OpusAudioEncoder(channels: Self.channels)
            opusVersion = -1
            opusPackets = 0
            opusClock = opus.map { SampleClock(sampleRate: Double(Self.sampleRate), leadingFrames: $0.lookahead) }
        }
        guard let opus, var clock = opusClock else { return }
        if wanted.version != opusVersion {
            opusVersion = wanted.version
            do {
                try opus.configure(profile: wanted.profile, plan: wanted.plan)
            } catch {
                Log.warn("sound: Opus wouldn't take the \(wanted.profile.path.rawValue) settings: \(error.localizedDescription)")
            }
        }
        clock.input(frames: Int(pcm.frameLength), captureTime: captureTime)
        opusClock = clock
        let packets: [Data]
        do {
            packets = try opus.encode(pcm)
        } catch {
            Log.warn("sound: Opus failed: \(error.localizedDescription)")
            self.opus = nil
            return
        }
        for packet in packets {
            let timestamp = clock.captureTime(ofDecodedSample: opusPackets * OpusFormat.frameSamples) ?? captureTime
            opusPackets += 1
            for session in wanted.opus {
                session.sendAudio(packet, timestamp: UInt64(max(timestamp, 0)), duration: OpusFormat.frameDuration)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("sound: capture stopped: \(error.localizedDescription)")
        self.stream = nil
        onStop?(error)
    }

    /// The sample buffer's PCM, in a buffer the encoder takes.
    private static func pcm(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// What the sound capture encodes, set on the main thread and read on the capture queue: the AAC codecs the phones on
/// the WebSocket take, and Opus for the UDP sessions listening. With several on different paths, Opus takes the
/// slowest path's bitrate and the highest expected loss.
final class AudioOutputs: @unchecked Sendable {
    struct Snapshot {
        var codecs: Set<String>
        var opus: [UDPServerSession]
        var profile: PathProfile
        var plan: RecoveryPlan
        /// Changes whenever the Opus settings do.
        var version: Int
    }

    private let lock = NSLock()
    private var codecs: Set<String> = []
    private var listeners: [UUID: (session: UDPServerSession, path: PathKind, plan: RecoveryPlan)] = [:]
    private var version = 0

    /// The AAC codecs some phone on the WebSocket takes.
    func setCodecs(_ codecs: Set<String>) {
        lock.withLock { self.codecs = codecs }
    }

    /// A phone takes Opus over this session, on this path and plan (again when they change).
    func setOpus(_ id: UUID, session: UDPServerSession, path: PathKind, plan: RecoveryPlan) {
        lock.withLock {
            listeners[id] = (session, path, plan)
            version += 1
        }
    }

    func removeOpus(_ id: UUID) {
        lock.withLock {
            guard listeners.removeValue(forKey: id) != nil else { return }
            version += 1
        }
    }

    func removeAll() {
        lock.withLock {
            codecs = []
            listeners.removeAll()
            version += 1
        }
    }

    func current() -> Snapshot {
        lock.withLock {
            let entries = Array(listeners.values)
            let slowest = entries.min { PathProfile.profile(for: $0.path).opusBitrate < PathProfile.profile(for: $1.path).opusBitrate }
            var plan = slowest?.plan ?? RecoveryPolicy.plan(profile: .profile(for: .unknown), network: .other,
                                                            roundTripMs: nil, lossRate: 0)
            plan.opusExpectedLossPercent = entries.map(\.plan.opusExpectedLossPercent).max() ?? plan.opusExpectedLossPercent
            return Snapshot(codecs: codecs, opus: entries.map(\.session), profile: .profile(for: slowest?.path ?? .unknown),
                            plan: plan, version: version)
        }
    }
}
