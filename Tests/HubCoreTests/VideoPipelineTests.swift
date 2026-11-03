import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

/// Step 1's two halves meeting, as they do over the wire: the hub's encoder (`VideoEncoder`) feeds the phone's decoder
/// (`VideoDecoder`) through the wire format (`encoded()`, `parse`), the phone's `VideoSequenceTracker` decides what it
/// may decode, and each decoded frame's token goes straight back to the encoder, as the phone's feedback carries it.
/// The frames are drawn in RGB and made Y'CbCr the way ScreenCaptureKit makes them for the hub: BT.709 for 4:2:0, and
/// BT.601 for 4:4:4 (which the hub tags so). The colours only come back right if that matrix reaches the phone.
@Suite("Video from the hub to the phone", .serialized)
struct VideoPipelineTests {
    enum Stream: String, CaseIterable, CustomTestStringConvertible {
        case hevc, hevc444, h264

        var codec: VideoFrameMessage.Codec { self == .h264 ? .h264 : .hevc }
        var chroma444: Bool { self == .hevc444 }
        var testDescription: String { rawValue }
    }

    /// A Mac-like size, and large enough that a decoder missing the stream's matrix would take BT.709 rather than 601.
    static let width = 1280
    static let height = 800
    /// How far a colour may come back from what was drawn, in 8-bit codes. The wrong matrix is 25 to 35 off on the
    /// green square (see `theMatricesTellApart`).
    static let tolerance = 10

    /// A keyframe and frames that change a little: each arrives in order, decodes on the phone, and looks as drawn.
    @Test(arguments: Stream.allCases)
    func framesArriveAsTheMacDrewThem(_ stream: Stream) throws {
        let collector = Collector()
        guard let encoder = try Self.encoder(stream, into: collector) else { return }
        let screen = Screen(matrix: encoder.chroma444 ? .bt601 : .bt709, format: encoder.pixelFormat)
        let phone = Phone()
        var sent: [VideoFrameMessage] = []
        var picture: VideoDecoder.Picture?
        for index in 0..<6 {
            let frame = try Self.send(screen.frame(index), index, encoder, collector)
            sent.append(frame)
            picture = try #require(try phone.receive(frame, acknowledgingTo: encoder), "frame \(frame.sequence) decodes")
        }

        // The keyframe starts the stream with its parameter sets; the rest are bare frames, numbered in order.
        let keyframe = sent[0]
        #expect(keyframe.flags.isSuperset(of: [.keyframe, .refresh]))
        #expect(Self.nalTypes(keyframe) == (stream.codec == .hevc ? [32, 33, 34] : [7, 8]), "HEVC: VPS, SPS, PPS; H.264: SPS, PPS")
        for frame in sent.dropFirst() {
            #expect(frame.flags.isDisjoint(with: [.keyframe, .refresh]) && frame.parameterSets.isEmpty)
        }
        #expect(sent.map(\.sequence) == Array(1...6))
        #expect(sent.allSatisfy { $0.flags.contains(.chroma444) == stream.chroma444 }, "the flag says what the bitstream is")
        #expect(sent.allSatisfy { $0.displayID == 3 && $0.width == Self.width && $0.height == Self.height && $0.codec == stream.codec })
        // Tokens: the keyframe has one, they're never reused, and acknowledged at once they keep coming.
        let tokens = sent.map(\.ltrToken).filter { $0 != 0 }
        #expect(keyframe.ltrToken != 0)
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.count >= sent.count / 2, "tokens: \(sent.map(\.ltrToken))")
        // The stream says which matrix made it, as CoreMedia reads its parameter sets (so the phone's decoder does too).
        #expect(try Self.declaredMatrix(keyframe) == screen.matrix.tag as String)
        if !stream.chroma444 { #expect(phone.decoder.usingHardware, "4:2:0 decodes on the hardware") }

        let shown = try #require(picture)
        #expect(shown.width == Self.width && shown.height == Self.height)
        try screen.expectColours(shown, index: 5, chroma444: stream.chroma444)
        print("video pipeline: \(stream) (\(encoder.profile), \(screen.matrix)) keyframe \(keyframe.data.count) B, deltas "
            + "\(sent.dropFirst().map(\.data.count)) B, phone decoder on \(phone.decoder.usingHardware ? "hardware" : "software")")
    }

