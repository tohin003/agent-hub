import AVFoundation
import SwiftUI
import UIKit

/// A display's live video: each decoded frame goes straight to an `AVSampleBufferDisplayLayer` and shows at the next
/// screen refresh (no queue). With Smooth or lip-sync a frame instead carries the moment to show it, on the host clock
/// the layer reads timestamps on when it has no control timebase (as here): the layer holds it until then, at no cost
/// to the app. SwiftUI lays it out, zooms and pans it like the image it stands in for: the whole display, whatever
/// part of it a frame shows.
struct VideoSurfaceView: UIViewRepresentable {
    var feed: VideoFeed

    func makeUIView(context: Context) -> VideoSurfaceUIView {
        let view = VideoSurfaceUIView()
        view.attach(to: feed)
        return view
    }

    func updateUIView(_ view: VideoSurfaceUIView, context: Context) {
        view.attach(to: feed)
    }

    static func dismantleUIView(_ view: VideoSurfaceUIView, coordinator: ()) {
        view.detach()
    }
}

/// The view behind `VideoSurfaceView`: the whole display's picture. The display layer covers it, or (while the phone
/// is zoomed in and the hub sends only part of the display) just that part's place in it, over the backdrop: the whole
/// display as it last was.
///
/// The layer moves when the first frame of a new part shows, not when it's queued (`SurfaceSchedule`). Core Animation
/// makes the move on the render server at that moment, on the same host clock the frames are timed on, so frames of
/// the old part still waiting (Smooth, lip-sync) show in the old place, and the new part never shows in it.
final class VideoSurfaceUIView: UIView, VideoSurface {
    private static let moveKey = "move"

    private let display = AVSampleBufferDisplayLayer()
    private let backdrop = CALayer()
    private weak var feed: VideoFeed?
    /// Kept while frames keep their size and format.
    private var format: CMVideoFormatDescription?
    /// The order frames show in, and where the layer is when.
    private var schedule = SurfaceSchedule()
    /// The feed has a backdrop (zoomed in). It stays drawn until the layer covers the whole display again.
    private var wantsBackdrop = false
    private var settleCheck: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backdrop.contentsGravity = .resize
        backdrop.isHidden = true
        layer.addSublayer(backdrop)
        // SwiftUI already gives the view the picture's shape, and a part has the same shape as its place.
        display.videoGravity = .resize
        // The screen may dim and lock as it did with still frames.
        display.preventsDisplaySleepDuringVideoPlayback = false
        layer.addSublayer(display)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func attach(to feed: VideoFeed) {
        guard feed !== self.feed else { return }
        self.feed?.detach(self)
        self.feed = feed
        feed.attach(self)
    }

    func detach() {
        feed?.detach(self)
        feed = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(now: TransportClock.now())
    }

    func setBackdrop(_ image: CGImage?) {
        wantsBackdrop = image != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image { backdrop.contents = image }
        CATransaction.commit()
        updateBackdrop()
    }

    func show(_ frame: CVReadOnlyPixelBuffer, region: ScreenRegion?, at presentationTime: Int64?) {
        let renderer = display.sampleBufferRenderer
        let now = TransportClock.now()
        // The system stops the renderer while the app is in the background, and it fails if decoding resources go
        // away: a flush lets it show frames again.
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
            schedule.flushed(now: now)
            place(now: now)
        }
        let step = schedule.step(region: region, presentationTime: presentationTime, now: now, lead: lead)
        if step.flush { renderer.flush() }
        if step.flush || step.moves {
            place(now: now)
            // The move reaches the render server ahead of the frame's moment.
            CATransaction.flush()
        } else {
            updateBackdrop()
        }
        frame.withUnsafeBuffer { buffer in
            guard let sample = sample(showing: buffer, at: step.show ?? now, immediately: step.show == nil) else { return }
            renderer.enqueue(sample)
        }
    }

    /// How far ahead a frame that moves the layer is timed when it would show at once: a refresh, so the move and the
    /// frame reach the screen together.
    private var lead: Int64 {
        Int64(1_000_000 / Double(max(window?.windowScene?.screen.maximumFramesPerSecond ?? VideoFeed.refreshRate, 1)))
    }

    /// The display layer where it is now, and the moves still to come, each at its moment; the backdrop over the
    /// whole view.
    private func place(now: Int64) {
        schedule.settle(now: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        display.removeAnimation(forKey: Self.moveKey + ".position")
        display.removeAnimation(forKey: Self.moveKey + ".bounds")
        let places = [place(of: schedule.current)] + schedule.moves.map { place(of: $0.region) }
        display.frame = places[places.count - 1]
        if let last = schedule.moves.last {
            // Each earlier place holds until the next move's moment, on the render server; the layer's own frame (the
            // last place) takes over after the last.
            let start = Double(now) / 1e6
            let duration = max(Double(last.at) / 1e6 - start, 0.001)
            let keyTimes = [NSNumber(value: 0)] + schedule.moves.map { NSNumber(value: min(1, max(0, (Double($0.at) / 1e6 - start) / duration))) }
            let held = places.dropLast()
            let animations: [(String, [NSValue])] = [
                ("position", held.map { NSValue(cgPoint: CGPoint(x: $0.midX, y: $0.midY)) }),
                ("bounds", held.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.size)) }),
            ]
            for (keyPath, values) in animations {
                let move = CAKeyframeAnimation(keyPath: keyPath)
                move.calculationMode = .discrete
                move.values = values
                move.keyTimes = keyTimes
                move.beginTime = display.convertTime(start, from: nil)
                move.duration = duration
                move.isRemovedOnCompletion = true
                display.add(move, forKey: Self.moveKey + "." + keyPath)
            }
            // Once the last move has happened: settle, and take the backdrop away if it's no longer wanted.
            settleCheck?.cancel()
            let check = DispatchWorkItem { [weak self] in self?.place(now: TransportClock.now()) }
            settleCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: check)
        }
        CATransaction.commit()
        updateBackdrop()
    }

    /// Where a frame of `region` of the display goes in the view (nil: all of it).
    private func place(of region: ScreenRegion?) -> CGRect {
        guard let region else { return bounds }
        return CGRect(x: bounds.minX + region.x * bounds.width, y: bounds.minY + region.y * bounds.height,
                      width: region.width * bounds.width, height: region.height * bounds.height)
    }

    /// The backdrop shows while it's wanted, or while the layer covers (or is still to cover) only part of the view.
    private func updateBackdrop() {
        let needed = wantsBackdrop || schedule.current != nil || schedule.moves.contains { $0.region != nil }
        guard backdrop.isHidden == needed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.isHidden = !needed
        if !needed { backdrop.contents = nil }
        CATransaction.commit()
    }

    /// The frame as a sample: to show at once, replacing whatever is shown, or at `time` (µs on the host clock).
    private func sample(showing buffer: CVPixelBuffer, at time: Int64, immediately: Bool) -> CMSampleBuffer? {
        let sameAsLast = format.map { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) } ?? false
        if !sameAsLast { format = try? CMVideoFormatDescription(imageBuffer: buffer) }
        guard let format else { return nil }
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: time, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        guard let sample = try? CMSampleBuffer(imageBuffer: buffer, formatDescription: format, sampleTiming: timing) else { return nil }
        if immediately { sample.sampleAttachments[0][.displayImmediately] = true }
        return sample
    }
}
