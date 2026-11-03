import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

/// The phone's video decoder, fed by a low-latency hardware encoder set up as the hub sets one up: frames cross the
/// wire format and come back at their size and in their colours, HEVC 4:2:0 and 4:4:4 and H.264.
@Suite("Video decoder")
struct VideoDecoderTests {
    enum Stream: String, CustomTestStringConvertible, CaseIterable {
        case hevc, hevc444, h264

        var codec: VideoFrameMessage.Codec { self == .h264 ? .h264 : .hevc }
        var chroma444: Bool { self == .hevc444 }
        var testDescription: String { rawValue }
    }

    /// A keyframe, then frames that only change: each decodes to the picture drawn, at the size sent.
    @Test(arguments: Stream.allCases)
    func framesDecodeAtTheirSizeAndColour(_ stream: Stream) throws {
        let encoder = try VideoTestEncoder(codec: stream.codec, width: 640, height: 416, chroma444: stream.chroma444)
        let decoder = VideoDecoder()
        for step in 0..<4 {
            let sent = try encoder.encode(keyframe: step == 0, draw: VideoScene.drawing(width: 640, height: 416, step: step))
            #expect(sent.flags.contains(.keyframe) == (step == 0))
            #expect(sent.parameterSets.isEmpty == (step != 0), "parameter sets come with keyframes only")
            #expect(sent.flags.contains(.chroma444) == stream.chroma444)
            let received = try #require(VideoFrameMessage.parse(sent.encoded()))
            let picture = try decoder.decode(received)
            #expect(picture.width == 640 && picture.height == 416)
            #expect(picture.decodeMs >= 0 && picture.decodeMs < 1000)
            try picture.pixelBuffer.withUnsafeBuffer { buffer in
                #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
                #expect(CVPixelBufferGetIOSurface(buffer) != nil, "IOSurface-backed, for the display layer")
                for probe in VideoScene.probes(width: 640, height: 416, step: step) {
                    let got = try VideoPixels.rgb(buffer, x: probe.x, y: probe.y)
                    #expect(VideoPixels.near(got, probe.color, within: 40), "step \(step) at \(probe.x),\(probe.y): \(got)")
                }
                if stream.chroma444 {
                    // One-pixel red and blue stripes keep their colours: 4:2:0 would make both purple.
                    let red = try VideoPixels.rgb(buffer, x: 320, y: 400)
                    let blue = try VideoPixels.rgb(buffer, x: 321, y: 400)
                    #expect(Int(red.red) - Int(red.blue) > 100 && Int(blue.blue) - Int(blue.red) > 100, "\(red) \(blue)")
                }
            }
        }
    }

    /// The hub starts a new encoder at another size: the keyframe's parameter sets take the same decoder there, odd
    /// sizes (cropped by the stream) included.
    @Test func newParameterSetsChangeTheSize() throws {
        let decoder = VideoDecoder()
        for (width, height) in [(640, 416), (1918, 1246), (1280, 832)] {
            let encoder = try VideoTestEncoder(codec: .hevc, width: width, height: height, chroma444: false)
            for step in 0..<2 {
                let frame = try encoder.encode(keyframe: step == 0, draw: VideoScene.drawing(width: width, height: height, step: step))
                let picture = try decoder.decode(try #require(VideoFrameMessage.parse(frame.encoded())))
                #expect(picture.width == width && picture.height == height)
                try picture.pixelBuffer.withUnsafeBuffer { buffer in
                    for probe in VideoScene.probes(width: width, height: height, step: step) {
                        let got = try VideoPixels.rgb(buffer, x: probe.x, y: probe.y)
                        #expect(VideoPixels.near(got, probe.color, within: 40), "\(width)×\(height) at \(probe.x),\(probe.y): \(got)")
                    }
                }
            }
        }
    }

    /// Joining a stream part-way: a frame before any parameter sets can't decode, and says so.
    @Test func framesBeforeAnyParameterSetsAreRefused() throws {
        let encoder = try VideoTestEncoder(codec: .hevc, width: 320, height: 208, chroma444: false)
        _ = try encoder.encode(keyframe: true, draw: VideoScene.drawing(width: 320, height: 208, step: 0))
        let delta = try encoder.encode(keyframe: false, draw: VideoScene.drawing(width: 320, height: 208, step: 1))
        #expect(throws: VideoDecoder.Failure.noParameterSets) { try VideoDecoder().decode(delta) }
    }

    /// Damaged data is reported, so the phone can ask for a refresh, and a keyframe recovers.
    @Test func brokenFramesAreReportedAndAKeyframeRecovers() throws {
        let encoder = try VideoTestEncoder(codec: .hevc, width: 320, height: 208, chroma444: false)
        let key = try encoder.encode(keyframe: true, draw: VideoScene.drawing(width: 320, height: 208, step: 0))
        let decoder = VideoDecoder()
        _ = try decoder.decode(key)
        var broken = key
        broken.parameterSets = []
        broken.data = Data([0, 0, 0, 6, 0x26, 0x01, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: VideoDecoder.Failure.self) { try decoder.decode(broken) }
        var badSets = key
        badSets.parameterSets = [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])]
        #expect(throws: VideoDecoder.Failure.self) { try VideoDecoder().decode(badSets) }
        let again = try encoder.encode(keyframe: true, draw: VideoScene.drawing(width: 320, height: 208, step: 2))
        #expect(try decoder.decode(again).width == 320)
    }

