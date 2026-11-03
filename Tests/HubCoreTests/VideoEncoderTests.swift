import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

/// The hub's video encoder on this Mac's hardware: what the phone gets (keyframes with their parameter sets, frame
/// tokens to acknowledge, refreshes) and proof that it decodes to the same picture. Made-up frames only; nothing is
/// captured from the screen.
@Suite("Video encoder", .serialized)
struct VideoEncoderTests {
    static let width = 640
    static let height = 416
    static let format420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Each stream the hub can make: the codec, 4:4:4 or not, and (for 4:4:4) which profiles may be tried.
    struct Kind: CustomTestStringConvertible, Sendable {
        let name: String
        let codec: VideoFrameMessage.Codec
        let chroma444: Bool
        let profiles: [String]

        var testDescription: String { name }

        static let all = [
            Kind(name: "HEVC 4:2:0", codec: .hevc, chroma444: false, profiles: []),
            Kind(name: "H.264", codec: .h264, chroma444: false, profiles: []),
            Kind(name: "HEVC 4:4:4 10-bit", codec: .hevc, chroma444: true, profiles: ["HEVC_Main44410_AutoLevel"]),
            Kind(name: "HEVC 4:4:4 8-bit", codec: .hevc, chroma444: true, profiles: ["HEVC_Main444_AutoLevel"]),
        ]

        func encoder(bitrate: Int = 6_000_000, into collector: Collector) throws -> VideoEncoder {
            let settings = VideoEncoder.Settings(codec: codec, width: VideoEncoderTests.width, height: VideoEncoderTests.height,
                                                 fps: 60, bitrate: bitrate, chroma444: chroma444, displayID: 7)
            let candidates = VideoEncoder.chroma444Profiles.filter { profiles.contains($0.profile) }
            return try VideoEncoder(settings: settings, sequence: 0, chroma444Profiles: candidates, output: { collector.add($0) })
        }
    }

    // MARK: The stream

