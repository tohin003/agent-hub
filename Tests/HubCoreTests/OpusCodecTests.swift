import Foundation
import Testing

/// libopus through the Swift wrapper: the Mac's sound in 10 ms frames, with lost packets rebuilt from in-band error
/// correction or concealed, and the transport's copies standing in for lost music.
@Suite("Opus")
struct OpusCodecTests {
    static let rate = Double(OpusFormat.sampleRate)

    /// 10 ms of a stereo tone, interleaved.
    static func tone(frame: Int, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        var samples = [Float](repeating: 0, count: OpusFormat.frameSamples * 2)
        for index in 0..<OpusFormat.frameSamples {
            let time = Double(frame * OpusFormat.frameSamples + index) / rate
            let value = amplitude * Float(sin(2 * .pi * frequency * time))
            samples[2 * index] = value
            samples[2 * index + 1] = value
        }
        return samples
    }

    /// 10 ms of something voice-like: a 140 Hz buzz with falling harmonics, in 4 Hz syllables.
    static func voice(frame: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: OpusFormat.frameSamples * 2)
        for index in 0..<OpusFormat.frameSamples {
            let time = Double(frame * OpusFormat.frameSamples + index) / rate
            let envelope = 0.15 + 0.35 * (0.5 + 0.5 * sin(2 * .pi * 4 * time))
            var value = 0.0
            for harmonic in 1...12 { value += sin(2 * .pi * 140 * Double(harmonic) * time) / Double(harmonic) }
            samples[2 * index] = Float(0.4 * envelope * value)
            samples[2 * index + 1] = Float(0.4 * envelope * value)
        }
        return samples
    }

    static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func encode(_ encoder: OpusAudioEncoder, _ samples: [Float]) throws -> [Data] {
        try samples.withUnsafeBufferPointer { try encoder.encode(interleaved: $0) }
    }

    @Test func aToneComesThroughAtItsLevelAndPitch() throws {
        let encoder = try OpusAudioEncoder(bitrate: 128_000)
        let decoder = try OpusAudioDecoder()
        var output: [Float] = []
        var sizes: [Int] = []
        for frame in 0..<200 {
            let packets = try Self.encode(encoder, Self.tone(frame: frame))
            #expect(packets.count == 1, "one packet per 10 ms")
            for packet in packets {
                sizes.append(packet.count)
                output += try decoder.decode(packet)
            }
        }
        #expect(output.count == 200 * OpusFormat.frameSamples * 2)
        #expect(output.allSatisfy { $0.isFinite })
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }.dropFirst(4_800)
        let level = Self.rms(left)
        let rises = zip(left, left.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let pitch = Double(rises) / (Double(left.count) / Self.rate)
        let bitrate = Double(sizes.reduce(0, +)) * 8 / 2
        reportMetric(String(format: "Opus 10 ms frames, 440 Hz tone at 128 kbit/s: level %.3f (0.354 in), pitch %.1f Hz, "
            + "%.0f kbit/s actual, look-ahead %ld samples (%.1f ms)", level, pitch, bitrate / 1000, encoder.lookahead,
                            Double(encoder.lookahead) / 48))
        #expect(abs(level - 0.3536) < 0.03)
        #expect(abs(pitch - 440) < 5)
        #expect(bitrate > 90_000 && bitrate < 160_000)
    }

    /// Voice at 40 kbit/s with in-band correction planned for 10% loss, 5% of packets lost: a lost packet is rebuilt
    /// from the next one's correction when that arrived, else concealed; the result keeps its level and has no gaps or
    /// bursts. (libopus 1.6 leaves in-band correction off when the rate is short of its threshold for the bandwidth and
    /// the expected loss is 5% or less: at 32 kbit/s and 5% no packet carries any.)
    @Test func voiceSurvivesFivePercentLoss() throws {
        let encoder = try OpusAudioEncoder(bitrate: 40_000, expectedLossPercent: 10)
        try encoder.setSignal(.voice)
        let reference = try OpusAudioDecoder()
        let decoder = try OpusAudioDecoder()
        let count = 400
        var packets: [Data] = []
        for frame in 0..<count { packets += try Self.encode(encoder, Self.voice(frame: frame)) }
        #expect(packets.count == count)
        var random = SeededGenerator(seed: 61)
        let lost = (0..<count).map { $0 > 0 && random.chance(0.05) }
        var clean: [Float] = []
        var heard: [Float] = []
        var corrected = 0
        var concealed = 0
        var lostLevels: [Float] = []
        for index in 0..<count {
            let expected = try reference.decode(packets[index])
            clean += expected
            let frame: [Float]
            if !lost[index] {
                frame = try decoder.decode(packets[index])
            } else if index + 1 < count, !lost[index + 1] {
                if OpusAudioDecoder.hasInBandFEC(packets[index + 1]) { corrected += 1 } else { concealed += 1 }
                frame = try decoder.recover(lostBefore: packets[index + 1])
            } else {
                concealed += 1
                frame = try decoder.conceal()
            }
            if lost[index], Self.rms(expected) > 0.01 { lostLevels.append(Self.rms(frame) / Self.rms(expected)) }
            heard += frame
        }
        let withCorrection = packets.filter(OpusAudioDecoder.hasInBandFEC).count
        var noise = 0.0
        var signal = 0.0
        for (expected, got) in zip(clean, heard) {
            signal += Double(expected * expected)
            noise += Double((expected - got) * (expected - got))
        }
        let snr = 10 * log10(signal / max(noise, 1e-12))
        let level = Self.rms(heard) / Self.rms(clean)
        let lostLevel = lostLevels.reduce(0, +) / Float(max(lostLevels.count, 1))
        reportMetric(String(format: "Opus voice, 40 kbit/s planned for 10%% loss, 5%% lost: %ld of %ld lost, %ld rebuilt from in-band correction, %ld "
            + "concealed; %ld%% of packets carry correction; level %.2f of the lossless decode (%.2f in lost frames); "
            + "SNR against the lossless decode %.1f dB", lost.filter { $0 }.count, count, corrected, concealed,
                            withCorrection * 100 / count, level, lostLevel, snr))
        #expect(heard.count == clean.count && heard.allSatisfy(\.isFinite))
        #expect(heard.allSatisfy { abs($0) <= 1.5 }, "no bursts")
        #expect(withCorrection > count / 2, "voice packets carry in-band correction")
        #expect(corrected > 0)
        #expect(level > 0.8 && level < 1.2)
        #expect(lostLevel > 0.3, "lost frames are filled, not silent")
    }

    /// Music (CELT, no in-band correction) with 5% of packets lost: one copy of the previous frame in each sound packet
    /// brings back nearly all of it; only what's lost twice in a row is concealed.
    @Test func copiesBringBackLostMusic() throws {
        let encoder = try OpusAudioEncoder(bitrate: 96_000, expectedLossPercent: 5)
        try encoder.setSignal(.music)
        let decoder = try OpusAudioDecoder()
        var packetizer = AudioPacketizer(redundancy: 1)
        var depacketizer = AudioDepacketizer()
        var random = SeededGenerator(seed: 62)
        let count = 500
        var arrived: [UInt32: Data] = [:]
        for frame in 0..<count {
            for packet in try Self.encode(encoder, Self.tone(frame: frame, frequency: 523.25, amplitude: 0.4)) {
                let packetized = packetizer.packetize(packet, timestamp: UInt64(frame) * 10_000, duration: 10_000)
                let bundle = try #require(packetized)
                guard frame == 0 || !random.chance(0.05) else { continue }
                for received in depacketizer.unpack(bundle) { arrived[received.sequence] = received.data }
            }
        }
        var output: [Float] = []
        var concealed = 0
        for sequence in UInt32(1)...UInt32(count) {
            if let packet = arrived[sequence] {
                output += try decoder.decode(packet)
            } else {
                concealed += 1
                output += try decoder.conceal()
            }
        }
        let share = Double(arrived.count) / Double(count)
        reportMetric(String(format: "Opus music, 96 kbit/s, 5%% of packets lost, one copy each: %.1f%% of frames arrive, "
            + "%ld concealed, level %.3f (0.283 in)", share * 100, concealed, Self.rms(output.dropFirst(9_600))))
        #expect(share >= 0.99)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(abs(Self.rms(output.dropFirst(9_600)) - 0.283) < 0.04)
    }
}
