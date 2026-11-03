import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The live picture as HEVC or H.264 from the hardware encoder in its low-latency mode: one `VideoFrameMessage` per
/// encoded frame, numbered, with the parameter sets on every keyframe and refresh frame.
///
/// Every frame it makes is a long-term reference candidate with a token. The phone returns the tokens of the frames it
/// decoded (`acknowledge`), and a refresh (`requestRefresh`) is then a small frame that refers only to one of those, so
/// a phone that lost its place picks up again without a keyframe; with nothing acknowledged since the last keyframe, a
/// refresh is a keyframe. `encode` is called from one queue at a time; requests, acknowledgements and bitrate changes
/// may come from any thread and apply from the next `encode`. Frames come out on VideoToolbox's thread, in order.
nonisolated public final class VideoEncoder: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        public var codec: VideoFrameMessage.Codec
        public var width: Int
        public var height: Int
        public var fps: Int
        /// Average bits per second.
        public var bitrate: Int
        /// Asks for 4:4:4 chroma: HEVC only, where the hardware encoder has a 4:4:4 profile.
        public var chroma444: Bool
        /// The display the frames show, written into each message.
        public var displayID: UInt32

        public init(codec: VideoFrameMessage.Codec, width: Int, height: Int, fps: Int, bitrate: Int,
                    chroma444: Bool = false, displayID: UInt32 = 0) {
            self.codec = codec
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.chroma444 = chroma444
            self.displayID = displayID
        }
    }

    /// What comes out of the encoder.
    public enum Output: Sendable {
        case frame(VideoFrameMessage)
        /// The encoder dropped a frame (it may, to keep to its bitrate). A keyframe or refresh it was asked for is asked
        /// for again at the next `encode`.
        case dropped
    }

    /// 4:4:4 profiles as the encoders name them in their supported values (VideoToolbox exports no constants for these),
    /// first choice first, each with the pixel format it needs: the 8-bit profile only from 8-bit 4:4:4 input (from
    /// anything else it quietly makes 4:2:0), the 10-bit one from any input. 8-bit comes first because it's what the
    /// phone's launch check (`VideoDecoder.supports444`) proves its hardware decodes, and any 10-bit 4:4:4 decoder
    /// decodes it too; a 10-bit stream could fail on a phone that passed, and fall back to 4:2:0 on every connection.
    static let chroma444Profiles: [(profile: String, pixelFormat: OSType)] = [
        ("HEVC_Main444_AutoLevel", kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
        ("HEVC_Main44410_AutoLevel", kCVPixelFormatType_444YpCbCr10BiPlanarFullRange),
    ]

    /// How many frame tokens it remembers for acknowledgements that arrive late (about 4 s at 60 fps).
    static let rememberedTokens = 256

    public let settings: Settings
    /// The pixel format to feed it: '420v', or for 4:4:4 '444v' (the 8-bit profile) or 'xf44' (the 10-bit one).
    public let pixelFormat: OSType
    /// The profile it encodes with, as VideoToolbox names it.
    public let profile: String
    /// Set up for 4:4:4. Each frame's `.chroma444` flag says what its bitstream really carries.
    public let chroma444: Bool
    /// Long-term references are on: refreshes need no keyframe once a frame is acknowledged.
    public let longTermReferences: Bool
    /// Optional properties the encoder turned down, for the log.
    public let declined: [String]

    private enum Forced { case none, keyframe, refresh }

    private let session: VTCompressionSession
    private let output: @Sendable (Output) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var wantsKeyframe = false
    private var wantsRefresh = false
    /// The encoder's tokens for frames the phone acknowledged, handed over at the next `encode`.
    private var acknowledged: [NSNumber] = []
    /// Some frame since the last keyframe was acknowledged, so a refresh can refer to it.
    private var referenceAcknowledged = false
    private var bitrate: Int
    private var appliedBitrate: Int
    private var sequence: UInt32
    /// The tokens on the wire (never 0) for the encoder's own, which needn't fit in 32 bits.
    private var tokens: [UInt32: NSNumber] = [:]
    private var tokenOrder: [UInt32] = []
    private var lastToken: UInt32
    private var bitstreamIs444 = false
    // Used by `encode` only.
    private var colorsTagged = false

    /// Starts a hardware session for these settings; throws when the hardware has none. `sequence` is the number the
    /// frame before the first one had (a stream that starts a new encoder keeps counting).
    public convenience init(settings: Settings, sequence: UInt32 = 0, output: @escaping @Sendable (Output) -> Void) throws {
        try self.init(settings: settings, sequence: sequence, chroma444Profiles: Self.chroma444Profiles, output: output)
    }

    /// The same, trying only the given 4:4:4 profiles (the tests pick the 8-bit one this way).
    init(settings: Settings, sequence: UInt32, chroma444Profiles: [(profile: String, pixelFormat: OSType)],
         output: @escaping @Sendable (Output) -> Void) throws {
        let codecType = settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let name = settings.codec == .hevc ? "HEVC" : "H.264"
        var made: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
                                                 codecType: codecType,
                                                 encoderSpecification: Self.lowLatency as CFDictionary,
                                                 imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                 refcon: nil, compressionSessionOut: &made)
        guard created == noErr, let session = made else {
            throw WireError.failed("The Mac's \(name) encoder couldn't start (\(created)).")
        }
        var declined: [String] = []
        func set(_ key: CFString, _ value: CFTypeRef) -> Bool {
            let accepted = VTSessionSetProperty(session, key: key, value: value) == noErr
            if !accepted { declined.append(key as String) }
            return accepted
        }

        var profile = (settings.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel) as String
        var pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var chroma444 = false
        if settings.codec == .hevc, settings.chroma444 {
            let supported = Self.supportedProfiles(codecType, width: settings.width, height: settings.height)
            for candidate in chroma444Profiles where supported.contains(candidate.profile) {
                guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                           value: candidate.profile as CFString) == noErr else { continue }
                profile = candidate.profile
                pixelFormat = candidate.pixelFormat
                chroma444 = true
                break
            }
        }
        if !chroma444 { _ = set(kVTCompressionPropertyKey_ProfileLevel, profile as CFString) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        _ = set(kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as CFNumber)
        let longTermReferences = set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
        // Low-latency mode makes one keyframe and then none; this one is only a safety net.
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30 as CFNumber)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(session)
            throw WireError.failed("The Mac's \(name) encoder couldn't start (\(prepared)).")
        }

        self.settings = settings
        self.session = session
        self.output = output
        self.pixelFormat = pixelFormat
        self.profile = profile
        self.chroma444 = chroma444
        self.longTermReferences = longTermReferences
        self.declined = declined
        bitrate = settings.bitrate
        appliedBitrate = settings.bitrate
        self.sequence = sequence
        // Tokens from an earlier encoder can't be mistaken for this one's.
        lastToken = UInt32.random(in: 1...(UInt32.max / 2))
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Stops the session; frames still inside it are dropped.
    public func invalidate() {
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Encoding

    /// Encodes one frame. `time` must grow from frame to frame; `captureTime` (seconds on the host clock) and `region`
    /// (the part of the display the frame shows, nil for all of it) go into its message. False if VideoToolbox refused
    /// the frame.
    @discardableResult
    public func encode(_ pixels: CVPixelBuffer, time: CMTime, captureTime: Double, region: ScreenRegion? = nil) -> Bool {
        if !colorsTagged {
            colorsTagged = true
            tagColors(like: pixels)
        }
        let (properties, forced, newBitrate) = lock.withLock { () -> ([CFString: Any], Forced, Int?) in
            var properties: [CFString: Any] = [:]
            var forced = Forced.none
            if !acknowledged.isEmpty {
                properties[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledged
                acknowledged.removeAll()
                referenceAcknowledged = true
            }
            if wantsKeyframe || (wantsRefresh && !(longTermReferences && referenceAcknowledged)) {
                properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
                forced = .keyframe
            } else if wantsRefresh {
                properties[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
                forced = .refresh
            }
            wantsKeyframe = false
            wantsRefresh = false
            guard bitrate != appliedBitrate else { return (properties, forced, nil) }
            appliedBitrate = bitrate
            return (properties, forced, bitrate)
        }
        if let newBitrate {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFNumber)
        }
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time,
                                                     duration: .invalid,
                                                     frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
                                                     infoFlagsOut: nil) { [weak self] status, info, sample in
            self?.finished(status: status, info: info, sample: sample, forced: forced, captureTime: captureTime, region: region)
        }
        guard status == noErr else {
            askAgain(forced)
            return false
        }
        return true
    }

    /// Waits until every frame handed to `encode` has come out.
    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// The next frame is a keyframe (a new phone starts there).
    public func requestKeyframe() {
        lock.withLock { wantsKeyframe = true }
    }

    /// The next frame is safe to start from after a gap: it refers only to an acknowledged frame, or it's a keyframe.
    public func requestRefresh() {
        lock.withLock { wantsRefresh = true }
    }

    /// A keyframe or refresh is waiting for a frame to encode (an unchanged screen gives none: encode the last again).
    public var wantsFrame: Bool {
        lock.withLock { wantsKeyframe || wantsRefresh }
    }

    /// The phone decoded the frames with these tokens (`VideoFrameMessage.ltrToken`); unknown ones are ignored.
    public func acknowledge(_ wireTokens: [UInt32]) {
        lock.withLock {
            for wire in wireTokens {
                if let token = tokens.removeValue(forKey: wire) { acknowledged.append(token) }
            }
        }
    }

    /// The average bitrate from the next frame on.
    public var currentBitrate: Int {
        get { lock.withLock { bitrate } }
        set { lock.withLock { bitrate = max(1, newValue) } }
    }

    /// The sequence number of the newest frame out.
    public var lastSequence: UInt32 {
        lock.withLock { sequence }
    }

    private func askAgain(_ forced: Forced) {
        lock.withLock {
            switch forced {
            case .keyframe: wantsKeyframe = true
            case .refresh: wantsRefresh = true
            case .none: break
            }
        }
    }

    private func finished(status: OSStatus, info: VTEncodeInfoFlags, sample: CMSampleBuffer?, forced: Forced,
                          captureTime: Double, region: ScreenRegion?) {
        guard status == noErr, !info.contains(.frameDropped), let sample, let block = CMSampleBufferGetDataBuffer(sample),
              let data = Self.bytes(of: block) else {
            askAgain(forced)
            output(.dropped)
            return
        }
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
        let keyframe = !(attachments?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let token = attachments?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber
        var flags: VideoFrameMessage.Flags = keyframe ? [.keyframe, .refresh] : forced == .refresh ? .refresh : []
        // A keyframe asked for always comes as one; if not, the next frame asks again.
        if forced == .keyframe, !keyframe { askAgain(.keyframe) }
        let description = CMSampleBufferGetFormatDescription(sample)
        let parameterSets = flags.contains(.refresh) ? description.map { Self.parameterSets(of: $0, codec: settings.codec) } ?? [] : []
        let message: VideoFrameMessage = lock.withLock {
            if keyframe {
                // Nothing before a keyframe can be referred to after it.
                referenceAcknowledged = false
                acknowledged.removeAll()
                tokens.removeAll()
                tokenOrder.removeAll()
                if let description { bitstreamIs444 = settings.codec == .hevc && Self.chromaFormat(of: description) == 3 }
            }
            var wire: UInt32 = 0
            if let token {
                lastToken = lastToken == UInt32.max ? 1 : lastToken + 1
                wire = lastToken
                tokens[wire] = token
                tokenOrder.append(wire)
                if tokenOrder.count > Self.rememberedTokens { tokens[tokenOrder.removeFirst()] = nil }
            }
            if bitstreamIs444 { flags.insert(.chroma444) }
            sequence &+= 1
            return VideoFrameMessage(displayID: settings.displayID, width: settings.width, height: settings.height,
                                     sequence: sequence, captureTime: captureTime, codec: settings.codec, flags: flags,
                                     ltrToken: wire, parameterSets: parameterSets, region: region, data: data)
        }
        output(.frame(message))
    }

    // MARK: Format

    /// Tags the stream's colours as the first frame's: its primaries, transfer function and YCbCr matrix, BT.709 for
    /// any it lacks.
    private func tagColors(like pixels: CVPixelBuffer) {
        let tags: [(attachment: CFString, property: CFString, fallback: CFString)] = [
            (kCVImageBufferColorPrimariesKey, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for tag in tags {
            let value = CVBufferCopyAttachment(pixels, tag.attachment, nil) ?? tag.fallback
            VTSessionSetProperty(session, key: tag.property, value: value)
        }
    }

    /// The low-latency hardware encoder.
    private static var lowLatency: [CFString: Any] {
        [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
         kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    }

    /// The profile names the hardware encoders list for a codec at this size. The low-latency HEVC encoder (macOS 27)
    /// lists H.264's names instead of its own, so the plain hardware encoder's list (the same media engine) counts too.
    static func supportedProfiles(_ codecType: CMVideoCodecType, width: Int, height: Int) -> Set<String> {
        let hardware: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var names = Set<String>()
        for specification in [lowLatency, hardware] {
            var properties: CFDictionary?
            guard VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height), codecType: codecType,
                                                              encoderSpecification: specification as CFDictionary,
                                                              encoderIDOut: nil, supportedPropertiesOut: &properties) == noErr,
                  let all = properties as? [CFString: Any],
                  let profile = all[kVTCompressionPropertyKey_ProfileLevel] as? [CFString: Any],
                  let values = profile[kVTPropertySupportedValueListKey] as? [String] else { continue }
            names.formUnion(values)
        }
        return names
    }

    /// The parameter sets in a frame's format description: HEVC's VPS, SPS and PPS, or H.264's SPS and PPS.
    public static func parameterSets(of description: CMFormatDescription, codec: VideoFrameMessage.Codec) -> [Data] {
        var sets: [Data] = []
        var count = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index,
                                                                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
                                                                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return sets
    }

    /// An HEVC stream's chroma format (1 is 4:2:0, 3 is 4:4:4), from the decoder configuration record ('hvcC') the
    /// encoder wrote: byte 16 holds it in its two low bits.
    static func chromaFormat(of description: CMFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(description,
                                                          extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any],
              let record = atoms["hvcC"] as? Data, record.count > 16 else { return nil }
        return Int(record[record.startIndex + 16] & 0x03)
    }

    private static func bytes(of block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}
