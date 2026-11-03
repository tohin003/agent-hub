import Foundation
import Testing

/// The live picture's binary messages: video frames, keepalive ticks and the pointer. Both apps depend on these
/// layouts byte for byte.
@Suite("Stream messages")
struct StreamMessagesTests {
    @Test func videoFramesKeepEverything() throws {
        let frame = VideoFrameMessage(displayID: 0xA1B2_C3D4, width: 1920, height: 1248, sequence: 77,
                                      captureTime: 432_101.123_456_789, codec: .hevc, flags: [.keyframe, .refresh, .chroma444],
                                      ltrToken: 0xDEAD_BEEF, parameterSets: [Data([0x40, 1]), Data([0x42, 2, 3]), Data([0x44])],
                                      data: Data([0, 0, 0, 3, 0x26, 1, 0xAF]))
        let parsed = try #require(VideoFrameMessage.parse(frame.encoded()))
        #expect(parsed == frame)
        #expect(parsed.captureTime == 432_101.123_456_789, "capture time keeps full Float64 precision")
        #expect(frame.encoded()[22] & VideoFrameMessage.Flags.parameterSets.rawValue != 0, "the flag follows the sets")
    }

    @Test func deltaFramesNeedNoParameterSets() throws {
        let frame = VideoFrameMessage(displayID: 1, width: 1280, height: 832, sequence: 2, captureTime: 1, codec: .h264,
                                      flags: [], data: Data(repeating: 9, count: 3000))
        let message = frame.encoded()
        #expect(message.count == VideoFrameMessage.headerSize + 3000)
        #expect(VideoFrameMessage.parse(message) == frame)
    }

    @Test func brokenVideoFramesAreRefused() {
        let frame = VideoFrameMessage(displayID: 1, width: 10, height: 10, sequence: 1, captureTime: 0, codec: .hevc,
                                      flags: .keyframe, parameterSets: [Data([1, 2, 3])], data: Data([1]))
        let message = frame.encoded()
        #expect(VideoFrameMessage.parse(message.prefix(VideoFrameMessage.headerSize + 3)) == nil, "cut inside the sets")
        var unknownCodec = message
        unknownCodec[unknownCodec.startIndex + 21] = 9
        #expect(VideoFrameMessage.parse(unknownCodec) == nil)
        #expect(VideoFrameMessage.parse(StreamKeepalive.message) == nil)
        #expect(ScreenFrameHeader.parse(message) == nil, "the JPEG reader ignores video frames")
        #expect(AudioPacketMessage.parse(message) == nil)
    }

    @Test func pointerMessagesRoundTrip() throws {
        let position = CursorPositionMessage(displayID: 5, x: 0.25, y: 0.75, visible: true, shapeID: 12)
        #expect(position.encoded().count == CursorPositionMessage.size)
        #expect(CursorPositionMessage.parse(position.encoded()) == position)
        let shape = CursorShapeMessage(shapeID: 12, width: 17, height: 23, hotSpotX: 4, hotSpotY: 3.5,
                                       png: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(CursorShapeMessage.parse(shape.encoded()) == shape)
        #expect(CursorPositionMessage.parse(shape.encoded()) == nil)
        #expect(CursorShapeMessage.parse(position.encoded()) == nil)
    }

    @Test func eachKindHasItsOwnFirstByte() {
        let kinds: [UInt8] = [StreamKeepalive.kind, ScreenFrameHeader.jpegKind, AudioPacketMessage.kind,
                              VideoFrameMessage.kind, CursorPositionMessage.kind, CursorShapeMessage.kind]
        #expect(Set(kinds).count == kinds.count)
    }

    @Test func feedbackAndStartParamsDecodeFromOlderJSON() throws {
        let old = try JSONDecoder().decode(ScreenStartParams.self, from: Data(#"{"maxPixels":1700,"fps":8,"quality":0.6}"#.utf8))
        #expect(old.codec == nil && old.bitrate == nil && old.chroma444 == nil && old.cursor == nil)
        let feedback = ScreenFeedback(sequence: 9, ltrTokens: [3, 4], refresh: true, receivedBytes: 4096, intervalMs: 20,
                                      decodeMs: 1.5)
        #expect(try JSONDecoder().decode(ScreenFeedback.self, from: JSONEncoder().encode(feedback)) == feedback)
    }
}
