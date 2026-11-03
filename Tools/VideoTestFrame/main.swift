// Makes Shared/Video/VideoDecoderTestFrame.swift: one small HEVC Main 4:4:4 keyframe from this Mac's hardware encoder
// in low-latency mode, as the hub encodes, for the phone's 4:4:4 decode check (`VideoDecoder.supports444`). The picture
// is four bands of colour above one-pixel red and blue stripes, which 4:2:0 chroma would blur into purple. It checks
// that this Mac decodes the frame back to those colours before writing anything. Run on a Mac:
//   xcrun swiftc -O Tools/VideoTestFrame/main.swift -o build/videotestframe
//   build/videotestframe > Shared/Video/VideoDecoderTestFrame.swift
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let side = 128

struct RGB: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

/// The test picture: red, green, blue and white bands above; one-pixel red and blue stripes below.
func color(x: Int, y: Int) -> RGB {
    let red = RGB(red: 230, green: 40, blue: 40)
    let blue = RGB(red: 40, green: 60, blue: 230)
    guard y < side / 2 else { return x.isMultiple(of: 2) ? red : blue }
    return [red, RGB(red: 40, green: 200, blue: 60), blue, RGB(red: 235, green: 235, blue: 235)][x * 4 / side]
}

/// The pixels the phone checks: the middle of each band, and neighbouring stripes.
let probes: [(x: Int, y: Int)] = [(16, 32), (48, 32), (80, 32), (112, 32), (62, 96), (63, 96), (64, 100), (65, 100)]
/// How far a decoded probe may stray per channel (colour matrix and range differences stay well inside it; a 4:2:0
/// decode puts the stripes about 95 away).
let tolerance = 60

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("videotestframe: \(message)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (\(status))") }
}

func set(_ session: VTSession, _ key: CFString, _ value: CFTypeRef) {
    check(VTSessionSetProperty(session, key: key, value: value), "setting \(key)")
}

func tag709(_ buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
}

func pixelBuffer(_ format: OSType) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    check(CVPixelBufferCreate(nil, side, side, format, attributes, &buffer), "making a pixel buffer")
    guard let buffer else { fail("no pixel buffer") }
    return buffer
}

/// Reads a BGRA pixel.
func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> RGB {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { fail("no pixels") }
    let bytes = base.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return RGB(red: bytes[2], green: bytes[1], blue: bytes[0])
}

/// The HEVC SPS's general_profile_idc and chroma_format_idc.
func profileAndChroma(sps: [UInt8]) -> (profile: Int, chroma: Int) {
    var rbsp: [UInt8] = []
    var zeros = 0
    for byte in sps.dropFirst(2) {
        if zeros >= 2, byte == 3 {
            zeros = 0
            continue
        }
        rbsp.append(byte)
        zeros = byte == 0 ? zeros + 1 : 0
    }
    var bit = 0
    func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = bit / 8 < rbsp.count ? rbsp[bit / 8] : 0
            value = value << 1 | Int(byte >> (7 - UInt8(bit % 8)) & 1)
            bit += 1
        }
        return value
    }
    func golomb() -> Int {
        var zeros = 0
        while read(1) == 0, zeros < 32 { zeros += 1 }
        return (1 << zeros) - 1 + read(zeros)
    }
    _ = read(4)
    let subLayers = read(3)
    _ = read(1)
    _ = read(3)
    let profile = read(5)
    _ = read(32 + 4 + 43 + 1 + 8)
    var present: [(profile: Bool, level: Bool)] = []
    for _ in 0..<subLayers { present.append((read(1) == 1, read(1) == 1)) }
    if subLayers > 0 { for _ in subLayers..<8 { _ = read(2) } }
    for layer in present {
        if layer.profile { _ = read(88) }
        if layer.level { _ = read(8) }
    }
    _ = golomb()
    return (profile, golomb())
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// The encoder's own name for HEVC Main 4:4:4 (8-bit), in low-latency mode.
let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
var encoderID: CFString?
var supported: CFDictionary?
check(VTCopySupportedPropertyDictionaryForEncoder(width: Int32(side), height: Int32(side), codecType: kCMVideoCodecType_HEVC,
                                                  encoderSpecification: specification, encoderIDOut: &encoderID,
                                                  supportedPropertiesOut: &supported), "asking the HEVC encoder")
guard let properties = supported as? [String: Any],
      let profileLevel = properties[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any],
      let profiles = profileLevel[kVTPropertySupportedValueListKey as String] as? [String],
      let profile = profiles.first(where: { $0.contains("Main444") && !$0.contains("10") })
else { fail("this Mac's low-latency HEVC encoder has no Main 4:4:4 profile") }

var made: VTCompressionSession?
check(VTCompressionSessionCreate(allocator: nil, width: Int32(side), height: Int32(side), codecType: kCMVideoCodecType_HEVC,
                                 encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                 outputCallback: nil, refcon: nil, compressionSessionOut: &made), "making the encoder")