    @Test(arguments: [VideoFrameMessage.Codec.hevc, .h264])
    func theFirstFrameStartsTheStream(codec: VideoFrameMessage.Codec) throws {
        let collector = Collector()
        let encoder = try VideoEncoder(settings: .init(codec: codec, width: Self.width, height: Self.height, fps: 60,
                                                       bitrate: 4_000_000, displayID: 7), output: { collector.add($0) })
        #expect(encoder.pixelFormat == Self.format420)
        #expect(encoder.longTermReferences, "long-term references are what refreshes stand on")
        let canvas = Canvas(format: encoder.pixelFormat)
        for index in 0..<10 {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60),
                           captureTime: 1000.25 + Double(index))
        }
        encoder.flush()
        let frames = collector.frames
        try #require(frames.count == 10, "no frame was dropped")
        let first = frames[0]
        #expect(first.flags.isSuperset(of: [.keyframe, .refresh]))
        #expect(!first.flags.contains(.chroma444))
        let nalTypes = first.parameterSets.map { codec == .hevc ? Int($0[$0.startIndex] >> 1) & 0x3F : Int($0[$0.startIndex]) & 0x1F }
        #expect(nalTypes == (codec == .hevc ? [32, 33, 34] : [7, 8]), "HEVC: VPS, SPS, PPS; H.264: SPS, PPS")
        #expect(first.displayID == 7 && first.width == Self.width && first.height == Self.height && first.codec == codec)
        #expect(frames.map(\.sequence) == Array(1...10), "every frame numbered, in order")
        #expect(frames.map(\.captureTime) == (0..<10).map { 1000.25 + Double($0) })
        #expect(first.ltrToken != 0, "the keyframe carries a token to acknowledge")
        let tokens = frames.map(\.ltrToken).filter { $0 != 0 }
        #expect(Set(tokens).count == tokens.count, "tokens are never reused")
        for frame in frames.dropFirst() {
            #expect(frame.flags.isEmpty && frame.parameterSets.isEmpty, "a delta frame is just the frame")
        }
        #expect(VideoFrameMessage.parse(first.encoded()) == first, "survives the wire")
        print("hub-video: \(codec) 640×416 keyframe \(first.data.count) B, delta frames \(frames.dropFirst().map(\.data.count)) B")
    }

    /// H.264 marks every frame for acknowledgement; HEVC keeps one unacknowledged at a time, so new tokens come as fast
    /// as the phone returns them.
    @Test(arguments: [VideoFrameMessage.Codec.hevc, .h264])
    func acknowledgedTokensKeepNewOnesComing(codec: VideoFrameMessage.Codec) throws {
        let collector = Collector()
        let encoder = try VideoEncoder(settings: .init(codec: codec, width: Self.width, height: Self.height, fps: 60,
                                                       bitrate: 4_000_000), output: { collector.add($0) })
        let canvas = Canvas(format: encoder.pixelFormat)
        var pattern = ""
        for index in 0..<12 {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
            encoder.flush()
            let frame = try #require(collector.take().last)
            pattern += frame.ltrToken == 0 ? "-" : "T"
            if frame.ltrToken != 0 { encoder.acknowledge([frame.ltrToken]) }
        }
        #expect(pattern.filter { $0 == "T" }.count >= 6, "tokens with prompt acknowledgements: \(pattern)")
        print("hub-video: \(codec) tokens with each acknowledged at once: \(pattern)")
    }

    @Test(arguments: Kind.all)
    func framesDecodeToTheSamePicture(kind: Kind) throws {
        let collector = Collector()
        let encoder = try kind.encoder(bitrate: 8_000_000, into: collector)
        guard !kind.chroma444 || encoder.chroma444 else {
            // This Mac's HEVC encoder has no such 4:4:4 profile; the 4:2:0 cases cover it.
            #expect(encoder.pixelFormat == Self.format420)
            return
        }
        let canvas = Canvas(format: encoder.pixelFormat)
        // 4:4:4 frames tagged BT.601 as the hub tags ScreenCaptureKit's; 4:2:0 ones untagged (the stream says BT.709).
        let matrix = kind.chroma444 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        let count = 12
        for index in 0..<count {
            let pixels = canvas.frame(index)
            if kind.chroma444 { CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
            encoder.encode(pixels, time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
        }
        encoder.flush()
        let frames = collector.frames
        try #require(frames.count == count)
        #expect(frames.allSatisfy { $0.flags.contains(.chroma444) == kind.chroma444 }, "the flag says what the bitstream carries")
        let decoder = try TestDecoder(start: frames[0], pixelFormat: encoder.pixelFormat)
        var last: CVPixelBuffer?
        for frame in frames {
            let decoded = decoder.decode(frame)
            #expect(decoded.status == noErr, "frame \(frame.sequence)")
            last = decoded.image ?? last
        }
        let picture = try #require(last)
        #expect(CVPixelBufferGetPixelFormatType(picture) == encoder.pixelFormat)
        #expect(CVBufferCopyAttachment(picture, kCVImageBufferYCbCrMatrixKey, nil) as? String == matrix as String,
                "the phone's decoder learns the matrix from the stream")
        #expect(CVBufferCopyAttachment(picture, kCVImageBufferColorPrimariesKey, nil) as? String
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        let patch = canvas.patch(count - 1)
        let seen = canvas.read(picture, x: patch.midX, y: patch.midY)
        #expect(seen.near(Canvas.patchColor), "the coloured square: \(seen)")
        #expect(canvas.read(picture, x: 20, y: 380).near(Canvas.background), "the grey around it")
        if kind.chroma444 {
            // One-pixel columns of alternating colour: 4:2:0 would average each pair into grey.
            let stripes = Canvas.stripes
            var swing = 0.0
            for x in stripes.minX..<(stripes.maxX - 1) {
                swing += abs(canvas.read(picture, x: x, y: stripes.midY).cr - canvas.read(picture, x: x + 1, y: stripes.midY).cr)
            }
            swing /= Double(stripes.width - 1)
            #expect(swing > 0.3, "full-resolution colour survives: mean swing \(swing) of 0.6")
        }
        print("hub-video: \(kind.name) (\(encoder.profile)) keyframe \(frames[0].data.count) B, delta median \(frames.dropFirst().map(\.data.count).sorted()[count / 2]) B")
    }

    // MARK: Losing frames and picking up again

    /// The phone decodes frames and acknowledges them a few frames late (its round trip), then misses some (the hub
    /// skipped them on a slow link). The refresh that follows is a small frame that refers only to an acknowledged one,
    /// and it decodes on the phone's decoder as it stands, gap and all.
    @Test(arguments: Kind.all)
    func aRefreshAfterAGapNeedsNoKeyframe(kind: Kind) throws {
        let collector = Collector()
        let encoder = try kind.encoder(into: collector)
        let canvas = Canvas(format: encoder.pixelFormat)
        var decoder: TestDecoder?
        var unacknowledged: [UInt32] = []
        var index = 0
        func next() -> VideoFrameMessage? {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
            encoder.flush()
            index += 1
            return collector.take().last
        }
        // Received and decoded; each acknowledgement lands three frames later.
        for _ in 0..<10 {
            let frame = try #require(next())
            if decoder == nil { decoder = try TestDecoder(start: frame, pixelFormat: encoder.pixelFormat) }
            #expect(decoder?.decode(frame).status == noErr)
            unacknowledged.append(frame.ltrToken)
            if unacknowledged.count > 3 { encoder.acknowledge([unacknowledged.removeFirst()]) }
        }
        // The gap: skipped by the hub, while the last acknowledgements still arrive.
        for _ in 0..<5 {
            _ = try #require(next())
            if !unacknowledged.isEmpty { encoder.acknowledge([unacknowledged.removeFirst()]) }
        }
        encoder.requestRefresh()
        #expect(encoder.wantsFrame)
        let refresh = try #require(next())
        #expect(!encoder.wantsFrame)
        #expect(refresh.flags.contains(.refresh) && !refresh.flags.contains(.keyframe), "a refresh, not a keyframe: \(refresh.flags)")
        #expect(!refresh.parameterSets.isEmpty, "a refresh carries the parameter sets")
        let decoded = try #require(decoder).decode(refresh)
        #expect(decoded.status == noErr)
        let picture = try #require(decoded.image)
        let patch = canvas.patch(index - 1)
        #expect(canvas.read(picture, x: patch.midX, y: patch.midY).near(Canvas.patchColor), "the picture is current again")
        for _ in 0..<3 {
            let frame = try #require(next())
            #expect(frame.flags.isDisjoint(with: [.keyframe, .refresh]))
            #expect(decoder?.decode(frame).status == noErr, "and the frames after it decode too")
        }
        print("hub-video: \(kind.name) refresh after a gap \(refresh.data.count) B (keyframe \(collector.allSizes.first ?? 0) B)")
    }

    /// An acknowledgement that arrives very late (the phone was slow) still gives a refresh the phone can decode: a
    /// small one if the encoder still holds that frame, a keyframe if not.
    @Test(arguments: [0, 1])
    func aLateAcknowledgementStillGivesADecodableRefresh(kindIndex: Int) throws {
        let collector = Collector()
        let encoder = try Kind.all[kindIndex].encoder(into: collector)
        let canvas = Canvas(format: encoder.pixelFormat)
        for index in 0..<40 {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
        }
        encoder.flush()
        let frames = collector.take()
        try #require(frames.count == 40)
        let decoder = try TestDecoder(start: frames[0], pixelFormat: encoder.pixelFormat)
        #expect(decoder.decode(frames[0]).status == noErr)
        #expect(decoder.decode(frames[1]).status == noErr)
        try #require(frames[0].ltrToken != 0)
        encoder.acknowledge([frames[0].ltrToken])
        encoder.requestRefresh()
        encoder.encode(canvas.frame(40), time: CMTime(value: 41, timescale: 60), captureTime: 0)
        encoder.flush()
        let refresh = try #require(collector.take().last)
        #expect(refresh.flags.contains(.refresh))
        let decoded = decoder.decode(refresh)
        #expect(decoded.status == noErr && decoded.image != nil)
        print("hub-video: \(Kind.all[kindIndex].name) refresh 40 frames after the acknowledged one: \(refresh.flags.contains(.keyframe) ? "keyframe" : "refers to it"), \(refresh.data.count) B")
    }

    @Test func aRefreshWithNothingAcknowledgedIsAKeyframe() throws {
        let collector = Collector()
        let encoder = try Kind.all[0].encoder(into: collector)
        let canvas = Canvas(format: encoder.pixelFormat)
        for index in 0..<3 {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
        }
        encoder.requestRefresh()
        encoder.encode(canvas.frame(3), time: CMTime(value: 4, timescale: 60), captureTime: 0)
        encoder.flush()
        let frames = collector.frames
        try #require(frames.count == 4)
        #expect(frames[3].flags.isSuperset(of: [.keyframe, .refresh]))
        #expect(!frames[3].parameterSets.isEmpty)
    }

    @Test func aKeyframeOnRequestEvenWithAcknowledgedFrames() throws {
        let collector = Collector()
        let encoder = try Kind.all[1].encoder(into: collector)
        let canvas = Canvas(format: encoder.pixelFormat)
        for index in 0..<4 {
            encoder.encode(canvas.frame(index), time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: 0)
            encoder.flush()
            if let token = collector.frames.last?.ltrToken { encoder.acknowledge([token]) }
        }
        encoder.requestKeyframe()
        encoder.encode(canvas.frame(4), time: CMTime(value: 5, timescale: 60), captureTime: 0)
        encoder.flush()
        let keyframe = try #require(collector.frames.last)
        #expect(keyframe.flags.isSuperset(of: [.keyframe, .refresh]))
        #expect(keyframe.sequence == 5)
        // Tokens from before a keyframe mean nothing after it.
        encoder.acknowledge([collector.frames[2].ltrToken])
        encoder.requestRefresh()
        encoder.encode(canvas.frame(5), time: CMTime(value: 6, timescale: 60), captureTime: 0)
        encoder.flush()
        #expect(collector.frames.last?.flags.contains(.keyframe) == true, "nothing acknowledged since the keyframe")
    }

    @Test func h264Is420OnlyAndNumbersCarryOn() throws {
        let collector = Collector()
        let settings = VideoEncoder.Settings(codec: .h264, width: Self.width, height: Self.height, fps: 30, bitrate: 2_000_000,
                                             chroma444: true)
        let encoder = try VideoEncoder(settings: settings, sequence: 41, output: { collector.add($0) })
        #expect(!encoder.chroma444 && encoder.pixelFormat == Self.format420)
        encoder.currentBitrate = 1_000_000
        #expect(encoder.currentBitrate == 1_000_000)
        encoder.encode(Canvas(format: encoder.pixelFormat).frame(0), time: CMTime(value: 1, timescale: 30), captureTime: 0)
        encoder.flush()
        #expect(collector.frames.first?.sequence == 42, "a new encoder for the same stream keeps counting")
        #expect(encoder.lastSequence == 42)
    }
}

