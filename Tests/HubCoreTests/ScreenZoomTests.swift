import CoreGraphics
import Foundation
import Testing

/// Sharp zoom and the pointer: frames that show part of the display, how the phone's view maps to the Mac (upright, on
/// its side, zoomed), which part the hub captures for it, and how big the phone draws the pointer.
@Suite("Screen zoom")
struct ScreenZoomTests {
    /// This MacBook Air: 1470 × 956 points, Retina (2940 × 1912 pixels), streamed at 1920 × 1248.
    static let points = CGSize(width: 1470, height: 956)
    static let pixels = CGSize(width: 2940, height: 1912)
    static let frame = CGSize(width: 1920, height: 1248)
    /// The view the picture sits in: an iPhone 18 Pro upright (the tab's picture area) and on its side (the stage
    /// gives the picture the display's shape at the screen's full height).
    static let upright = CGSize(width: 402, height: 640)
    static let onItsSide = CGSize(width: 402 * 1470.0 / 956, height: 402)

    // MARK: The wire

    @Test func aFrameCarriesItsRegion() throws {
        let region = ScreenRegion(x: 0.125, y: 0.25, width: 0.65, height: 0.6503)
        let frame = VideoFrameMessage(displayID: 1, width: 1920, height: 1248, sequence: 9, captureTime: 12.5, codec: .hevc,
                                      flags: [.refresh], ltrToken: 3, parameterSets: [Data([0x40, 1]), Data([0x42, 1])],
                                      region: region, data: Data([0, 0, 0, 2, 0x26, 1]))
        let bytes = frame.encoded()
        #expect(bytes[22] & VideoFrameMessage.Flags.region.rawValue != 0)
        let parsed = try #require(VideoFrameMessage.parse(bytes))
        #expect(parsed.parameterSets == frame.parameterSets && parsed.data == frame.data && parsed.flags == [.refresh])
        let back = try #require(parsed.region)
        for (a, b) in [(back.x, region.x), (back.y, region.y), (back.width, region.width), (back.height, region.height)] {
            #expect(abs(a - b) < 1e-6, "Float32 on the wire: \(a) for \(b)")
        }
    }

    /// Frames of the whole display are byte for byte what phones from before regions read.
    @Test func aWholeFrameIsUnchanged() throws {
        let data = Data([0, 0, 0, 2, 0x26, 1])
        let plain = VideoFrameMessage(displayID: 1, width: 1920, height: 1248, sequence: 9, captureTime: 1, codec: .hevc,
                                      flags: [], data: data)
        let whole = VideoFrameMessage(displayID: 1, width: 1920, height: 1248, sequence: 9, captureTime: 1, codec: .hevc,
                                      flags: [], region: ScreenRegion(x: 0, y: 0, width: 0.999, height: 1), data: data)
        #expect(whole.region == nil, "a region covering the display is the whole display")
        #expect(whole.encoded() == plain.encoded())
        #expect(plain.encoded().count == VideoFrameMessage.headerSize + data.count)
        #expect(VideoFrameMessage.parse(plain.encoded())?.region == nil)
    }

    // MARK: The phone's view

