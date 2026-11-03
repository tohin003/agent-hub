import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams one display, as JPEG frames (for phones from before the video codecs) or as HEVC or H.264 from the hardware
/// encoder. ScreenCaptureKit only delivers a frame when the screen changes, so an idle screen costs nothing.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// No hardware encoder started for the codecs asked for: the phone gets JPEG instead.
    struct NoVideoEncoder: Error {}

    /// A video frame ready for the wire, with what decides who gets it.
    struct VideoFrame: Sendable {
        let flags: VideoFrameMessage.Flags
        let sequence: UInt32
        let ltrToken: UInt32
        /// The part of the display it shows, when a zoomed-in phone asked for one (`setRegion`).
        let region: ScreenRegion?
        let bytes: Data
    }

    /// The sizes a region is planned from (`CaptureRegionPlanner`): the frames' and the display's, in pixels.
    struct CaptureGeometry: Equatable {
        let output: CGSize
        let display: CGSize
    }

    /// What a running video stream was started with; a newer phone asking for something else restarts it.
    struct VideoShape: Equatable {
        var maxPixels: Int
        var fps: Int
        var codec: String?
        var chroma444: Bool
        var showsCursor: Bool

        init(_ params: ScreenStartParams) {
            maxPixels = params.maxPixels
            fps = params.fps
            codec = params.codec
            chroma444 = params.chroma444 == true
            showsCursor = params.cursor != true
        }
    }

    /// The frame rate a video stream runs at when the display doesn't say how fast it refreshes.
    static let maxVideoFPS = 60

    let displayID: CGDirectDisplayID
    /// HEVC or H.264 rather than JPEG, for the streamer's whole life.
    let video: Bool
    private var stream: SCStream?
    /// The running capture's configuration (for changing its frame rate and region) and the rate it was started at.
    private var configuration: SCStreamConfiguration?
    private var startedFPS = ScreenStreamer.maxVideoFPS
    private var cappedFPS: Int?
    /// The display's size and place on the desktop, in points, for the region a frame shows.
    private var displayPoints = CGSize.zero
    private var displayOrigin = CGPoint.zero
    private let queue = DispatchQueue(label: "agenthub.screen", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var quality: Double = 0.6
    private var sequence: UInt32 = 0
    private let lock = NSLock()
    private var lastFrame: Data?
    // Video. Used on `queue`:
    private var encoder: VideoEncoder?
    /// The newest frame captured, which a refresh or a new phone's keyframe encodes again on an unchanged screen.
    private var lastPixels: CVPixelBuffer?
    private var lastTime = CMTime.invalid
    private var lastEncodedTime = CMTime.invalid
    /// The newest frame was captured while every phone waited, and isn't encoded yet.
    private var withheld = false
    private var frameInterval = 1.0 / 60
    /// The sequence number of the last frame of an earlier encoder, so a restarted stream keeps counting.
    private var lastSequence: UInt32 = 0
    /// ScreenCaptureKit's 4:4:4 frames carry no colour tags (see `tagBT601`).
    private var untagged444 = false
    /// The part of the display the newest frame shows (nil: all of it).
    private var lastRegion: ScreenRegion?
    /// The fastest the display refreshes, which caps the frame rate (and paces re-encoding an unchanged screen).
    private var refreshFPS = ScreenStreamer.maxVideoFPS
    /// The encoder's bitrate now, and when a still screen gets its refinement passes.
    private var linkBitrate = 0
    private var refinement = RefinementTrigger()
    private var refinementCheck = 0
    /// The capture time of the last refinement pass, which tells its frame from the others when it comes out.
    private var passTime: Double?
    // Guarded by `lock`:
    private var holdingFrames = false
    private var shape: VideoShape?
    private var startBitrate: Int?
    private var geometry: CaptureGeometry?
    private var fullFPS = ScreenStreamer.maxVideoFPS
    /// Called on the capture queue with a complete binary frame (header + JPEG).
    var onFrame: ((Data) -> Void)?
    /// Called on VideoToolbox's thread with each encoded frame, in order.
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onStop: ((Error?) -> Void)?

    init(displayID: CGDirectDisplayID, video: Bool = false) {
        self.displayID = displayID
        self.video = video
    }

    var latestFrame: Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame
    }

    /// What the running video stream was started with.
    var videoShape: VideoShape? { lock.withLock { shape } }

    /// The bitrate the running video stream started at: the one asked for, or one for its size.
    var videoBitrate: Int? { lock.withLock { startBitrate } }

    /// The running video stream's frame and display sizes, for planning a region.
    var captureGeometry: CaptureGeometry? { lock.withLock { geometry } }

    /// The frame rate the running video stream was started at: the one asked for, within the display's refresh rate.
    var fullFrameRate: Int { lock.withLock { fullFPS } }

    /// Starts the stream as the phone asked: JPEG, or video when this streamer is for video.
    func start(_ params: ScreenStartParams, hiding: Set<CGWindowID>) async throws {
        if video {
            try await startVideo(params, hiding: hiding)
        } else {
            try await start(maxPixels: params.maxPixels, fps: params.fps, quality: params.quality,
                            showsCursor: params.cursor != true, hiding: hiding)
        }
    }

    func start(maxPixels: Int, fps: Int, quality: Double, showsCursor: Bool = true, hiding: Set<CGWindowID>) async throws {
        self.quality = min(max(quality, 0.2), 0.95)
        let (display, filter) = try await Self.filter(displayID, hiding: hiding)
        let configuration = SCStreamConfiguration()
        let size = Self.outputSize(display, maxPixels: maxPixels)
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 30))))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        try await capture(configuration, filter)
        Log.info("screen: streaming display \(displayID) at \(configuration.width)×\(configuration.height), \(fps) fps")
    }

    /// HEVC (4:4:4 if asked for and possible), then H.264: the first the hardware starts. Throws `NoVideoEncoder` if
    /// none does.
    private func startVideo(_ params: ScreenStartParams, hiding: Set<CGWindowID>) async throws {
        let (display, filter) = try await Self.filter(displayID, hiding: hiding)
        let size = Self.outputSize(display, maxPixels: max(params.maxPixels, 64))
        // As fast as the display refreshes (120 on ProMotion), if the phone asked for that much.
        let id = displayID
        let refresh = FrameRatePolicy.displayMaximum(reported: await MainActor.run { FrameRatePolicy.reportedMaximum(of: id) })
        let fps = min(max(params.fps, 1), refresh)
        displayPoints = CGSize(width: display.width, height: display.height)
        displayOrigin = CGDisplayBounds(displayID).origin
        let scale = Self.pixelScale(display)
        let sizes = CaptureGeometry(output: CGSize(width: size.width, height: size.height),
                                      display: CGSize(width: Double(display.width) * scale, height: Double(display.height) * scale))
        let bitrate = params.bitrate.map { max($0, VideoPacing.lowestBitrate) }
            ?? VideoPacing.defaultBitrate(width: size.width, height: size.height, fps: fps)
        var attempts: [(codec: VideoFrameMessage.Codec, chroma444: Bool)] = []
        if params.codec == "hevc" {
            if params.chroma444 == true { attempts.append((.hevc, true)) }
            attempts.append((.hevc, false))
        }
        attempts.append((.h264, false))
        for attempt in attempts {
            let settings = VideoEncoder.Settings(codec: attempt.codec, width: size.width, height: size.height, fps: fps,
                                                 bitrate: bitrate, chroma444: attempt.chroma444, displayID: displayID)
            let base = queue.sync { lastSequence }
            let encoder: VideoEncoder
            do {
                encoder = try VideoEncoder(settings: settings, sequence: base) { [weak self] output in
                    self?.encoded(output)
                }
            } catch {
                Log.warn("screen: \(error.localizedDescription)")
                continue
            }
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            configuration.pixelFormat = encoder.pixelFormat
            configuration.colorSpaceName = CGColorSpace.sRGB
            if encoder.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            }
            configuration.showsCursor = params.cursor != true
            configuration.queueDepth = 3
            configuration.capturesAudio = false
            queue.sync {
                self.encoder = encoder
                lastPixels = nil
                lastRegion = nil
                lastTime = .invalid
                lastEncodedTime = .invalid
                withheld = false
                frameInterval = 1 / Double(fps)
                refreshFPS = refresh
                linkBitrate = bitrate
                refinement = RefinementTrigger()
                passTime = nil
                untagged444 = encoder.chroma444
            }
            startedFPS = fps
            cappedFPS = nil
            do {
                try await capture(configuration, filter)
            } catch {
                queue.sync { self.encoder = nil }
                encoder.invalidate()
                // ScreenCaptureKit may turn a 4:4:4 format down: 4:2:0 next. Anything else is the capture's own failure.
                guard encoder.chroma444 else { throw error }
                Log.warn("screen: display \(displayID) can't be captured in 4:4:4 (\(error.localizedDescription)); trying 4:2:0")
                continue
            }
            lock.withLock {
                shape = VideoShape(params)
                startBitrate = bitrate
                geometry = sizes
                fullFPS = fps
            }
            let codec = attempt.codec == .hevc ? (encoder.chroma444 ? "HEVC 4:4:4" : "HEVC") : "H.264"
            let declined = encoder.declined.isEmpty ? "" : "; the encoder declined \(encoder.declined.joined(separator: ", "))"
            Log.info("screen: streaming display \(displayID) as \(codec) (\(encoder.profile)) at \(size.width)×\(size.height), "
                + "\(fps) fps, \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbit/s\(declined)")
            return
        }
        throw NoVideoEncoder()
    }

    private func capture(_ configuration: SCStreamConfiguration, _ filter: SCContentFilter) async throws {
        self.configuration = configuration
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// The size frames are sent at: the display in pixels, shrunk so its longest side fits `maxPixels`, in even numbers.
    private static func outputSize(_ display: SCDisplay, maxPixels: Int) -> (width: Int, height: Int) {
        let scale = pixelScale(display)
        let fullWidth = Double(display.width) * scale
        let fullHeight = Double(display.height) * scale
        let shrink = min(1, Double(maxPixels) / max(fullWidth, fullHeight))
        return (Int((fullWidth * shrink).rounded()) & ~1, Int((fullHeight * shrink).rounded()) & ~1)
    }

    /// The display's pixels per point (2 on Retina). The display mode knows the real pixel width; CGDisplayPixelsWide
    /// reports points on Retina screens.
    private static func pixelScale(_ display: SCDisplay) -> Double {
        let pixelWidth = Double(CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? CGDisplayPixelsWide(display.displayID))
        let pointWidth = Double(display.width)
        return pixelWidth > 0 && pointWidth > 0 ? max(1, pixelWidth / pointWidth) : 2
    }

    /// The whole display, less the given windows: the privacy screen's, while it's up, so the phone sees everything
    /// it covers (the hub's menu bar icon and menus too).
    private static func filter(_ displayID: CGDirectDisplayID, hiding: Set<CGWindowID>) async throws
        -> (SCDisplay, SCContentFilter) {
        var tries = 0
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw WireError.notFound("That display is no longer connected.")
            }
            let windows = content.windows.filter { hiding.contains($0.windowID) }
            // A window put on screen a moment ago may not be listed yet.
            if windows.count < hiding.count, tries < 5 {
                tries += 1
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            return (display, SCContentFilter(display: display, excludingWindows: windows))
        }
    }

    /// Leaves the privacy screen's windows out (it went up, or a display came or went) or puts nothing out (it came
    /// down).
    func refreshFilter(hiding: Set<CGWindowID>) async {
        guard let stream, let fresh = try? await Self.filter(displayID, hiding: hiding) else { return }
        do {
            try await stream.updateContentFilter(fresh.1)
        } catch {
            Log.warn("screen: couldn't update display \(displayID)'s filter: \(error.localizedDescription)")
        }
    }

    func update(maxPixels: Int, fps: Int, quality: Double, showsCursor: Bool = true, hiding: Set<CGWindowID>) async {
        await stop()
        try? await start(maxPixels: maxPixels, fps: fps, quality: quality, showsCursor: showsCursor, hiding: hiding)
    }

    /// Starts the video stream again with a newer phone's settings; false if it couldn't.
    func restart(_ params: ScreenStartParams, hiding: Set<CGWindowID>) async -> Bool {
        await stop()
        do {
            try await startVideo(params, hiding: hiding)
            return true
        } catch {
            Log.warn("screen: display \(displayID)'s video didn't start again: \(error.localizedDescription)")
            return false
        }
    }

    func stop() async {
        let running = stream
        stream = nil
        if let running { try? await running.stopCapture() }
        if video {
            // Also after the capture stopped on its own: the next encoder carries on counting.
            queue.sync {
                if let encoder {
                    lastSequence = encoder.lastSequence
                    encoder.invalidate()
                }
                encoder = nil
                lastPixels = nil
                withheld = false
                refinementCheck += 1
            }
            lock.withLock {
                shape = nil
                geometry = nil
            }
        }
        if running != nil { Log.info("screen: stopped display \(displayID)") }
    }

    // MARK: Video controls (from the screen service)

    /// While every phone waits for a refresh or a keyframe, captured frames aren't encoded (the newest is kept for the
    /// one asked for); when a phone takes frames again, a frame held back meanwhile goes out at once.
    var holding: Bool {
        get { lock.withLock { holdingFrames } }
        set {
            let released = lock.withLock { () -> Bool in
                defer { holdingFrames = newValue }
                return holdingFrames && !newValue
            }
            if released { queue.async { [weak self] in self?.sendWithheld() } }
        }
    }

    /// The next frame refreshes the phones (`keyframe`: starts a new phone): the newest frame if it was held back, else
    /// the next one captured, or (an unchanged screen sends none) the newest one again if none comes within a frame.
    func refresh(keyframe: Bool) {
        queue.async { [weak self] in
            guard let self, let encoder else { return }
            if keyframe { encoder.requestKeyframe() } else { encoder.requestRefresh() }
            if withheld {
                encodeNewest(encoder)
            } else {
                encodeSoonIfStill()
            }
        }
    }

    /// The phones decoded the frames with these tokens.
    func acknowledge(_ tokens: [UInt32]) {
        guard !tokens.isEmpty else { return }
        queue.async { [weak self] in self?.encoder?.acknowledge(tokens) }
    }

    func setBitrate(_ bitrate: Int) {
        queue.async { [weak self] in
            self?.encoder?.currentBitrate = bitrate
            self?.linkBitrate = bitrate
        }
    }

    /// Captures only this part of the display (nil: all of it), at the stream's frame size: for a zoomed-in phone, at up
    /// to the display's own resolution. ScreenCaptureKit takes the new source rectangle without a restart (30 to 70 ms
    /// here), and every frame says which part it shows (`screenRect`), so frames already on their way keep theirs.
    /// The encoder carries on: the first frame of the new part is an ordinary one, not a keyframe.
    func setRegion(_ region: ScreenRegion?) async {
        guard video, let stream, let configuration, displayPoints.width > 0, displayPoints.height > 0 else { return }
        let rect = region.map {
            CGRect(x: $0.x * displayPoints.width, y: $0.y * displayPoints.height,
                   width: $0.width * displayPoints.width, height: $0.height * displayPoints.height)
        } ?? CGRect(origin: .zero, size: displayPoints)
        configuration.sourceRect = rect
        do {
            try await stream.updateConfiguration(configuration)
            Log.info("screen: display \(displayID) now captures "
                + (region.map { _ in String(format: "%.0f×%.0f pt at %.0f,%.0f", rect.width, rect.height, rect.minX, rect.minY) }
                   ?? "all of it"))
        } catch {
            Log.warn("screen: couldn't change the part of display \(displayID) captured: \(error.localizedDescription)")
        }
    }

    /// Caps the video stream's frame rate (a slow path's limit, from the UDP transport), without restarting it; nil
    /// lifts the cap back to the rate it was started at.
    func limitFrameRate(_ fps: Int?) async {
        guard video, let stream, let configuration else { return }
        let rate = min(max(fps ?? startedFPS, 1), startedFPS)
        guard rate != (cappedFPS ?? startedFPS) else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        do {
            try await stream.updateConfiguration(configuration)
            cappedFPS = rate == startedFPS ? nil : rate
            queue.async { [weak self] in self?.frameInterval = 1 / Double(rate) }
            Log.info("screen: display \(displayID) now captures at up to \(rate) fps")
        } catch {
            Log.warn("screen: couldn't change display \(displayID)'s frame rate: \(error.localizedDescription)")
        }
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue), status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if video {
            let screenRect = (attachments.first?[.screenRect] as! CFDictionary?).flatMap { CGRect(dictionaryRepresentation: $0) }
            captured(pixelBuffer, at: sampleBuffer.presentationTimeStamp, region: screenRect.map(region(of:)) ?? lastRegion)
            return
        }
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

    /// The part of the display a frame shows, from where ScreenCaptureKit says it captured it; nil for all of it. That's
    /// on the desktop for a display away from its origin, else on the display itself.
    private func region(of screenRect: CGRect) -> ScreenRegion? {
        guard displayPoints.width > 0, displayPoints.height > 0 else { return nil }
        var rect = screenRect
        if displayOrigin != .zero, !CGRect(origin: .zero, size: displayPoints).insetBy(dx: -1, dy: -1).contains(rect) {
            rect = rect.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        }
        let region = ScreenRegion(x: rect.minX / displayPoints.width, y: rect.minY / displayPoints.height,
                                  width: rect.width / displayPoints.width, height: rect.height / displayPoints.height)
        return region.isWhole ? nil : region
    }

    /// A new frame from the display (on `queue`): the screen changed.
    private func captured(_ pixels: CVPixelBuffer, at time: CMTime, region: ScreenRegion?) {
        guard let encoder else { return }
        if untagged444 { Self.tagBT601(pixels) }
        lastPixels = pixels
        lastRegion = region
        lastTime = time
        refinement.changed(at: .now)
        scheduleRefinement()
        // While every phone waits, only a frame asked for is encoded.
        guard !holding || encoder.wantsFrame else {
            withheld = true
            return
        }
        encode(pixels, encoder: encoder, at: time)
    }

    private func encode(_ pixels: CVPixelBuffer, encoder: VideoEncoder, at time: CMTime) {
        withheld = false
        lastEncodedTime = time
        encoder.encode(pixels, time: time, captureTime: time.seconds, region: lastRegion)
    }

    /// Asks for the next refinement pass, if one is due later (on `queue`): `RefinementTrigger`. A newer change
    /// replaces the check.
    private func scheduleRefinement() {
        refinementCheck += 1
        guard let due = refinement.nextPass() else { return }
        let check = refinementCheck
        let delay = (due - ContinuousClock.now).components
        let wait = max(0, Double(delay.seconds) + Double(delay.attoseconds) / 1e18)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, check == refinementCheck else { return }
            if refinement.refineNow(at: .now, bitrate: linkBitrate), !holding, let encoder, lastPixels != nil {
                encodeNewest(encoder)
                passTime = lastEncodedTime.seconds
            }
            scheduleRefinement()
        }
    }

    /// Encodes the newest frame again unless a captured one answers the request first (on `queue`).
    private func encodeSoonIfStill() {
        let wait = min(frameInterval, 1.0 / Double(refreshFPS))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let encoder, encoder.wantsFrame else { return }
            encodeNewest(encoder)
        }
    }

    /// A phone takes frames again: the frame held back meanwhile goes out (on `queue`).
    private func sendWithheld() {
        guard withheld, let encoder else { return }
        encodeNewest(encoder)
    }

    /// The newest frame: at its own capture time if it was held back, else again at the time now (the screen hasn't
    /// changed since, so that's what it shows).
    private func encodeNewest(_ encoder: VideoEncoder) {
        guard let pixels = lastPixels else { return }
        if withheld {
            encode(pixels, encoder: encoder, at: lastTime)
            return
        }
        var time = CMClockGetTime(CMClockGetHostTimeClock())
        if lastEncodedTime.isValid, time <= lastEncodedTime {
            time = lastEncodedTime + CMTime(value: 1, timescale: 1_000_000)
        }
        encode(pixels, encoder: encoder, at: time)
    }

    /// From VideoToolbox's thread.
    private func encoded(_ output: VideoEncoder.Output) {
        switch output {
        case .frame(let message):
            let bytes = message.data.count
            let time = message.captureTime
            queue.async { [weak self] in
                guard let self else { return }
                refinement.encoded(bytes: bytes, pass: time == passTime, at: .now, bitrate: linkBitrate,
                                   frameInterval: frameInterval)
            }
            onVideoFrame?(VideoFrame(flags: message.flags, sequence: message.sequence, ltrToken: message.ltrToken,
                                     region: message.region, bytes: message.encoded()))
        case .dropped:
            // A keyframe or refresh asked for may have gone with it: it comes with the next frame, or this one again.
            queue.async { [weak self] in self?.encodeSoonIfStill() }
        }
    }

    /// ScreenCaptureKit's 4:4:4 frames come untagged, converted with BT.601 whatever `colorMatrix` asks for (measured
    /// on macOS 27 against the same screen in BGRA: within 0.2 of a code for BT.601, about 10 off for BT.709); its 4:2:0
    /// frames are BT.709 and say so. Tagged, the encoder describes the stream truthfully, and the phone's decoder
    /// converts it back with the right matrix.
    private static func tagBT601(_ pixels: CVPixelBuffer) {
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("screen: display \(displayID) stopped: \(error.localizedDescription)")
        self.stream = nil
        onStop?(error)
    }
}