// MARK: Test helpers

/// Collects what an encoder puts out.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [VideoEncoder.Output] = []
    private var taken = 0

    func add(_ output: VideoEncoder.Output) {
        lock.withLock { outputs.append(output) }
    }

    var frames: [VideoFrameMessage] {
        lock.withLock { outputs.compactMap { if case .frame(let frame) = $0 { frame } else { nil } } }
    }

    var allSizes: [Int] { frames.map(\.data.count) }

    /// The frames that came out since the last call.
    func take() -> [VideoFrameMessage] {
        let all = frames
        defer { taken = all.count }
        return Array(all.dropFirst(taken))
    }
}

/// A colour as Y' (0...1) and Cb, Cr (-0.5...0.5).
struct YCC: CustomStringConvertible {
    var y: Double
    var cb: Double
    var cr: Double

    func near(_ other: YCC, within tolerance: Double = 0.04) -> Bool {
        abs(y - other.y) <= tolerance && abs(cb - other.cb) <= tolerance && abs(cr - other.cr) <= tolerance
    }

    var description: String { String(format: "Y %.3f Cb %.3f Cr %.3f", y, cb, cr) }
}

/// Made-up frames in the encoder's pixel format: grey, a coloured square that moves 8 pixels a frame and, where chroma
/// is at full resolution, one-pixel columns of alternating colour.
struct Canvas {
    static let background = YCC(y: 0.5, cb: 0, cr: 0)
    static let patchColor = YCC(y: 0.35, cb: -0.2, cr: 0.3)
    static let stripes = (minX: 400, maxX: 464, minY: 300, maxY: 332, midY: 316, width: 64)

