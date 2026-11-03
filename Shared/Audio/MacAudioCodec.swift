import AVFAudio
import Foundation

// The Mac's sound on the WebSocket: encoded on the Mac, decoded on the phone. AAC-ELD (low delay: 10 ms packets, 5 ms
// of encoder delay) for phones that ask for it, AAC-LC (44 ms of encoder delay) for older ones. Over UDP the sound is
// Opus instead (`OpusCodec`). Both sides compile this file.

nonisolated public enum MacAudioCodec {
    /// AAC-LC, 1,024 frames a packet: what phones from before step 2 decode.
    public static let aacLC = "aac"
    /// AAC-ELD, 480 frames (10 ms at 48 kHz) a packet.
    public static let aacELD = "aac-eld"
    /// AAC-LC's packet size, which `MacAudioFormat` reports for it.
    public static let framesPerPacket = 1024

    public static func framesPerPacket(_ codec: String) -> Int {
        codec == aacELD ? 480 : framesPerPacket
    }

    static func compressed(_ codec: String, sampleRate: Double, channels: Int) -> AVAudioFormat? {
        let eld = codec == aacELD
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: eld ? kAudioFormatMPEG4AAC_ELD : kAudioFormatMPEG4AAC,
            mFormatFlags: eld ? 0 : AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket(codec)), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }

    static func aac(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        compressed(aacLC, sampleRate: sampleRate, channels: channels)
    }

    static func pcm(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
    }
}

/// PCM in, AAC-LC or AAC-ELD packets out (on the Mac). Not thread-safe: one capture queue feeds it.
nonisolated public final class MacAudioEncoder {
    public let format: MacAudioFormat
    public let codec: String
    /// The encoder's own delay in samples (its priming): the decoder's first `leadingFrames` samples come before the
    /// first sample put in. Measured on this Mac: AAC-LC 2,112 (44 ms), AAC-ELD 240 (5 ms).
    public let leadingFrames: Int
    private let output: AVAudioFormat
    private let bitRate: Int
    private var input: AVAudioFormat
    private var converter: AVAudioConverter

    public convenience init(sampleRate: Double, channels: Int, bitRate: Int = 128_000) throws {
        try self.init(codec: MacAudioCodec.aacLC, sampleRate: sampleRate, channels: channels, bitRate: bitRate)
    }

    public init(codec: String, sampleRate: Double, channels: Int, bitRate: Int = 128_000) throws {
        guard let input = MacAudioCodec.pcm(sampleRate: sampleRate, channels: channels),
              let output = MacAudioCodec.compressed(codec, sampleRate: sampleRate, channels: channels),
              let converter = Self.converter(from: input, to: output, bitRate: bitRate) else {
            throw WireError.failed("The Mac's sound encoder couldn't start.")
        }
        self.codec = codec
        self.input = input
        self.output = output
        self.bitRate = bitRate
        self.converter = converter
        leadingFrames = Int(converter.primeInfo.leadingFrames)
        format = MacAudioFormat(codec: codec, sampleRate: sampleRate, channels: channels,
                                framesPerPacket: MacAudioCodec.framesPerPacket(codec), magicCookie: converter.magicCookie ?? Data())
    }

    private static func converter(from input: AVAudioFormat, to output: AVAudioFormat, bitRate: Int) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: output)
        converter?.bitRate = bitRate
        return converter
    }

    /// The whole packets these frames complete; the rest waits inside the encoder for the next call.
    public func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format != input {
            // A different sample layout than expected: a converter for it (the AAC side, and so the cookie, stays).
            guard let fresh = Self.converter(from: buffer.format, to: output, bitRate: bitRate) else { return [] }
            input = buffer.format
            converter = fresh
        }
        var packets: [Data] = []
        var supplied = false
        while true {
            let out = AVAudioCompressedBuffer(format: output, packetCapacity: 16,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            packets += Self.packets(in: out)
            // .haveData means the output filled up with more to come; anything else, it's used everything it can.
            guard status == .haveData else { break }
        }
        return packets
    }

    private static func packets(in buffer: AVAudioCompressedBuffer) -> [Data] {
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else { return [] }
        return (0..<Int(buffer.packetCount)).compactMap { index in
            let description = descriptions[index]
            guard description.mDataByteSize > 0 else { return nil }
            return Data(bytes: buffer.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize))
        }
    }
}

/// AAC-LC or AAC-ELD packets in, PCM out (on the phone).
nonisolated public final class MacAudioDecoder {
    public let pcmFormat: AVAudioFormat
    private let compressed: AVAudioFormat
    private let converter: AVAudioConverter
    private let framesPerPacket: Int

    public init(format: MacAudioFormat) throws {
        guard format.codec == MacAudioCodec.aacLC || format.codec == MacAudioCodec.aacELD,
              let compressed = MacAudioCodec.compressed(format.codec, sampleRate: format.sampleRate, channels: format.channels),
              let pcm = MacAudioCodec.pcm(sampleRate: format.sampleRate, channels: format.channels),
              let converter = AVAudioConverter(from: compressed, to: pcm) else {
            throw WireError.failed("This iPhone can't play the Mac's sound (\(format.codec)).")
        }
        if !format.magicCookie.isEmpty { converter.magicCookie = format.magicCookie }
        self.compressed = compressed
        pcmFormat = pcm
        self.converter = converter
        framesPerPacket = max(format.framesPerPacket, 1)
    }

    /// The sound in these packets; nil while the decoder is still filling (AAC-LC's first packet or two).
    public func decode(_ packets: [Data]) -> AVAudioPCMBuffer? {
        let packets = packets.filter { !$0.isEmpty }
        guard let largest = packets.map(\.count).max() else { return nil }
        let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: AVAudioPacketCount(packets.count),
                                            maximumPacketSize: largest)
        guard let descriptions = input.packetDescriptions else { return nil }
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { input.data.advanced(by: offset).copyMemory(from: base, byteCount: packet.count) }
            }
            descriptions[index] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                               mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(packets.count * framesPerPacket)) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