    /// The frame the phone checks at launch decodes on this Mac's hardware, stripes and all.
    @Test func theEmbedded444FrameDecodes() throws {
        #expect(VideoDecoder.supports444)
        let frame = VideoFrameMessage(displayID: 0, width: VideoDecoderTestFrame.width, height: VideoDecoderTestFrame.height,
                                      sequence: 0, captureTime: 0, codec: .hevc, flags: [.keyframe, .refresh, .chroma444],
                                      parameterSets: VideoDecoderTestFrame.parameterSets.map { Data($0) },
                                      data: Data(VideoDecoderTestFrame.frame))
        let decoder = VideoDecoder(allowsSoftware: false)
        let picture = try decoder.decode(try #require(VideoFrameMessage.parse(frame.encoded())))
        #expect(decoder.usingHardware)
        #expect(picture.width == VideoDecoderTestFrame.width && picture.height == VideoDecoderTestFrame.height)
        #expect(picture.pixelBuffer.withUnsafeBuffer { VideoDecoder.showsTestFrame($0) })
    }
}

/// What the test encoder draws: a grey screen with a red and a blue window that move a little each step, and a strip
/// of one-pixel red and blue stripes along the bottom.
enum VideoScene {
    typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    static let grey: RGB = (128, 128, 128)
    static let red: RGB = (220, 40, 40)
    static let blue: RGB = (40, 60, 220)

    /// The picture at a step, pixel by pixel, for `VideoTestEncoder.encode`.
    static func drawing(width: Int, height: Int, step: Int) -> (Int, Int) -> RGB {
        { x, y in color(x: x, y: y, width: width, height: height, step: step) }
    }

    static func color(x: Int, y: Int, width: Int, height: Int, step: Int) -> RGB {
        if y >= height - height / 8 { return x.isMultiple(of: 2) ? red : blue }
        if redWindow(width: width, height: height, step: step).contains(CGPoint(x: x, y: y)) { return red }
        if blueWindow(width: width, height: height, step: step).contains(CGPoint(x: x, y: y)) { return blue }
        return grey
    }

    static func probes(width: Int, height: Int, step: Int) -> [(x: Int, y: Int, color: RGB)] {
        let redCenter = redWindow(width: width, height: height, step: step)
        let blueCenter = blueWindow(width: width, height: height, step: step)
        return [(Int(redCenter.midX), Int(redCenter.midY), red), (Int(blueCenter.midX), Int(blueCenter.midY), blue),
                (width / 2, height / 20, grey)]
    }

    private static func redWindow(width: Int, height: Int, step: Int) -> CGRect {
        CGRect(x: width / 10 + step * width / 40, y: height / 5, width: width * 3 / 10, height: height * 2 / 5)
    }

    private static func blueWindow(width: Int, height: Int, step: Int) -> CGRect {
        CGRect(x: width * 6 / 10 - step * width / 40, y: height * 3 / 10, width: width / 4, height: height * 2 / 5)
    }
}

enum VideoPixels {
    struct Unreadable: Error {}

    /// A pixel of a BGRA buffer.
    static func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> VideoScene.RGB {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Unreadable() }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), x < CVPixelBufferGetWidth(buffer), y < CVPixelBufferGetHeight(buffer)
        else { throw Unreadable() }
        let pixel = (base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        return (pixel[2], pixel[1], pixel[0])
    }

    static func near(_ a: VideoScene.RGB, _ b: VideoScene.RGB, within tolerance: Int) -> Bool {
        abs(Int(a.red) - Int(b.red)) <= tolerance && abs(Int(a.green) - Int(b.green)) <= tolerance
            && abs(Int(a.blue) - Int(b.blue)) <= tolerance
    }
}

/// A low-latency hardware encoder set up as the hub sets one up (no frame reordering, real time), turning drawn
/// pictures into wire messages: 4:2:0 from '420v' input, or 4:4:4 (the encoder's Main 4:4:4 profile) from '444v'.
final class VideoTestEncoder {
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    let codec: VideoFrameMessage.Codec
    let chroma444: Bool
    let width: Int
    let height: Int
    private let session: VTCompressionSession
    private let transfer: VTPixelTransferSession
    private var sequence: UInt32 = 0