    let format: OSType

    private var wide: Bool { format == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange }
    private var subsampled: Bool { format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }

    func patch(_ index: Int) -> (minX: Int, minY: Int, midX: Int, midY: Int, size: Int) {
        let x = 32 + (index * 8) % 320
        return (x, 64, x + 32, 96, 64)
    }

    func frame(_ index: Int) -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, VideoEncoderTests.width, VideoEncoderTests.height, format, attributes as CFDictionary, &made)
        let pixels = made!
        fill(pixels, x: 0, y: 0, width: VideoEncoderTests.width, height: VideoEncoderTests.height, Self.background)
        texture(pixels)
        let patch = patch(index)
        fill(pixels, x: patch.minX, y: patch.minY, width: patch.size, height: patch.size, Self.patchColor)
        if !subsampled {
            for x in Self.stripes.minX..<Self.stripes.maxX {
                let cr = x % 2 == 0 ? 0.3 : -0.3
                fill(pixels, x: x, y: Self.stripes.minY, width: 1, height: Self.stripes.maxY - Self.stripes.minY,
                     YCC(y: 0.5, cb: 0, cr: cr))
            }
        }
        return pixels
    }

    /// Text-like detail (light and dark 2×2 blocks) in rows 160 to 288, so frames cost what a screen's do.
    private func texture(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        for y in 160..<288 {
            for x in 0..<VideoEncoderTests.width {
                var hash = UInt32(truncatingIfNeeded: (x / 2) &* 73_856_093 ^ (y / 2) &* 19_349_663)
                hash ^= hash >> 13
                hash = hash &* 0x5BD1_E995
                write(pixels, plane: 0, x: x, y: y, component: 0, of: 1, code(hash & 0x100 == 0 ? 0.15 : 0.9, chroma: false))
            }
        }
    }

    /// The colour at a point of a picture in this canvas's format.
    func read(_ pixels: CVPixelBuffer, x: Int, y: Int) -> YCC {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let (cx, cy) = subsampled ? (x / 2, y / 2) : (x, y)
        return YCC(y: value(sample(pixels, plane: 0, x: x, y: y, component: 0, of: 1), chroma: false),
                   cb: value(sample(pixels, plane: 1, x: cx, y: cy, component: 0, of: 2), chroma: true),
                   cr: value(sample(pixels, plane: 1, x: cx, y: cy, component: 1, of: 2), chroma: true))
    }

    private func fill(_ pixels: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int, _ color: YCC) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        for row in y..<(y + height) {
            for column in x..<(x + width) { write(pixels, plane: 0, x: column, y: row, component: 0, of: 1, code(color.y, chroma: false)) }
        }
        let (cx, cy, cw, ch) = subsampled ? (x / 2, y / 2, max(1, width / 2), max(1, height / 2)) : (x, y, width, height)
        for row in cy..<(cy + ch) {
            for column in cx..<(cx + cw) {
                write(pixels, plane: 1, x: column, y: row, component: 0, of: 2, code(color.cb, chroma: true))
                write(pixels, plane: 1, x: column, y: row, component: 1, of: 2, code(color.cr, chroma: true))
            }
        }
    }

    /// 8-bit video range, or (xf44) 10-bit full range.
    private func code(_ value: Double, chroma: Bool) -> Int {
        if wide { return Int(((chroma ? 512 + 1023 * value : 1023 * value)).rounded()).clamped(0, 1023) }
        return Int((chroma ? 128 + 224 * value : 16 + 219 * value).rounded()).clamped(0, 255)
    }

    private func value(_ code: Int, chroma: Bool) -> Double {
        if wide { return chroma ? (Double(code) - 512) / 1023 : Double(code) / 1023 }
        return chroma ? (Double(code) - 128) / 224 : (Double(code) - 16) / 219
    }

    private func write(_ pixels: CVPixelBuffer, plane: Int, x: Int, y: Int, component: Int, of components: Int, _ code: Int) {
        let row = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixels, plane))
        if wide {
            row.assumingMemoryBound(to: UInt16.self)[x * components + component] = UInt16(code << 6)
        } else {
            row.assumingMemoryBound(to: UInt8.self)[x * components + component] = UInt8(code)
        }
    }

    private func sample(_ pixels: CVPixelBuffer, plane: Int, x: Int, y: Int, component: Int, of components: Int) -> Int {
        let row = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixels, plane))
        if wide { return Int(row.assumingMemoryBound(to: UInt16.self)[x * components + component] >> 6) }
        return Int(row.assumingMemoryBound(to: UInt8.self)[x * components + component])
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

