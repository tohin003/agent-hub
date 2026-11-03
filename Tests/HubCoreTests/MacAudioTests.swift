import AVFAudio
import Foundation
import Testing

/// The Mac's sound on the wire: the message framing, and AAC through the encoder (the hub's) and decoder (the
/// phone's).
@Suite("Mac sound")
struct MacAudioTests {
    @Test func messagesKeepTheirPackets() throws {
        let packets = [Data([1, 2, 3]), Data(repeating: 7, count: 700), Data([9])]
        let message = AudioPacketMessage.make(sequence: 0xDEAD_BEEF, packets: packets)
        let parsed = try #require(AudioPacketMessage.parse(message))
        #expect(parsed.sequence == 0xDEAD_BEEF)
        #expect(parsed.packets == packets)
        #expect(message.count == AudioPacketMessage.headerSize + packets.reduce(0) { $0 + 2 + $1.count })
    }

    @Test func otherMessagesAreRefused() {
        let message = AudioPacketMessage.make(sequence: 1, packets: [Data([1, 2, 3])])
        #expect(AudioPacketMessage.parse(message.dropLast()) == nil, "cut short")
        #expect(AudioPacketMessage.parse(message + Data([0])) == nil, "trailing bytes")
        var frame = message
        frame[frame.startIndex] = ScreenFrameHeader.jpegKind
        #expect(AudioPacketMessage.parse(frame) == nil, "a screen frame")
        #expect(ScreenFrameHeader.parse(message) == nil, "the screen side ignores sound")
        #expect(AudioPacketMessage.parse(Data()) == nil)
    }

    /// A tone through the encoder, the wire and the decoder comes out as the same tone: about as loud, at the same
    /// pitch.
    @Test func aacKeepsTheSound() throws {
        let rate = 48_000.0
        let encoder = try MacAudioEncoder(sampleRate: rate, channels: 2)
        #expect(!encoder.format.magicCookie.isEmpty, "the decoder needs the encoder's cookie")
        let decoder = try MacAudioDecoder(format: encoder.format)
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frequency = 440.0
        let amplitude: Float = 0.5
        var played = 0
        var heard: [Float] = []
        // One second, in the 480-frame pieces (10 ms) ScreenCaptureKit hands over.
        for _ in 0..<100 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
            buffer.frameLength = 480
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<480 {
                let sample = amplitude * Float(sin(2 * .pi * frequency * Double(played + frame) / rate))
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
            played += 480
            let sent = AudioPacketMessage.make(sequence: 1, packets: encoder.encode(buffer))
            guard let received = AudioPacketMessage.parse(sent), let pcm = decoder.decode(received.packets),
                  let left = pcm.floatChannelData?[0] else { continue }
            heard += UnsafeBufferPointer(start: left, count: Int(pcm.frameLength))
        }
        #expect(heard.count > Int(rate * 0.85), "most of the second arrives (the encoder holds back a packet or two)")
        let steady = Array(heard.dropFirst(4096))
        try #require(steady.count > 1000)
        let loudness = sqrt(steady.reduce(0) { $0 + $1 * $1 } / Float(steady.count))
        #expect(abs(loudness - amplitude / Float(2).squareRoot()) < 0.05, "loudness \(loudness)")
        let rises = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let pitch = Double(rises) / (Double(steady.count) / rate)
        #expect(abs(pitch - frequency) < 10, "pitch \(pitch) Hz")
    }
}