guard let encoder = made else { fail("no encoder") }
set(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
set(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
set(encoder, kVTCompressionPropertyKey_ProfileLevel, profile as CFString)
set(encoder, kVTCompressionPropertyKey_AverageBitRate, 6_000_000 as CFNumber)
set(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber)
set(encoder, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
set(encoder, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
set(encoder, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

// Draw the picture in BGRA, then make it 4:4:4 Y'CbCr ('444v') for the encoder.
let source = pixelBuffer(kCVPixelFormatType_32BGRA)
CVPixelBufferLockBaseAddress(source, [])
if let base = CVPixelBufferGetBaseAddress(source) {
    let row = CVPixelBufferGetBytesPerRow(source)
    for y in 0..<side {
        for x in 0..<side {
            let rgb = color(x: x, y: y)
            let pixel = base.assumingMemoryBound(to: UInt8.self) + y * row + x * 4
            pixel[0] = rgb.blue
            pixel[1] = rgb.green
            pixel[2] = rgb.red
            pixel[3] = 255
        }
    }
}
CVPixelBufferUnlockBaseAddress(source, [])
tag709(source)
let input = pixelBuffer(kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
tag709(input)
var transfer: VTPixelTransferSession?
check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "making the converter")
guard let transfer else { fail("no converter") }
set(transfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
check(VTPixelTransferSessionTransferImage(transfer, from: source, to: input), "converting to 4:4:4")

let encoded = Box<CMSampleBuffer?>(nil)
check(VTCompressionSessionEncodeFrame(encoder, imageBuffer: input, presentationTimeStamp: .zero,
                                      duration: CMTime(value: 1, timescale: 30),
                                      frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary,
                                      infoFlagsOut: nil) { status, _, sample in
    if status == noErr { encoded.value = sample }
}, "encoding")
check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), "finishing")
guard let sample = encoded.value, let format = CMSampleBufferGetFormatDescription(sample),
      let block = CMSampleBufferGetDataBuffer(sample) else { fail("the encoder gave nothing back") }
let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
    .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
if notSync { fail("the frame isn't a keyframe") }

var parameterSets: [[UInt8]] = []
var count = 0
var lengthSize: Int32 = 0
repeat {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: parameterSets.count,
                                                             parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                             parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize),
          "reading parameter set \(parameterSets.count)")
    guard let pointer else { fail("empty parameter set") }
    parameterSets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
} while parameterSets.count < count
if lengthSize != 4 { fail("NAL unit lengths are \(lengthSize) bytes, not 4") }
guard let sps = parameterSets.first(where: { ($0[0] >> 1) & 0x3F == 33 }) else { fail("no SPS") }
let stream = profileAndChroma(sps: sps)
if stream.chroma != 3 { fail("the frame is chroma_format_idc \(stream.chroma), not 4:4:4") }
var frame = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frame.count, destination: &frame), "copying the frame")

// Decode it back on this Mac's hardware decoder, as the phone will, and check the probes.
var decoder: VTDecompressionSession?
let output = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
              kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
let hardware = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: kCFBooleanTrue] as CFDictionary
check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: hardware,
                                   imageBufferAttributes: output, outputCallback: nil, decompressionSessionOut: &decoder),
      "making the hardware decoder")
guard let decoder else { fail("no decoder") }
let decoded = Box<CVPixelBuffer?>(nil)
check(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
    if status == noErr { decoded.value = image }
}, "decoding")
guard let picture = decoded.value else { fail("the decoder gave nothing back") }
if CVPixelBufferGetWidth(picture) != side || CVPixelBufferGetHeight(picture) != side { fail("decoded at the wrong size") }
for probe in probes {
    let want = color(x: probe.x, y: probe.y)
    let got = pixel(picture, x: probe.x, y: probe.y)
    let off = max(abs(Int(got.red) - Int(want.red)), abs(Int(got.green) - Int(want.green)), abs(Int(got.blue) - Int(want.blue)))
    if off > tolerance { fail("probe \(probe) decoded as \(got), wanted \(want)") }
    FileHandle.standardError.write(Data("probe \(probe): drawn \(want), decoded \(got)\n".utf8))
}

func literal(_ bytes: [UInt8], indent: String) -> String {
    stride(from: 0, to: bytes.count, by: 16).map { start in
        indent + bytes[start..<min(start + 16, bytes.count)].map { String(format: "0x%02X,", $0) }.joined(separator: " ")
    }.joined(separator: "\n")
}

let names = ["VPS", "SPS", "PPS"]
print("""
// Generated by Tools/VideoTestFrame on a Mac; don't edit. Remake with:
//   xcrun swiftc -O Tools/VideoTestFrame/main.swift -o build/videotestframe
//   build/videotestframe > Shared/Video/VideoDecoderTestFrame.swift
// Encoder: \(encoderID as String? ?? "HEVC"), \(profile).
import Foundation

/// One \(side)×\(side) HEVC Main 4:4:4 keyframe from a Mac's hardware encoder in low-latency mode, as the hub encodes, for
/// the phone's 4:4:4 check (`VideoDecoder.supports444`): red, green, blue and white bands above one-pixel red and
/// blue stripes, which a 4:2:0 decode blurs into purple.
nonisolated enum VideoDecoderTestFrame {
    static let width = \(side)
    static let height = \(side)

    /// \(parameterSets.indices.map { names.indices.contains($0) ? names[$0] : "set \($0)" }.joined(separator: ", ")).
    static let parameterSets: [[UInt8]] = [
\(parameterSets.map { "        [\n" + literal($0, indent: "            ") + "\n        ]," }.joined(separator: "\n"))
    ]

    /// The frame: NAL units with 4-byte big-endian lengths.
    static let frame: [UInt8] = [
\(literal(frame, indent: "        "))
    ]

    /// Pixels to check, as they were drawn.
    static let probes: [(x: Int, y: Int, red: UInt8, green: UInt8, blue: UInt8)] = [
\(probes.map { probe in
    let rgb = color(x: probe.x, y: probe.y)
    return "        (\(probe.x), \(probe.y), \(rgb.red), \(rgb.green), \(rgb.blue)),"
}.joined(separator: "\n"))
    ]

    /// How far a decoded probe may stray per channel: colour matrix and range differences stay well inside it, and a
    /// 4:2:0 decode puts the stripes about 95 away.
    static let tolerance = \(tolerance)
}
""")
let sizes = "parameter sets \(parameterSets.map(\.count)) bytes, frame \(frame.count) bytes"
FileHandle.standardError.write(Data("videotestframe: \(profile), \(sizes)\n".utf8))
