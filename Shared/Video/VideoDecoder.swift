import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The hub's HEVC and H.264 frames (`VideoFrameMessage`) in, BGRA pictures out, on the hardware decoder. Decoding is
/// synchronous, about a millisecond a frame: `decode(_:)` returns the picture or throws, and after a throw the frames
/// that follow can't be trusted until a refresh frame. Not thread-safe: the one loop that receives a stream owns its
/// decoder. Both apps compile this file, so the Mac's tests run it.
nonisolated public final class VideoDecoder {
    /// A decoded frame: 32-bit BGRA, IOSurface-backed and Metal-compatible. Nothing writes to it once decoded, so it
    /// can go to another thread.
    public struct Picture: Sendable {
        public let pixelBuffer: CVReadOnlyPixelBuffer
        public let width: Int
        public let height: Int
        /// How long the decoder took, in milliseconds.
        public let decodeMs: Double
        /// When the Mac captured it: seconds on the Mac's host clock (`VideoFrameMessage.captureTime`), for the delay
        /// to the screen and the sync rule.
        public var captureTime: Double = 0
        /// The part of the display the frame shows (`VideoFrameMessage.region`); nil: all of it.
        public var region: ScreenRegion? = nil
    }

    /// Why a frame gave no picture.
    public enum Failure: Error, Equatable, Sendable {
        /// A frame came before any parameter sets: a stream starts at a keyframe or a refresh frame.
        case noParameterSets
        /// The parameter sets don't describe a picture.
        case parameterSets(OSStatus)
        /// No decoder takes this stream (the hardware's, nor a software one where allowed).
        case session(OSStatus)
        /// The frame couldn't be handed to the decoder.
        case sample(OSStatus)
        /// The decoder failed on the frame.
        case decode(OSStatus)
        /// The decoder took the frame without giving a picture back.
        case noPicture
    }

    /// Whether a software decoder may stand in when the hardware has none for a stream.
    public let allowsSoftware: Bool
    /// Whether frames go through the hardware decoder, rather than the software one standing in (false until the
    /// first frame starts a session).
    public private(set) var usingHardware = false

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: VideoFrameMessage.Codec?
    private var parameterSets: [Data] = []

    public init(allowsSoftware: Bool = true) {
        self.allowsSoftware = allowsSoftware
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one frame. New parameter sets (they come with keyframes and refresh frames) are taken in first: the
    /// session carries on if it accepts them, else a new one starts.
    public func decode(_ frame: VideoFrameMessage) throws -> Picture {
        if !frame.parameterSets.isEmpty, frame.parameterSets != parameterSets || frame.codec != codec {
            try take(frame.parameterSets, codec: frame.codec)
        }
        guard let format else { throw Failure.noParameterSets }
        let session = try self.session ?? makeSession(format)
        self.session = session
        guard !frame.data.isEmpty else { throw Failure.noPicture }
        let sample = try Self.sample(frame, format: format)
        let output = DecodeOutput()
        let clock = ContinuousClock()
        let start = clock.now
        // No asynchronous or temporal-order flags: the picture comes back before the call returns (the streams have
        // no frame reordering).
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            output.store(status: status, image: image)
        }
        let decodeMs = Self.milliseconds(clock.now - start)
        // The system took the decoder away (the app left the foreground): a new session for the next frame.
        if status == kVTInvalidSessionErr { reset(keepingFormat: true) }
        guard status == noErr else { throw Failure.decode(status) }
        let result = output.result
        guard result.status == noErr else { throw Failure.decode(result.status) }
        guard let image = result.image else { throw Failure.noPicture }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        return Picture(pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: image), width: width, height: height, decodeMs: decodeMs,
                       captureTime: frame.captureTime, region: frame.region)
    }

    /// Forgets the stream: the next frame must bring parameter sets (a keyframe).
    public func reset() {
        reset(keepingFormat: false)
    }

    private func reset(keepingFormat: Bool) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        usingHardware = false
        guard !keepingFormat else { return }
        format = nil
        codec = nil
        parameterSets = []
    }

    /// Starts using new parameter sets, in the same session when it accepts them.
    private func take(_ sets: [Data], codec: VideoFrameMessage.Codec) throws {
        let fresh = try Self.format(sets, codec: codec)
        if let session, codec != self.codec || !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fresh) {
            reset(keepingFormat: true)
        }
        format = fresh
        self.codec = codec
        parameterSets = sets
    }

    /// The hardware decoder, or a software one when allowed and the hardware has none for this stream.
    private func makeSession(_ format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        let output = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                      kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        let requireHardware = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var made: VTDecompressionSession?
        var status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: requireHardware, imageBufferAttributes: output,
                                                  outputCallback: nil, decompressionSessionOut: &made)
        let hardware = status == noErr
        if !hardware, allowsSoftware {
            status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil, imageBufferAttributes: output,
                                                  outputCallback: nil, decompressionSessionOut: &made)
        }
        guard status == noErr, let made else { throw Failure.session(status) }
        VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        usingHardware = hardware
        return made
    }

    /// A format description from the parameter sets (HEVC: VPS, SPS, PPS; H.264: SPS, PPS), for 4-byte NAL lengths.
    private static func format(_ sets: [Data], codec: VideoFrameMessage.Codec) throws -> CMVideoFormatDescription {
        guard !sets.contains(where: \.isEmpty) else { throw Failure.parameterSets(kCMFormatDescriptionError_InvalidParameter) }
        // All the sets back to back, so one call can point into each of them.
        let joined = sets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { all -> OSStatus in
            guard let base = all.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            let pointers = sizes.indices.map { base + sizes[..<$0].reduce(0, +) }
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw Failure.parameterSets(status) }
        return format
    }

    /// The frame's NAL units as one sample, timed by its capture time.
    private static func sample(_ frame: VideoFrameMessage, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        let timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: frame.captureTime, preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        do {
            let block = try CMBlockBuffer(length: frame.data.count, flags: .assureMemoryNow)
            try frame.data.withUnsafeBytes { try block.replaceDataBytes(with: $0) }
            return try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1, sampleTimings: [timing],
                                      sampleSizes: [frame.data.count])
        } catch {
            throw Failure.sample(OSStatus(truncatingIfNeeded: (error as NSError).code))
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: 4:4:4

    /// Whether this device's hardware decodes HEVC with 4:4:4 chroma: decodes a small 4:4:4 keyframe made by a Mac's
    /// encoder (`VideoDecoderTestFrame`) on the hardware decoder alone, and checks its colours, one-pixel stripes
    /// included. Worked out once, on first use, in a few milliseconds.
    public static let supports444: Bool = {
        let frame = VideoFrameMessage(displayID: 0, width: VideoDecoderTestFrame.width, height: VideoDecoderTestFrame.height,
                                      sequence: 0, captureTime: 0, codec: .hevc, flags: [.keyframe, .refresh, .chroma444],
                                      parameterSets: VideoDecoderTestFrame.parameterSets.map { Data($0) },
                                      data: Data(VideoDecoderTestFrame.frame))
        guard let picture = try? VideoDecoder(allowsSoftware: false).decode(frame),
              picture.width == VideoDecoderTestFrame.width, picture.height == VideoDecoderTestFrame.height else { return false }
        return picture.pixelBuffer.withUnsafeBuffer { showsTestFrame($0) }
    }()

    /// Whether a decoded BGRA picture of `VideoDecoderTestFrame` shows what was drawn.
    static func showsTestFrame(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        return VideoDecoderTestFrame.probes.allSatisfy { probe in
            let pixel = (base + probe.y * row + probe.x * 4).assumingMemoryBound(to: UInt8.self)
            return [(pixel[2], probe.red), (pixel[1], probe.green), (pixel[0], probe.blue)].allSatisfy { got, drawn in
                abs(Int(got) - Int(drawn)) <= VideoDecoderTestFrame.tolerance
            }
        }
    }
}

/// What the decoder's output handler hands back. Decoding is synchronous, so the handler has run (on whichever thread
/// the decoder chose) before `VTDecompressionSessionDecodeFrame` returns; the lock makes that hand-over explicit.
nonisolated private final class DecodeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var status: OSStatus = noErr
    private var image: CVImageBuffer?

    func store(status: OSStatus, image: CVImageBuffer?) {
        lock.withLock {
            self.status = status
            self.image = image
        }
    }

    var result: (status: OSStatus, image: CVImageBuffer?) {
        lock.withLock { (status, image) }
    }
}