    init(codec: VideoFrameMessage.Codec, width: Int, height: Int, chroma444: Bool) throws {
        self.codec = codec
        self.chroma444 = chroma444
        self.width = width
        self.height = height
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var made: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                  encoderSpecification: specification, imageBufferAttributes: nil,
                                                  compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                  compressionSessionOut: &made), "making the encoder")
        guard let made else { throw Failed(description: "no encoder") }
        session = made
        var converter: VTPixelTransferSession?
        try Self.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &converter), "making the converter")
        guard let converter else { throw Failed(description: "no converter") }
        transfer = converter
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_AverageBitRate: 8_000_000 as CFNumber,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60 as CFNumber,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties { try Self.check(VTSessionSetProperty(session, key: key, value: value), "setting \(key)") }
        if chroma444 {
            try Self.check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                                value: try Self.main444Profile(width: width, height: height)), "the 4:4:4 profile")
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Encodes one picture, drawn a pixel at a time, into the message the hub would send for it.
    func encode(keyframe: Bool, draw: (Int, Int) -> VideoScene.RGB) throws -> VideoFrameMessage {
        let picture = try pixelBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(picture, [])
        if let base = CVPixelBufferGetBaseAddress(picture) {
            let row = CVPixelBufferGetBytesPerRow(picture)
            for y in 0..<height {
                let line = (base + y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let color = draw(x, y)
                    line[x * 4] = color.blue
                    line[x * 4 + 1] = color.green
                    line[x * 4 + 2] = color.red
                    line[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])
        let input = try pixelBuffer(chroma444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
                                              : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        try Self.check(VTPixelTransferSessionTransferImage(transfer, from: picture, to: input), "converting")

        sequence += 1
        let output = Output()
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        try Self.check(VTCompressionSessionEncodeFrame(session, imageBuffer: input,
                                                       presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 60),
                                                       duration: CMTime(value: 1, timescale: 60), frameProperties: options,
                                                       infoFlagsOut: nil) { status, _, sample in
            output.set(status == noErr ? sample : nil)
        }, "encoding")
        try Self.check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "finishing")
        guard let sample = output.sample, let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample)
        else { throw Failed(description: "the encoder gave nothing back") }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        try data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { throw Failed(description: "an empty frame") }
            try Self.check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: address), "copying")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var flags: VideoFrameMessage.Flags = isKeyframe ? [.keyframe, .refresh] : []
        if chroma444 { flags.insert(.chroma444) }
        return VideoFrameMessage(displayID: 1, width: width, height: height, sequence: sequence,
                                 captureTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds, codec: codec, flags: flags,
                                 parameterSets: isKeyframe ? try parameterSets(format) : [], data: data)
    }

    private func parameterSets(_ format: CMFormatDescription) throws -> [Data] {
        var sets: [Data] = []
        var count = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var length: Int32 = 0
            let index = sets.count
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                     nalUnitHeaderLengthOut: &length)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                     nalUnitHeaderLengthOut: &length)
            try Self.check(status, "reading parameter set \(sets.count)")
            guard let pointer, length == 4 else { throw Failed(description: "unexpected parameter set") }
            sets.append(Data(bytes: pointer, count: size))
        } while sets.count < count
        return sets
    }

    private func pixelBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        try Self.check(CVPixelBufferCreate(nil, width, height, format, attributes, &buffer), "making a pixel buffer")
        guard let buffer else { throw Failed(description: "no pixel buffer") }
        for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        return buffer
    }

    /// The encoder's own name for HEVC Main 4:4:4 (8-bit) in low-latency mode.
    private static func main444Profile(width: Int, height: Int) throws -> CFString {
        var supported: CFDictionary?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        try check(VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
                                                              codecType: kCMVideoCodecType_HEVC, encoderSpecification: lowLatency,
                                                              encoderIDOut: nil, supportedPropertiesOut: &supported), "asking the encoder")
        let profileLevel = (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
        let profiles = profileLevel?[kVTPropertySupportedValueListKey as String] as? [String]
        guard let profile = profiles?.first(where: { $0.contains("Main444") && !$0.contains("10") }) else {
            throw Failed(description: "no Main 4:4:4 profile in \(profiles ?? [])")
        }
        return profile as CFString
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw Failed(description: "\(what): \(status)") }
    }

    /// The encoder's output; complete-frames waits for it.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CMSampleBuffer?

        func set(_ sample: CMSampleBuffer?) { lock.withLock { stored = sample } }
        var sample: CMSampleBuffer? { lock.withLock { stored } }
    }
}