    /// The hub skips a frame (the link was busy). The frame after the gap isn't decoded: the phone asks for a refresh,
    /// and the refresh the encoder makes refers only to a frame the phone acknowledged, so it's small and decodes on the
    /// phone's decoder as it stands, the frames after it too.
    @Test(arguments: Stream.allCases)
    func aSkippedFrameIsMadeGoodByARefresh(_ stream: Stream) throws {
        let collector = Collector()
        guard let encoder = try Self.encoder(stream, into: collector) else { return }
        let screen = Screen(matrix: encoder.chroma444 ? .bt601 : .bt709, format: encoder.pixelFormat)
        let phone = Phone()
        var keyframe: VideoFrameMessage?
        for index in 0..<6 {
            let frame = try Self.send(screen.frame(index), index, encoder, collector)
            keyframe = keyframe ?? frame
            _ = try #require(try phone.receive(frame, acknowledgingTo: encoder))
        }
        // Skipped by the hub: it never reaches the phone.
        _ = try Self.send(screen.frame(6), 6, encoder, collector)
        let afterGap = try Self.send(screen.frame(7), 7, encoder, collector)
        #expect(try phone.receive(afterGap, acknowledgingTo: encoder) == nil, "a frame after a gap isn't decoded")
        #expect(phone.tracker.needsRefresh, "the phone asks for a refresh")

        encoder.requestRefresh()
        let refresh = try Self.send(screen.frame(8), 8, encoder, collector)
        let full = try #require(keyframe)
        #expect(refresh.flags.contains(.refresh) && !refresh.flags.contains(.keyframe), "a refresh, not a keyframe: \(refresh.flags)")
        #expect(!refresh.parameterSets.isEmpty, "a refresh carries the parameter sets")
        #expect(refresh.data.count * 4 < full.data.count, "\(refresh.data.count) B against the keyframe's \(full.data.count) B")
        let picture = try #require(try phone.receive(refresh, acknowledgingTo: encoder), "the refresh decodes")
        #expect(!phone.tracker.needsRefresh)
        try screen.expectColours(picture, index: 8, chroma444: stream.chroma444)
        for index in 9..<11 {
            let frame = try Self.send(screen.frame(index), index, encoder, collector)
            #expect(try phone.receive(frame, acknowledgingTo: encoder) != nil, "frame \(frame.sequence) after the refresh")
        }
        print("video pipeline: \(stream) refresh after a skipped frame \(refresh.data.count) B (keyframe \(full.data.count) B)")
    }

    /// The colour checks above would catch a stream decoded with the other matrix.
    @Test func theMatricesTellApart() {
        let green = Screen.squares[0]
        for (made, read) in [(Matrix.bt601, Matrix.bt709), (.bt709, .bt601)] {
            let wrong = read.rgb(made.ycc(green))
            #expect(!VideoPixels.near(wrong, green, within: Self.tolerance * 2), "\(made) read as \(read): \(wrong)")
            #expect(VideoPixels.near(made.rgb(made.ycc(green)), green, within: 1))
        }
    }

    // MARK: The hub and the phone

    /// The encoder `ScreenStreamer` would make for this stream, at 12 Mbit/s; nil for 4:4:4 when this Mac's encoder
    /// has no 4:4:4 profile (it makes 4:2:0 then, which the other cases cover).
    static func encoder(_ stream: Stream, into collector: Collector) throws -> VideoEncoder? {
        let settings = VideoEncoder.Settings(codec: stream.codec, width: width, height: height, fps: 60, bitrate: 12_000_000,
                                             chroma444: stream.chroma444, displayID: 3)
        let encoder = try VideoEncoder(settings: settings, output: { collector.add($0) })
        return stream.chroma444 && !encoder.chroma444 ? nil : encoder
    }

    /// Encodes frame `index` and takes what the encoder made of it.
    static func send(_ pixels: CVPixelBuffer, _ index: Int, _ encoder: VideoEncoder, _ collector: Collector) throws
        -> VideoFrameMessage {
        encoder.encode(pixels, time: CMTime(value: CMTimeValue(index + 1), timescale: 60), captureTime: Double(index) / 60)
        encoder.flush()
        return try #require(collector.take().last, "the encoder made frame \(index)")
    }

    /// The phone's side, as its `VideoReceiver` does it: the tracker decides, the decoder decodes, and the frame's token
    /// goes back to the encoder at once (the phone sends feedback with every decoded frame).
    final class Phone {
        let decoder = VideoDecoder()
        var tracker = VideoSequenceTracker()

        /// The picture, or nil for a frame the tracker holds back.
        func receive(_ sent: VideoFrameMessage, acknowledgingTo encoder: VideoEncoder) throws -> VideoDecoder.Picture? {
            let frame = try #require(VideoFrameMessage.parse(sent.encoded()))
            #expect(frame == sent, "frame \(sent.sequence) crosses the wire unchanged")
            guard tracker.shouldDecode(sequence: frame.sequence, flags: frame.flags) else { return nil }
            let picture = try decoder.decode(frame)
            tracker.decoded(sequence: frame.sequence, flags: frame.flags)
            if frame.ltrToken != 0 { encoder.acknowledge([frame.ltrToken]) }
            return picture
        }
    }

