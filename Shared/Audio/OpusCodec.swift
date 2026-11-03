import AVFAudio
import Foundation
import Opus

// The Mac's sound as Opus (libopus, BSD licence): 48 kHz stereo in 10 ms frames, encoded on the Mac and decoded on the
// phone, whose packet-loss concealment and in-band error correction cover lost packets. Both sides compile this file.
//
// The encoder runs in Opus's "audio" application: the Mac plays music, video and voices alike, and this mode keeps
// music full-band while still switching to its speech coder (SILK, hybrid) for voices, the only modes whose in-band
// error correction works. The low-delay mode would save 4 ms of look-ahead but loses that correction and the speech
// coder. In-band error correction is set to 2, "on, but music stays music": setting 1 would push music into the
// speech coder once loss is high, costing quality the transport's redundant copies make unnecessary. 10 ms frames
// keep the framing delay small; constrained VBR keeps packet sizes near the bitrate so the pacer can plan for them.
// Bitrate and expected loss follow the path profile (128 kbit/s direct, 96 relay, 64 DERP).

nonisolated public enum OpusFormat {
    public static let sampleRate = 48_000
    public static let channels = 2
    /// Samples per channel in one 10 ms frame.
    public static let frameSamples = 480
    /// One frame in µs, as sound bundles carry it.
    public static let frameDuration: UInt16 = 10_000
    /// The largest packet Opus produces.
    public static let maxPacketSize = 1275
}

nonisolated public struct OpusError: Error, Equatable, LocalizedError {
    public var code: Int32

    public init(_ code: Int32) {
        self.code = code
    }

    public var errorDescription: String? {
        guard let text = opus_strerror(code) else { return "Opus error \(code)" }
        return "Opus: \(String(cString: text))"
    }
}

/// PCM in, Opus packets out (on the Mac). Not thread-safe: one capture queue feeds it.
nonisolated public final class OpusAudioEncoder {
    public let channels: Int
    public private(set) var bitrate: Int
    public private(set) var expectedLossPercent: Int
    private let encoder: OpaquePointer
    /// Interleaved samples waiting for a whole frame.
    private var pending: [Float] = []

    public init(channels: Int = OpusFormat.channels, bitrate: Int = 128_000, expectedLossPercent: Int = 2,
                complexity: Int = 10) throws {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(Int32(OpusFormat.sampleRate), Int32(channels), OPUS_APPLICATION_AUDIO,
                                                &error) else { throw OpusError(error) }
        guard error == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw OpusError(error)
        }
        self.encoder = encoder
        self.channels = channels
        self.bitrate = bitrate
        self.expectedLossPercent = expectedLossPercent
        try set(OPUS_SET_EXPERT_FRAME_DURATION_REQUEST, OPUS_FRAMESIZE_10_MS)
        try set(OPUS_SET_BITRATE_REQUEST, Int32(bitrate))
        try set(OPUS_SET_VBR_REQUEST, 1)
        try set(OPUS_SET_VBR_CONSTRAINT_REQUEST, 1)
        try set(OPUS_SET_COMPLEXITY_REQUEST, Int32(complexity))
        try set(OPUS_SET_INBAND_FEC_REQUEST, 2)
        try set(OPUS_SET_PACKET_LOSS_PERC_REQUEST, Int32(expectedLossPercent))
    }

    /// What the sound is, when known; Opus otherwise decides frame by frame.
    nonisolated public enum Signal: Sendable {
        case automatic, voice, music
    }

    public func setSignal(_ signal: Signal) throws {
        switch signal {
        case .automatic: try set(OPUS_SET_SIGNAL_REQUEST, OPUS_AUTO)
        case .voice: try set(OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_VOICE)
        case .music: try set(OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_MUSIC)
        }
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    public func setBitrate(_ bitrate: Int) throws {
        try set(OPUS_SET_BITRATE_REQUEST, Int32(clamping: bitrate))
        self.bitrate = bitrate
    }

    /// The loss the in-band error correction plans for: more spends more of the bitrate on it.
    public func setExpectedLoss(percent: Int) throws {
        let percent = min(max(percent, 0), 100)
        try set(OPUS_SET_PACKET_LOSS_PERC_REQUEST, Int32(percent))
        expectedLossPercent = percent
    }

    /// Bitrate and expected loss for a path.
    public func configure(profile: PathProfile, plan: RecoveryPlan) throws {
        try setBitrate(profile.opusBitrate)
        try setExpectedLoss(percent: plan.opusExpectedLossPercent)
    }

    /// Opus's current algorithmic delay in samples at 48 kHz (its look-ahead).
    public var lookahead: Int {
        var value: Int32 = 0
        _ = opus_swift_encoder_get(encoder, OPUS_GET_LOOKAHEAD_REQUEST, &value)
        return Int(value)
    }

    /// The packets the given interleaved samples complete; the rest waits for the next call.
    public func encode(interleaved samples: UnsafeBufferPointer<Float>) throws -> [Data] {
        pending.append(contentsOf: samples)
        let frameLength = OpusFormat.frameSamples * channels
        var packets: [Data] = []
        var start = 0
        var output = [UInt8](repeating: 0, count: OpusFormat.maxPacketSize)
        while pending.count - start >= frameLength {
            let size = pending.withUnsafeBufferPointer { input -> Int32 in
                output.withUnsafeMutableBufferPointer { out -> Int32 in
                    guard let source = input.baseAddress, let destination = out.baseAddress else { return OPUS_BAD_ARG }
                    return opus_encode_float(encoder, source + start, Int32(OpusFormat.frameSamples), destination,
                                             Int32(out.count))
                }
            }
            guard size > 0 else { throw OpusError(size) }
            packets.append(Data(output.prefix(Int(size))))
            start += frameLength
        }
        pending.removeFirst(start)
        return packets
    }

    /// The packets a capture buffer completes (any layout AVAudioPCMBuffer holds as float, one or two channels).
    public func encode(_ buffer: AVAudioPCMBuffer) throws -> [Data] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return [] }
        let sourceChannels = Int(buffer.format.channelCount)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let source = min(channel, sourceChannels - 1)
                interleaved[frame * channels + channel] = buffer.format.isInterleaved
                    ? data[0][frame * sourceChannels + source]
                    : data[source][frame]
            }
        }
        return try interleaved.withUnsafeBufferPointer { try encode(interleaved: $0) }
    }

    private func set(_ request: Int32, _ value: Int32) throws {
        let result = opus_swift_encoder_set(encoder, request, value)
        guard result == OPUS_OK else { throw OpusError(result) }
    }
}