    /// A tap goes to the Mac point under the finger, zoomed and panned, upright and on its side: checked against the
    /// picture's own layout worked out by hand, then in Retina pixels.
    @Test(arguments: [(Self.upright, "upright"), (Self.onItsSide, "on its side")])
    func tapsMapToTheMacZoomedIn(container: CGSize, name: String) throws {
        let scale: CGFloat = 3
        let offset = CGSize(width: 37, height: -21)
        let fitted = ScreenGeometry.fitted(Self.frame, in: container)
        // Where the Mac point (900, 300) is drawn: in the fitted picture, then zoomed about the view's centre and panned.
        let mac = CGPoint(x: 900, y: 300)
        let inPicture = CGPoint(x: (container.width - fitted.width) / 2 + mac.x / Self.points.width * fitted.width,
                                y: (container.height - fitted.height) / 2 + mac.y / Self.points.height * fitted.height)
        let finger = CGPoint(x: container.width / 2 + (inPicture.x - container.width / 2) * scale + offset.width,
                             y: container.height / 2 + (inPicture.y - container.height / 2) * scale + offset.height)
        let hit = try #require(ScreenGeometry.normalized(finger, container: container, picture: Self.frame, scale: scale,
                                                         offset: offset))
        #expect(abs(hit.x * Self.points.width - mac.x) < 1e-9 && abs(hit.y * Self.points.height - mac.y) < 1e-9, "\(name): \(hit)")
        // And in the display's own pixels, as the Mac's input injection works in points: 2 pixels a point.
        #expect(abs(hit.x * Self.pixels.width - 1800) < 1e-6 && abs(hit.y * Self.pixels.height - 600) < 1e-6)
        // The pointer drawn at that point lands under the same finger.
        let drawn = ScreenGeometry.viewPoint(hit, container: container, picture: Self.frame, scale: scale, offset: offset)
        #expect(abs(drawn.x - finger.x) < 1e-9 && abs(drawn.y - finger.y) < 1e-9)
    }

    @Test func aTapOffThePictureGoesNowhere() {
        // Upright, the picture is letterboxed: the black above it isn't the Mac.
        #expect(ScreenGeometry.normalized(CGPoint(x: 200, y: 5), container: Self.upright, picture: Self.frame, scale: 1,
                                          offset: .zero) == nil)
    }

    /// A frame of part of the display is drawn exactly where the whole display's picture has that part, so a tap on it
    /// hits the Mac point it shows.
    @Test func aRegionFrameSitsWhereItsPartIs() throws {
        let region = ScreenRegion(x: 0.2, y: 0.3, width: 0.653, height: 0.653)
        let container = Self.onItsSide, scale: CGFloat = 2, offset = CGSize(width: -40, height: 25)
        let fitted = ScreenGeometry.fitted(Self.frame, in: container)
        // The surface lays the region over (x, y) of the fitted picture's own bounds, as `VideoSurfaceUIView` does.
        let surfaceOrigin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)
        let pixelInRegion = CGPoint(x: 0.5, y: 0.25)   // a point of the frame, as fractions of it
        let unzoomed = CGPoint(x: surfaceOrigin.x + (region.x + pixelInRegion.x * region.width) * fitted.width,
                               y: surfaceOrigin.y + (region.y + pixelInRegion.y * region.height) * fitted.height)
        let onScreen = CGPoint(x: container.width / 2 + (unzoomed.x - container.width / 2) * scale + offset.width,
                               y: container.height / 2 + (unzoomed.y - container.height / 2) * scale + offset.height)
        let hit = try #require(ScreenGeometry.normalized(onScreen, container: container, picture: Self.frame, scale: scale,
                                                         offset: offset))
        #expect(abs(hit.x - (region.x + pixelInRegion.x * region.width)) < 1e-9)
        #expect(abs(hit.y - (region.y + pixelInRegion.y * region.height)) < 1e-9)
    }

    @Test func whatTheViewShows() throws {
        #expect(ScreenGeometry.visibleRegion(container: Self.onItsSide, picture: Self.frame, scale: 1, offset: .zero) == nil)
        let centred = try #require(ScreenGeometry.visibleRegion(container: Self.onItsSide, picture: Self.frame, scale: 2,
                                                                offset: .zero))
        // On its side the picture fills the stage: twice the zoom shows the middle half each way.
        #expect(abs(centred.width - 0.5) < 0.01 && abs(centred.height - 0.5) < 0.01 && abs(centred.midX - 0.5) < 0.01)
        // Upright the view is taller than the picture: it shows a tall strip of it.
        let tall = try #require(ScreenGeometry.visibleRegion(container: Self.upright, picture: Self.frame, scale: 3,
                                                             offset: .zero))
        #expect(abs(tall.width - 1 / 3) < 0.01 && tall.height > 0.8, "\(tall)")
        // Panned to the right edge: the part ends at the display's edge.
        let fitted = ScreenGeometry.fitted(Self.frame, in: Self.onItsSide)
        let edge = try #require(ScreenGeometry.visibleRegion(container: Self.onItsSide, picture: Self.frame, scale: 2,
                                                             offset: CGSize(width: -fitted.width / 2, height: 0)))
        #expect(abs(edge.x + edge.width - 1) < 0.01)
    }

    /// Upright, the whole display's frames have more pixels than the view up to about 1.6×, so the phone asks for no
    /// sharper part until then; on its side they have about as many at 1×, so a zoom asks for one at once.
    @Test func thePhoneAsksForASharperPartOnlyWhereItShows() {
        func asks(_ container: CGSize, _ scale: CGFloat, viewScale: CGFloat = 3) -> Bool {
            ScreenGeometry.sharperRegion(container: container, picture: Self.frame, scale: scale, offset: .zero,
                                         viewScale: viewScale) != nil
        }
        #expect(!asks(Self.upright, 1.5))
        #expect(asks(Self.upright, 1.7))
        #expect(asks(Self.upright, 3))
        #expect(!asks(Self.onItsSide, 1))
        #expect(asks(Self.onItsSide, 1.1))
        // A 2× iPhone upright: up to about 2.4×.
        #expect(!asks(Self.upright, 2.3, viewScale: 2))
        #expect(asks(Self.upright, 2.5, viewScale: 2))
    }

    // MARK: What the hub captures

    @Test func theCapturedPartCoversTheViewAtTheDisplaysOwnResolution() throws {
        // On its side at 2×: half the display each way, plus the margin, but no smaller than 1920 / 2940 of it.
        let visible = ScreenRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let part = try #require(CaptureRegionPlanner.region(showing: visible, output: Self.frame, display: Self.pixels))
        #expect(abs(part.width - 1920.0 / 2940) < 1e-9, "one frame pixel per display pixel: \(part)")
        // The frame's shape, so nothing stretches: width·2940 / (height·1912) = 1920 / 1248.
        #expect(abs(part.width * 2940 / (part.height * 1912) - 1920.0 / 1248) < 1e-9)
        #expect(part.x <= visible.x && part.y <= visible.y && part.x + part.width >= visible.x + visible.width
            && part.y + part.height >= visible.y + visible.height, "it covers what the phone shows")
        #expect(abs(part.midX - 0.5) < 1e-9 && abs(part.midY - 0.5) < 1e-9)
        // Zoomed in further, the part stays at the display's own resolution: the phone enlarges it.
        let deep = try #require(CaptureRegionPlanner.region(showing: ScreenRegion(x: 0.7, y: 0.7, width: 0.15, height: 0.15),
                                                            output: Self.frame, display: Self.pixels))
        #expect(abs(deep.width - 1920.0 / 2940) < 1e-9)
        #expect(deep.x + deep.width <= 1 + 1e-12 && deep.y + deep.height <= 1 + 1e-12, "kept on the display: \(deep)")
        // A little zoom: a part with the margin, sharper than the whole display.
        let mild = try #require(CaptureRegionPlanner.region(showing: ScreenRegion(x: 0.15, y: 0.15, width: 0.7, height: 0.7),
                                                            output: Self.frame, display: Self.pixels))
        #expect(abs(mild.width - 0.84) < 0.001, "\(mild)")
    }

    @Test func nearlyAllOfItIsTheWholeDisplay() {
        // Upright at 3× the view is a tall strip: with the margin it needs the display's whole height.
        #expect(CaptureRegionPlanner.region(showing: ScreenRegion(x: 0.33, y: 0.08, width: 0.33, height: 0.84),
                                            output: Self.frame, display: Self.pixels) == nil)
        #expect(CaptureRegionPlanner.region(showing: nil, output: Self.frame, display: Self.pixels) == nil)
        #expect(CaptureRegionPlanner.region(showing: .whole, output: Self.frame, display: Self.pixels) == nil)
    }

    @Test func smallMovesDontSwitch() {
        let a = ScreenRegion(x: 0.2, y: 0.2, width: 0.653, height: 0.653)
        #expect(CaptureRegionPlanner.isClose(a, ScreenRegion(x: 0.21, y: 0.195, width: 0.653, height: 0.653)))
        #expect(!CaptureRegionPlanner.isClose(a, ScreenRegion(x: 0.25, y: 0.2, width: 0.653, height: 0.653)))
        #expect(!CaptureRegionPlanner.isClose(a, nil) && CaptureRegionPlanner.isClose(nil, nil))
    }

    // MARK: The pointer

    @Test func thePointerIsNeverASpeck() {
        // Upright, a Mac point is 402 / 1470 of a view point: the 17 × 23 arrow would be 4.6 × 6.3.
        let spot = CGPoint(x: 120, y: 300)
        let small = PointerGeometry.frame(spot: spot, shapeSize: CGSize(width: 17, height: 23), hotSpot: CGPoint(x: 4, y: 3),
                                          pointsPerMacPoint: 402.0 / 1470)
        #expect(abs(small.height - PointerGeometry.minimumHeight) < 1e-9)
        #expect(abs(small.width - 17 * PointerGeometry.minimumHeight / 23) < 1e-9, "its shape kept")
        let factor = small.height / 23
        #expect(abs(small.minX + 4 * factor - spot.x) < 1e-9 && abs(small.minY + 3 * factor - spot.y) < 1e-9,
                "the hot spot exactly on the spot")
        // Zoomed in far enough, it's drawn at its size on the Mac.
        let zoomed = PointerGeometry.frame(spot: spot, shapeSize: CGSize(width: 17, height: 23), hotSpot: CGPoint(x: 4, y: 3),
                                           pointsPerMacPoint: 402.0 / 1470 * 5)
        #expect(abs(zoomed.height - 23 * 402.0 / 1470 * 5) < 1e-9)
        #expect(abs(zoomed.minX + 4 * 402.0 / 1470 * 5 - spot.x) < 1e-9)
    }
}