/// A minimal stand-in for the phone's decoder: a stream's parameter sets in, pictures out in a chosen pixel format.
final class TestDecoder {
    private let session: VTDecompressionSession
    private let description: CMFormatDescription

    /// Starts from a keyframe's parameter sets.
    init(start: VideoFrameMessage, pixelFormat: OSType) throws {
        let sets = start.parameterSets.map { [UInt8]($0) }
        try #require(!sets.isEmpty, "a keyframe carries its parameter sets")
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var made: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerList in
            sizes.withUnsafeBufferPointer { sizeList in
                start.codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                          parameterSetPointers: pointerList.baseAddress!,
                                                                          parameterSetSizes: sizeList.baseAddress!,
                                                                          nalUnitHeaderLength: 4, extensions: nil,
                                                                          formatDescriptionOut: &made)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                          parameterSetPointers: pointerList.baseAddress!,
                                                                          parameterSetSizes: sizeList.baseAddress!,
                                                                          nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        try #require(status == noErr)
        description = try #require(made)
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var decoder: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                                   imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                   decompressionSessionOut: &decoder)
        try #require(created == noErr)
        session = try #require(decoder)
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    final class Result: @unchecked Sendable {
        var status: OSStatus = noErr
        var image: CVPixelBuffer?
    }

    func decode(_ frame: VideoFrameMessage) -> (status: OSStatus, image: CVPixelBuffer?) {
        var block: CMBlockBuffer?
        let length = frame.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              frame.data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                         offsetIntoDestination: 0, dataLength: length) }) == noErr
        else { return (-1, nil) }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return (-1, nil) }
        let result = Result()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            result.status = status
            result.image = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return (status != noErr ? status : result.status, result.image)
    }
}
