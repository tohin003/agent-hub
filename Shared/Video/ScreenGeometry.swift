import CoreGraphics
import Foundation

/// Where the live picture sits in the phone's view, and how the view maps to the Mac's display. The view always works
/// in the whole display's coordinates, whatever part of it a video frame shows (`VideoFrameMessage.region`): the picture
/// is fitted into the view (letterboxed), zoomed by `scale` about the view's centre and moved by `offset`.
nonisolated public enum ScreenGeometry {
    /// A picture of `size` fitted inside `container` without cropping: its size there.
    public static func fitted(_ size: CGSize, in container: CGSize) -> CGSize {
        let aspect = size.width / size.height
        return container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
    }

    /// A point in the view on the display (0...1 from its top-left), undoing zoom, pan and the letterboxing; nil off the
    /// picture.
    public static func normalized(_ point: CGPoint, container: CGSize, picture: CGSize, scale: CGFloat,
                                  offset: CGSize) -> CGPoint? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let spot = displayPoint(point, container: container, picture: picture, scale: scale, offset: offset)
        guard (0...1).contains(spot.x), (0...1).contains(spot.y) else { return nil }
        return spot
    }

    /// A point in the view as a point of the display, kept on it: a drag that runs past the picture's edge stays at
    /// the edge.
    public static func clampedNormalized(_ point: CGPoint, container: CGSize, picture: CGSize, scale: CGFloat,
                                         offset: CGSize) -> CGPoint? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let spot = displayPoint(point, container: container, picture: picture, scale: scale, offset: offset)
        return CGPoint(x: min(max(spot.x, 0), 1), y: min(max(spot.y, 0), 1))
    }

    /// A point of the display (0...1 from its top-left) in the view: where the picture shows it.
    public static func viewPoint(_ point: CGPoint, container: CGSize, picture: CGSize, scale: CGFloat,
                                 offset: CGSize) -> CGPoint {
        let fitted = fitted(picture, in: container)
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let spot = CGPoint(x: (container.width - fitted.width) / 2 + point.x * fitted.width,
                           y: (container.height - fitted.height) / 2 + point.y * fitted.height)
        return CGPoint(x: center.x + (spot.x - center.x) * scale + offset.width,
                       y: center.y + (spot.y - center.y) * scale + offset.height)
    }

    /// The part of the display the view shows; nil when that's all of it (or nearly: not zoomed in).
    public static func visibleRegion(container: CGSize, picture: CGSize, scale: CGFloat, offset: CGSize) -> ScreenRegion? {
        guard picture.width > 0, picture.height > 0, container.width > 0, container.height > 0, scale > 1.01 else {
            return nil
        }
        let topLeft = displayPoint(.zero, container: container, picture: picture, scale: scale, offset: offset)
        let bottomRight = displayPoint(CGPoint(x: container.width, y: container.height), container: container,
                                       picture: picture, scale: scale, offset: offset)
        let x0 = max(0, topLeft.x), y0 = max(0, topLeft.y)
        let x1 = min(1, bottomRight.x), y1 = min(1, bottomRight.y)
        guard x1 > x0, y1 > y0 else { return nil }
        let region = ScreenRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return region.isWhole ? nil : region
    }

    /// The part of the display to have the hub capture sharper: what the view shows (`visibleRegion`), unless the whole
    /// display's frames already have a pixel for each of the view's there (`viewScale`: the view's pixels per point), as
    /// a sharper part would look no different. Upright on a 3× iPhone that's up to about 1.6×; on its side, only 1×.
    public static func sharperRegion(container: CGSize, picture: CGSize, scale: CGFloat, offset: CGSize,
                                     viewScale: CGFloat) -> ScreenRegion? {
        guard picture.width > 0, picture.height > 0, container.width > 0, container.height > 0,
              picture.width < fitted(picture, in: container).width * scale * viewScale else { return nil }
        return visibleRegion(container: container, picture: picture, scale: scale, offset: offset)
    }

    /// `normalized` without the bounds check.
    private static func displayPoint(_ point: CGPoint, container: CGSize, picture: CGSize, scale: CGFloat,
                                     offset: CGSize) -> CGPoint {
        let fitted = fitted(picture, in: container)
        let origin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let unpanned = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
        let unscaled = CGPoint(x: center.x + (unpanned.x - center.x) / scale, y: center.y + (unpanned.y - center.y) / scale)
        return CGPoint(x: (unscaled.x - origin.x) / fitted.width, y: (unscaled.y - origin.y) / fitted.height)
    }
}

