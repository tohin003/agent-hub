import CoreVideo
import Observation
import UIKit
import VideoToolbox

/// Something that shows a display's video frames as they're decoded: `VideoSurfaceView`'s display layer.
protocol VideoSurface: AnyObject {
    /// Shows a frame of `region` of the display (nil: all of it), at once (`presentationTime` nil) or at that moment:
    /// µs on this phone's host clock (`TransportClock`), when Smooth or lip-sync holds the picture back.
    func show(_ frame: CVReadOnlyPixelBuffer, region: ScreenRegion?, at presentationTime: Int64?)
    /// The whole display as it last was, drawn around a zoomed-in part; nil: nothing.
    func setBackdrop(_ image: CGImage?)
}

/// One display's live picture and pointer, for `RemoteScreenView`. Decoded video frames go straight to the surfaces
/// attached here, never through SwiftUI, which sees only the picture's size and the Mac's pointer.
///
/// It is also the picture's side of the sync rule (`MediaSync`): each frame's delay from the Mac's capture to this
/// phone's glass is reported, and a frame is given a moment to show at when Smooth evens out the pace or lip-sync
/// holds the picture back to meet the sound (`PictureTiming`).
///
/// While the phone is zoomed in, the hub may send only the part around what it shows, sharper (`region`). The last
/// frame of the whole display then stays as a backdrop, so a pinch or a pan that shows more has something there
/// until the hub's next part arrives.
@Observable
final class VideoFeed {
    /// Smooth (the Screen tab's option): frames show at an even pace, a steady delay after their capture.
    static var smooth = false

    let displayID: UInt32
    /// The newest video frame's size in pixels; nil while the display streams JPEG, or nothing yet.
    private(set) var size: CGSize?
    /// The Mac's pointer, when the hub leaves it out of the picture for the phone to draw.
    private(set) var pointer: ScreenPointer?

    /// The newest video frame, for snapshots and for surfaces that attach later, and the part of the display it shows.
    @ObservationIgnored private(set) var latest: CVReadOnlyPixelBuffer?
    @ObservationIgnored private(set) var latestRegion: ScreenRegion?
    /// The whole display, from the last frame that showed all of it, while frames show only part.
    @ObservationIgnored private(set) var backdrop: CGImage?
    @ObservationIgnored private var surfaces: [WeakSurface] = []
    @ObservationIgnored private var position: CursorPositionMessage?
    @ObservationIgnored private var smoother = FrameSmoother()
    /// Frames shown so far, for waiting on the next one.
    @ObservationIgnored private(set) var framesShown = 0

    init(displayID: UInt32) {
        self.displayID = displayID
    }

    func show(_ picture: VideoDecoder.Picture) {
        if picture.region != nil, latestRegion == nil, let whole = latest {
            // Zoomed in: keep the whole display as it was (a copy, so no decoder buffer stays pinned).
            setBackdrop(Self.image(of: whole))
        } else if picture.region == nil, backdrop != nil {
            setBackdrop(nil)
        }
        latest = picture.pixelBuffer
        latestRegion = picture.region
        let size = CGSize(width: picture.width, height: picture.height)
        if self.size != size { self.size = size }
        surfaces.removeAll { $0.surface == nil }
        let presentation = presentationTime(capturedAt: picture.captureTime)
        for weak in surfaces { weak.surface?.show(picture.pixelBuffer, region: picture.region, at: presentation) }
        framesShown += 1
    }

    /// Returns when the next frame has gone to the surfaces, or after `limit` (a still screen sends none).
    func nextFrame(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        let shown = framesShown
        while framesShown == shown, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// When to show a frame the Mac captured at `captureTime` (seconds on its host clock): nil for at once (the lowest
    /// delay, or nothing to wait for), else Smooth's or lip-sync's moment. Reports the frame's delay to the glass too.
    private func presentationTime(capturedAt captureTime: Double, now: Int64 = TransportClock.now()) -> Int64? {
        let sinceCapture = captureTime > 0
            ? MacClock.shared.milliseconds(since: Int64(captureTime * 1_000_000), now: now) : nil
        return PictureTiming.presentationTime(sinceCapture: sinceCapture, smooth: Self.smooth, smoother: &smoother,
                                              sync: .shared, displayLatencyMs: Self.displayLatencyMs, now: now)
    }

    /// From handing a frame to the display layer to light from the glass: the render server composites it at the next
    /// refresh (half a refresh on average) and the panel shows that composite at the one after. 12.5 ms at 120 Hz,
    /// 25 ms at 60 Hz. An estimate: the layer doesn't say when a frame was shown.
    static var displayLatencyMs: Double {
        if let cached = cachedDisplayLatency { return cached }
        let latency = 1.5 * 1000 / Double(refreshRate)
        cachedDisplayLatency = latency
        return latency
    }

    /// The fastest this phone's screen refreshes.
    static var refreshRate: Int {
        max(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.max() ?? 60, 1)
    }

    private static var cachedDisplayLatency: Double?

    /// The display streams JPEG now: `RemoteScreenView` shows the image again.
    func endVideo() {
        latest = nil
        latestRegion = nil
        setBackdrop(nil)
        smoother.reset()
        if size != nil { size = nil }
    }

    /// A still of the whole display: the newest frame when it shows all of it, else the backdrop.
    var wholeStill: CGImage? {
        if latestRegion != nil { return backdrop }
        return latest.flatMap(Self.image(of:))
    }

    /// Starts sending frames to a surface, the newest one at once.
    func attach(_ surface: VideoSurface) {
        guard !surfaces.contains(where: { $0.surface === surface }) else { return }
        surfaces.append(WeakSurface(surface: surface))
        surface.setBackdrop(backdrop)
        if let latest { surface.show(latest, region: latestRegion, at: nil) }
    }

    func detach(_ surface: VideoSurface) {
        surfaces.removeAll { $0.surface == nil || $0.surface === surface }
    }

    private func setBackdrop(_ image: CGImage?) {
        backdrop = image
        for weak in surfaces { weak.surface?.setBackdrop(image) }
    }

    /// A video frame as an image: a copy, so it doesn't hold one of the decoder's buffers.
    static func image(of frame: CVReadOnlyPixelBuffer) -> CGImage? {
        frame.withUnsafeBuffer { buffer -> CGImage? in
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image else { return nil }
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage()
        }
    }

    /// The pointer moved, or its shape arrived: drawn when it's visible and its shape is known. A position over UDP can
    /// outrun its new shape (which takes the WebSocket): the old shape moves there until the new one arrives.
    func movePointer(to position: CursorPositionMessage?, shapes: [UInt32: PointerShape]) {
        self.position = position ?? self.position
        var pointer: ScreenPointer?
        if let position = self.position, position.visible {
            if let shape = shapes[position.shapeID] ?? self.pointer?.shape {
                pointer = ScreenPointer(shape: shape, x: position.x, y: position.y)
            }
        }
        if self.pointer != pointer { self.pointer = pointer }
    }

    private struct WeakSurface {
        weak var surface: VideoSurface?
    }
}

/// A pointer shape from the hub (`CursorShapeMessage`): its image, and its size and hot spot in the Mac's points.
nonisolated struct PointerShape: Sendable, Equatable {
    var id: UInt32
    var image: UIImage
    var size: CGSize
    var hotSpot: CGPoint
}

/// The Mac's pointer as the phone draws it.
struct ScreenPointer: Equatable {
    var shape: PointerShape
    /// Where its hot spot is, as fractions of the display from its top-left.
    var x: Double
    var y: Double
}