/// Opus packets in, PCM out (on the phone): one 10 ms frame per call, interleaved float at 48 kHz.
nonisolated public final class OpusAudioDecoder {
    public let channels: Int
    private let decoder: OpaquePointer

    public init(channels: Int = OpusFormat.channels) throws {
        var error: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(OpusFormat.sampleRate), Int32(channels), &error) else {
            throw OpusError(error)
        }
        guard error == OPUS_OK else {
            opus_decoder_destroy(decoder)
            throw OpusError(error)
        }
        self.decoder = decoder
        self.channels = channels
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// A packet's sound.
    public func decode(_ packet: Data) throws -> [Float] {
        try run(packet, fec: false)
    }

    /// The sound of a lost packet, from the in-band error correction in the packet after it (decode that one next,
    /// as usual). Without correction data in it, libopus conceals instead.
    public func recover(lostBefore next: Data) throws -> [Float] {
        try run(next, fec: true)
    }

    /// The sound of a lost packet when nothing after it has arrived: libopus's packet-loss concealment.
    public func conceal() throws -> [Float] {
        try run(nil, fec: false)
    }

    /// Whether a packet carries in-band error correction for the one before it.
    public static func hasInBandFEC(_ packet: Data) -> Bool {
        packet.withUnsafeBytes { raw in
            opus_packet_has_lbrr(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count)) == 1
        }
    }

    private func run(_ packet: Data?, fec: Bool) throws -> [Float] {
        var pcm = [Float](repeating: 0, count: OpusFormat.frameSamples * channels)
        let decoded = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
            guard let destination = out.baseAddress else { return OPUS_BAD_ARG }
            guard let packet else {
                return opus_decode_float(decoder, nil, 0, destination, Int32(OpusFormat.frameSamples), 0)
            }
            return packet.withUnsafeBytes { raw in
                opus_decode_float(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), destination,
                                  Int32(OpusFormat.frameSamples), fec ? 1 : 0)
            }
        }
        guard decoded >= 0 else { throw OpusError(decoded) }
        if Int(decoded) < OpusFormat.frameSamples { pcm.removeLast((OpusFormat.frameSamples - Int(decoded)) * channels) }
        return pcm
    }
}