/// The part of a display the hub captures for a zoomed-in phone (ScreenCaptureKit's `sourceRect`). The frames keep
/// their size, so a switch costs one ordinary frame rather than a new encoder and a keyframe; so the part has the
/// frames' shape. It covers what the phone shows plus a margin for panning, and is never smaller than one frame pixel
/// per display pixel: that's the display's own resolution, and a smaller part would only enlarge pixels on the Mac
/// instead of on the phone.
nonisolated public enum CaptureRegionPlanner {
    /// Around what the phone shows, on each side, as a fraction of its size: a short pan stays sharp, and a longer
    /// one shows the backdrop at the edge until the next part arrives (about 0.3 s).
    public static let margin = 0.1
    /// A part this close to the whole display isn't worth capturing on its own.
    public static let wholeThreshold = 0.95

    /// The part to capture for `visible` (nil: the whole display). `output`: the frames' size in pixels; `display`: the
    /// display's size in pixels.
    public static func region(showing visible: ScreenRegion?, output: CGSize, display: CGSize,
                              margin: Double = margin) -> ScreenRegion? {
        guard let visible, !visible.isWhole, output.width > 0, output.height > 0, display.width > 0, display.height > 0
        else { return nil }
        // A part w × h (fractions of the display) fills a frame unstretched when w·Dw / (h·Dh) = W / H, so h = k·w.
        let k = (display.width * output.height) / (display.height * output.width)
        var width = max(visible.width, visible.height / k) * (1 + 2 * margin)
        width = max(width, output.width / display.width)
        width = min(width, 1, 1 / k)
        let height = width * k
        guard width < wholeThreshold || height < wholeThreshold else { return nil }
        return ScreenRegion(x: min(max(visible.midX - width / 2, 0), 1 - width),
                            y: min(max(visible.midY - height / 2, 0), 1 - height), width: width, height: height)
    }

    /// Whether moving from one part to the other is too small to be worth a switch.
    public static func isClose(_ a: ScreenRegion?, _ b: ScreenRegion?, tolerance: Double = 0.02) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
                && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        default:
            return false
        }
    }
}

/// Where the phone draws the Mac's pointer: at its size on the Mac through the picture's fit and zoom, but never shorter
/// than `minimumHeight` points (on an upright phone the Mac's arrow would be a speck of 4 by 6 points), always with its
/// hot spot exactly on the spot it points at.
nonisolated public enum PointerGeometry {
    public static let minimumHeight: CGFloat = 18

    /// The pointer image's frame in the view. `spot`: where its hot spot goes; `shapeSize` and `hotSpot`: in the Mac's
    /// points; `pointsPerMacPoint`: view points per Mac point, zoom included.
    public static func frame(spot: CGPoint, shapeSize: CGSize, hotSpot: CGPoint, pointsPerMacPoint: CGFloat,
                             minimumHeight: CGFloat = minimumHeight) -> CGRect {
        guard shapeSize.width > 0, shapeSize.height > 0, pointsPerMacPoint > 0 else { return CGRect(origin: spot, size: .zero) }
        let factor = max(pointsPerMacPoint, minimumHeight / shapeSize.height)
        return CGRect(x: spot.x - hotSpot.x * factor, y: spot.y - hotSpot.y * factor,
                      width: shapeSize.width * factor, height: shapeSize.height * factor)
    }
}
