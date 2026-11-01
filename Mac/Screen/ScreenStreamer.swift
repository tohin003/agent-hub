import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams one display as JPEG frames. ScreenCaptureKit only delivers a frame when the screen changes, so an idle
/// screen costs nothing.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "agenthub.screen", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var quality: Double = 0.6
    private var sequence: UInt32 = 0
    private let lock = NSLock()
    private var lastFrame: Data?
    /// Called on the capture queue with a complete binary frame (header + JPEG).
    var onFrame: ((Data) -> Void)?
    var onStop: ((Error?) -> Void)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    var latestFrame: Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame
    }

    func start(maxPixels: Int, fps: Int, quality: Double) async throws {
        self.quality = min(max(quality, 0.2), 0.95)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw WireError.notFound("That display is no longer connected.")
        }
        // Never stream the hub's own windows (it has none on screen, but keep the filter honest).
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        // The display mode knows the real pixel width (CGDisplayPixelsWide reports points on Retina screens).
        let pixelWidth = Double(CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? CGDisplayPixelsWide(displayID))
        let pointWidth = Double(display.width)
        let scale = pixelWidth > 0 && pointWidth > 0 ? max(1, pixelWidth / pointWidth) : 2
        let fullWidth = Double(display.width) * scale
        let fullHeight = Double(display.height) * scale
        let shrink = min(1, Double(maxPixels) / max(fullWidth, fullHeight))
        configuration.width = Int((fullWidth * shrink).rounded()) & ~1
        configuration.height = Int((fullHeight * shrink).rounded()) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 30))))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("screen: streaming display \(displayID) at \(configuration.width)×\(configuration.height), \(fps) fps")
    }

    func update(maxPixels: Int, fps: Int, quality: Double) async {
        await stop()
        try? await start(maxPixels: maxPixels, fps: fps, quality: quality)
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Log.info("screen: stopped display \(displayID)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue), status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
        else { return }
        sequence &+= 1
        var frame = ScreenFrameHeader.make(displayID: displayID, width: CVPixelBufferGetWidth(pixelBuffer),
                                           height: CVPixelBufferGetHeight(pixelBuffer), sequence: sequence)
        frame.append(jpeg)
        lock.lock()
        lastFrame = frame
        lock.unlock()
        onFrame?(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("screen: display \(displayID) stopped: \(error.localizedDescription)")
        self.stream = nil
        onStop?(error)
    }
}