    static func nalTypes(_ frame: VideoFrameMessage) -> [Int] {
        frame.parameterSets.map { set in
            let header = Int(set[set.startIndex])
            return frame.codec == .hevc ? header >> 1 & 0x3F : header & 0x1F
        }
    }

    /// The YCbCr matrix the stream's parameter sets declare, read as the phone's decoder reads them.
    static func declaredMatrix(_ keyframe: VideoFrameMessage) throws -> String? {
        let sets = keyframe.parameterSets.map { [UInt8]($0) }
        let pointers = sets.map { set -> UnsafePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return UnsafePointer(copy)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        var format: CMFormatDescription?
        let status = keyframe.codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        try #require(status == noErr, "parameter sets: \(status)")
        let description = try #require(format)
        return CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
    }

    // MARK: The made-up screen

    /// RGB to Y'CbCr and back, with one matrix's coefficients (no transfer function: both sides stay gamma-encoded).
    enum Matrix: CustomStringConvertible {
        case bt601, bt709

        var kr: Double { self == .bt601 ? 0.299 : 0.2126 }
        var kb: Double { self == .bt601 ? 0.114 : 0.0722 }
        var tag: CFString { self == .bt601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2 }
        var description: String { self == .bt601 ? "BT.601" : "BT.709" }

        /// Y' in 0...1, Cb and Cr in -0.5...0.5.
        func ycc(_ rgb: VideoScene.RGB) -> (y: Double, cb: Double, cr: Double) {
            let (r, g, b) = (Double(rgb.red) / 255, Double(rgb.green) / 255, Double(rgb.blue) / 255)
            let y = kr * r + (1 - kr - kb) * g + kb * b
            return (y, (b - y) / (2 * (1 - kb)), (r - y) / (2 * (1 - kr)))
        }

        /// What a decoder using this matrix shows.
        func rgb(_ value: (y: Double, cb: Double, cr: Double)) -> VideoScene.RGB {
            let r = value.y + 2 * (1 - kr) * value.cr
            let b = value.y + 2 * (1 - kb) * value.cb
            let g = (value.y - kr * r - kb * b) / (1 - kr - kb)
            func code(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
            return (code(r), code(g), code(b))
        }
    }

    /// A made-up Mac screen: a light window with dark, text-like detail, four coloured squares that move 8 points a
    /// frame, and one-pixel columns of red and blue (coloured text at its finest), in the encoder's pixel format.
    struct Screen {
        static let paper: VideoScene.RGB = (236, 236, 236)
        static let ink: VideoScene.RGB = (28, 28, 30)
        /// Green first: it's the one the two matrices disagree on most.
        static let squares: [VideoScene.RGB] = [(0, 220, 0), (230, 30, 30), (30, 60, 230), (240, 200, 20)]
        static let stripes = (minX: 900, maxX: 1028, minY: 120, maxY: 216)
        static let squareSize = 96

        let matrix: Matrix
        let format: OSType

        private static let palette: [VideoScene.RGB] = [paper, ink] + squares + [squares[1], squares[2]]

        static func square(_ n: Int, index: Int) -> (x: Int, y: Int) { (80 + n * 200 + index * 8 % 64, 120) }

        /// The parts that don't move (paper, text, stripes) as palette entries, worked out once: each frame starts as a
        /// copy, and its squares go on top.
        private static let still: [UInt8] = {
            let width = VideoPipelineTests.width, height = VideoPipelineTests.height
            var entries = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    if y >= stripes.minY, y < stripes.maxY, x >= stripes.minX, x < stripes.maxX {
                        entries[y * width + x] = x.isMultiple(of: 2) ? 6 : 7
                    } else if y >= 400, y < 560, x >= 80, x < 1200 {
                        // Text-like: dark 2×2 blocks, about a quarter of them.
                        var hash = UInt32(truncatingIfNeeded: (x / 2) &* 73_856_093 ^ (y / 2) &* 19_349_663)
                        hash ^= hash >> 13
                        hash = hash &* 0x5BD1_E995
                        if hash >> 7 & 3 == 0 { entries[y * width + x] = 1 }
                    }
                }
            }
            return entries
        }()

        /// Frame `index`, made Y'CbCr with `matrix` and tagged as the hub's frames are tagged.
        func frame(_ index: Int) throws -> CVPixelBuffer {
            let width = VideoPipelineTests.width, height = VideoPipelineTests.height
            let tenBit = format == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            let subsampled = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            try #require(tenBit || subsampled || format == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                         "a pixel format this test draws: \(format)")
            var entries = Self.still
            for n in Self.squares.indices {
                let at = Self.square(n, index: index)
                for y in at.y..<(at.y + Self.squareSize) {
                    for x in at.x..<(at.x + Self.squareSize) { entries[y * width + x] = UInt8(2 + n) }
                }
            }
            // The codes: 8-bit video range, or 10-bit full range ('xf44', the top 10 bits of 16).
            let colours = Self.palette.map { matrix.ycc($0) }
            func luma(_ y: Double) -> Int { Int((tenBit ? 1023 * y : 16 + 219 * y).rounded()) }
            func chroma(_ c: Double) -> Int { Int((tenBit ? 512 + 1023 * c : 128 + 224 * c).rounded()) }
            let lumaCodes = colours.map { luma($0.y) }

            var made: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            try #require(CVPixelBufferCreate(nil, width, height, format, attributes, &made) == kCVReturnSuccess)
            let pixels = try #require(made)
            CVPixelBufferLockBaseAddress(pixels, [])
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            let bases = try (0..<2).map { try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, $0)) }
            let strides = (0..<2).map { CVPixelBufferGetBytesPerRowOfPlane(pixels, $0) }
            // One row of codes at a time, written as the format stores them.
            func write(_ codes: [Int], plane: Int, row: Int) {
                let start = bases[plane].advanced(by: row * strides[plane])
                if tenBit {
                    let words = start.assumingMemoryBound(to: UInt16.self)
                    for (x, code) in codes.enumerated() { words[x] = UInt16(min(max(code, 0), 1023)) << 6 }
                } else {
                    let bytes = start.assumingMemoryBound(to: UInt8.self)
                    for (x, code) in codes.enumerated() { bytes[x] = UInt8(min(max(code, 0), 255)) }
                }
            }
            for y in 0..<height {
                write((0..<width).map { lumaCodes[Int(entries[y * width + $0])] }, plane: 0, row: y)
            }
            // Cb and Cr side by side, a pair per pixel, or (4:2:0) per 2×2 block, from the block's average colour.
            let step = subsampled ? 2 : 1
            for y in stride(from: 0, to: height, by: step) {
                var codes: [Int] = []
                codes.reserveCapacity(2 * width / step)
                for x in stride(from: 0, to: width, by: step) {
                    var cb = 0.0, cr = 0.0
                    for dy in 0..<step {
                        for dx in 0..<step {
                            let colour = colours[Int(entries[(y + dy) * width + x + dx])]
                            cb += colour.cb
                            cr += colour.cr
                        }
                    }
                    codes.append(chroma(cb / Double(step * step)))
                    codes.append(chroma(cr / Double(step * step)))
                }
                write(codes, plane: 1, row: y / step)
            }
            // ScreenCaptureKit tags its 4:2:0 frames BT.709; the hub tags its 4:4:4 ones BT.601 (`ScreenStreamer`).
            CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, matrix.tag, .shouldPropagate)
            CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                                  .shouldPropagate)
            return pixels
        }

        /// The squares, the paper and (in 4:4:4) the one-pixel stripes come back as drawn in frame `index`.
        func expectColours(_ picture: VideoDecoder.Picture, index: Int, chroma444: Bool) throws {
            try picture.pixelBuffer.withUnsafeBuffer { buffer in
                for n in Self.squares.indices {
                    let at = Self.square(n, index: index)
                    let got = try VideoPixels.rgb(buffer, x: at.x + Self.squareSize / 2, y: at.y + Self.squareSize / 2)
                    #expect(VideoPixels.near(got, Self.squares[n], within: VideoPipelineTests.tolerance),
                            "square \(n) (\(matrix)): drawn \(Self.squares[n]), shown \(got)")
                }
                let paper = try VideoPixels.rgb(buffer, x: 40, y: 40)
                #expect(VideoPixels.near(paper, Self.paper, within: VideoPipelineTests.tolerance), "paper: \(paper)")
                if chroma444 {
                    // One-pixel red and blue columns keep their colours: 4:2:0 would make both purple.
                    let y = (Self.stripes.minY + Self.stripes.maxY) / 2
                    let red = try VideoPixels.rgb(buffer, x: 960, y: y)
                    let blue = try VideoPixels.rgb(buffer, x: 961, y: y)
                    #expect(Int(red.red) - Int(red.blue) > 100 && Int(blue.blue) - Int(blue.red) > 100, "\(red) \(blue)")
                }
            }
        }
    }
}
