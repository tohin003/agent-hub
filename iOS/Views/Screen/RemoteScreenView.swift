import SwiftUI
import UIKit

/// One display's picture with the gestures that drive the Mac, as on a trackpad:
/// - tap: a click, at once (a quick second tap makes it a double click);
/// - double-tap and drag, or double-tap and hold then drag: a drag with the Mac's mouse (a file, a window, a selection);
/// - touch and hold (a ring fills under your finger) or tap with two fingers: a right-click;
/// - pinch: zoom, in scroll mode too; two fingers move the zoomed picture, and so does a drag outside scroll mode;
/// - drag in scroll mode: scrolls the Mac;
/// - the thin bar along the right edge (unless `showsRail` is off): scrolls the Mac in any mode.
struct RemoteScreenView: View {
    var image: UIImage?
    var live: Bool
    var displayId: UInt32
    var scrollMode: Bool
    /// The scroll bar along the right edge. Off in landscape: the whole picture takes taps, and Drag to Scroll scrolls.
    var showsRail = true
    @Binding var zoomed: Bool
    /// The display's video and pointer: once a video frame has decoded, it shows in place of `image`.
    var video: VideoFeed? = nil
    /// The display's width in points (`DisplayInfo.width`), to draw the Mac's pointer at its size there.
    var displayWidth: Double? = nil
    /// The part of the display the view shows once a zoom or a pan settles (nil: all of it), for the hub to capture
    /// sharper. The view itself always works in the whole display's coordinates, whatever part a frame shows.
    var onViewport: ((ScreenRegion?) -> Void)? = nil
    /// Shown dimmed, as a Space to swipe to (nil: when not live). The Space a switch is on its way to isn't: it shows
    /// its snapshot as it is, while taps wait for the Mac to get there.
    var dimmed: Bool? = nil
    var onInput: (ScreenInputParams) -> Void

    /// How long a still finger takes to right-click; long enough that a slow tap is still a click.
    static let holdDuration = 0.7
    /// The strip along the right edge where a vertical drag scrolls (a tap there is still a click).
    static let railWidth: CGFloat = 30

    @State private var scale = 1.0
    @Environment(\.displayScale) private var displayScale
    @State private var offset = CGSize.zero
    @State private var ripple: Ripple?
    @State private var hold: CGPoint?
    @State private var holdProgress = 0.0
    /// The last click: a quick second one nearby is its double click.
    @State private var lastClick: (at: Date, point: CGPoint, count: Int)?
    /// Where the scroll bar scrolls: the last place clicked (0...1 on the display).
    @State private var anchor: CGPoint?
    @State private var pendingScroll = CGSize.zero
    @State private var railScroll: CGFloat = 0
    @State private var thumb: CGFloat = 0
    @State private var railActive = false
    @State private var rightClicks = 0
    /// A double-tap and drag under way: where the finger is (the cue), where on the display the pointer went, and when a
    /// move last went to the Mac.
    @State private var carrying: CGPoint?
    @State private var carryTarget: CGPoint?
    @State private var carrySent = Date.distantPast
    @State private var carryFlushQueued = false
    @State private var pickUps = 0
    /// A double tap's second touch resting: where, and how full the ring is (it's full when it picks up).
    @State private var pickUpRing: CGPoint?
    @State private var pickUpProgress = 0.0
    @State private var drops = 0

    struct Ripple: Equatable {
        var point: CGPoint
        var right: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            ZStack {
                Color.black.opacity(0.92)
                if let video, let size = video.size {
                    VideoSurfaceView(feed: video)
                        .aspectRatio(size, contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .opacity(dimmed ?? !live ? 0.55 : 1)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .opacity(dimmed ?? !live ? 0.55 : 1)
                } else {
                    ProgressView().tint(.white)
                }
                if live, let video, let displayWidth, let pictureSize {
                    PointerOverlay(feed: video, picture: pictureSize, displayWidth: displayWidth, container: container,
                                   scale: scale, offset: offset)
                }
                if let hold {
                    HoldRing(progress: holdProgress)
                        .position(hold)
                        .transition(.opacity)
                }
                if let ripple {
                    RippleMark(right: ripple.right)
                        .position(ripple.point)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
                if let pickUpRing {
                    PickUpRing(progress: pickUpProgress)
                        .position(pickUpRing)
                        .transition(.opacity)
                }
                if let carrying {
                    CarryMark()
                        .position(carrying)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .overlay {
                ScreenTouchSurface(scrollMode: scrollMode, zoomed: scale > 1.01, railWidth: showsRail ? Self.railWidth : 0,
                                   holdDuration: Self.holdDuration, carries: live && pictureSize != nil) { event in
                    handle(event, container: container)
                }
            }
            .overlay(alignment: .trailing) {
                if showsRail, live, pictureSize != nil {
                    ScrollRail(thumb: thumb, active: railActive, width: Self.railWidth)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement()
            .accessibilityIdentifier("remoteScreen")
            .accessibilityLabel("Your Mac's screen")
            .accessibilityHint(showsRail
                ? "Tap to click. Touch and hold, or tap with two fingers, to right-click. Double-tap and drag, or double-tap and hold until the ring fills, to drag as with a mouse. Drag along the right edge to scroll."
                : "Tap to click. Touch and hold, or tap with two fingers, to right-click. Double-tap and drag, or double-tap and hold until the ring fills, to drag as with a mouse. Turn on Drag to Scroll to scroll.")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAction(named: "Scroll Up") { scrollMac(by: 300, container: container) }
            .accessibilityAction(named: "Scroll Down") { scrollMac(by: -300, container: container) }
            // A new view (a turn re-creates it) starts on the whole display.
            .onAppear { onViewport?(nil) }
            // A page that comes live, or stops being live, starts whole again: the new Space shows all of the Mac's
            // display, and the tab hears the zoom is off (zoomed in when the Mac switched by itself, it would otherwise
            // still think so, the pager held and the tab bar hidden). The page that came live then says what it shows,
            // the whole display, so the hub doesn't keep capturing the part the last one showed.
            .onChange(of: live) { _, isLive in
                if scale != 1 || offset != .zero {
                    scale = 1
                    offset = .zero
                }
                guard isLive else { return }
                onViewport?(nil)
            }
        }
        .clipped()
        // The scroll bar runs along the right edge, where the system otherwise holds back a drag in case it's one
        // of its own edge swipes (none starts there on an iPhone held upright).
        .defersSystemGestures(on: .trailing)
        .onChange(of: scale) { _, new in zoomed = new > 1.01 }
        .sensoryFeedback(.impact(weight: .medium), trigger: rightClicks)
        // Picked up, and dropped.
        // Heavier than a right-click's, so a pick-up is never taken for one.
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: pickUps)
        .sensoryFeedback(.impact(weight: .light), trigger: drops)
        // A finger held still keeps the drag: the hub lets go of one that goes quiet (`MouseDragSession.idleLimit`).
        .task(id: carrying != nil) {
            while carrying != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if carrying != nil, let carryTarget, Date.now.timeIntervalSince(carrySent) >= 0.9 {
                    sendCarry(.dragMove, at: carryTarget)
                }
            }
        }
        // Gone mid-drag (the phone turned, or the Space stopped being live): the Mac's button comes up.
        .onDisappear { endCarry(at: nil) }
    }

    /// The picture's size in pixels: the video frame's while there is one, else the image's.
    private var pictureSize: CGSize? {
        if let size = video?.size { return size }
        return image?.size
    }

    // MARK: Gestures

    private func handle(_ event: ScreenTouchSurface.Event, container: CGSize) {
        switch event {
        case .holdBegan(let point):
            guard live, normalized(point, container: container) != nil else { return }
            hold = point
            holdProgress = 0
            withAnimation(.linear(duration: Self.holdDuration - ScreenTouchSurface.ringDelay)) { holdProgress = 1 }
        case .holdEnded:
            withAnimation(.easeOut(duration: 0.15)) { hold = nil }
        case .tap(let point):
            click(at: point, container: container)
        case .doubleTap(let point):
            click(at: point, container: container, second: true)
        case .carry(let point, let phase, let pickedUp):
            carry(point, phase: phase, pickedUp: pickedUp, container: container)
        case .pickUpBegan(let point, let remaining):
            guard live, normalized(point, container: container) != nil else { return }
            pickUpRing = point
            pickUpProgress = 0
            withAnimation(.linear(duration: remaining)) { pickUpProgress = 1 }
        case .pickUpEnded:
            withAnimation(.easeOut(duration: 0.12)) { pickUpRing = nil }
        case .rightClick(let point):
            withAnimation(.easeOut(duration: 0.15)) { hold = nil }
            guard live, let target = normalized(point, container: container) else { return }
            anchor = target
            rightClicks += 1
            showRipple(at: point, right: true)
            onInput(ScreenInputParams(displayId: displayId, action: .rightClick, x: target.x, y: target.y))
        case .pinch(let factor, let center, let moved, let phase):
            zoom(by: factor, around: center, moved: moved, container: container)
            if phase == .ended { settle(container) }
        case .drag(let delta, let start, let phase):
            if scrollMode {
                scroll(delta, at: start, ended: phase == .ended, container: container)
            } else {
                offset.width += delta.width
                offset.height += delta.height
                if phase == .ended { settle(container) }
            }
        case .rail(let delta, let velocity, let phase):
            rail(delta, velocity: velocity, phase: phase, container: container)
        }
    }

    /// Double-tap and drag (or hold, then drag): the Mac's button goes down where the second touch landed (click state 1:
    /// a file picked up in Finder isn't opened), the pointer follows the finger (at most once a frame, the latest always)
    /// and the button comes up where it lifts. Past the picture's edge it stays at the edge.
    private func carry(_ point: CGPoint, phase: ScreenTouchSurface.Phase, pickedUp: Bool = false, container: CGSize) {
        let target = pictureSize.flatMap {
            ScreenGeometry.clampedNormalized(point, container: container, picture: $0, scale: scale, offset: offset)
        }
        switch phase {
        case .began:
            // It starts on the picture (a double tap in the black beside it drags nothing); past the picture's edge
            // afterwards, the pointer stays at the edge.
            guard live, normalized(point, container: container) != nil, let target else { return }
            // The carry ring takes the pick-up ring's place.
            pickUpRing = nil
            withAnimation(.easeOut(duration: 0.12)) { carrying = point }
            carryTarget = target
            anchor = target
            pickUps += 1
            sendCarry(.dragStart, at: target, pickedUp: pickedUp)
        case .changed:
            guard carrying != nil, let target else { return }
            carrying = point
            carryTarget = target
            let wait = 1.0 / 60 - Date.now.timeIntervalSince(carrySent)
            if wait <= 0 {
                sendCarry(.dragMove, at: target)
            } else if !carryFlushQueued {
                carryFlushQueued = true
                Task {
                    try? await Task.sleep(for: .seconds(wait))
                    carryFlushQueued = false
                    if carrying != nil, let carryTarget { sendCarry(.dragMove, at: carryTarget) }
                }
            }
        case .ended:
            endCarry(at: target)
        }
    }

    /// The drop: where the finger lifted (nil: where the pointer is).
    private func endCarry(at target: CGPoint?) {
        guard carrying != nil, let spot = target ?? carryTarget else { return }
        withAnimation(.easeOut(duration: 0.2)) { carrying = nil }
        carryTarget = nil
        anchor = spot
        drops += 1
        sendCarry(.dragEnd, at: spot)
    }

    /// `pickedUp`: for a start, whether a hold picked it up (for the hub's log).
    private func sendCarry(_ action: ScreenInputParams.Action, at target: CGPoint, pickedUp: Bool? = nil) {
        carrySent = .now
        onInput(ScreenInputParams(displayId: displayId, action: action, x: target.x, y: target.y, pickedUp: pickedUp))
    }

    /// A click at once; a quick second tap near the first is the second click of a double click, sent as a mouse
    /// sends it, so nothing waits to see whether a second tap comes. `second`: a double tap's second touch, lifted
    /// without moving: the double click however long it stayed down.
    private func click(at point: CGPoint, container: CGSize, second: Bool = false) {
        guard live, let target = normalized(point, container: container) else { return }
        var count = 1
        if let last = lastClick, second || Date.now.timeIntervalSince(last.at) < ScreenTouchSurface.doubleTapWindow,
           hypot(point.x - last.point.x, point.y - last.point.y) < ScreenTouchSurface.doubleTapReach {
            count = min(last.count + 1, 3)
        }
        lastClick = (.now, point, count)
        anchor = target
        showRipple(at: point, right: false)
        onInput(ScreenInputParams(displayId: displayId, action: .click, x: target.x, y: target.y, clickCount: count))
    }

    private func showRipple(at point: CGPoint, right: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { ripple = Ripple(point: point, right: right) }
        Task {
            try? await Task.sleep(for: .milliseconds(right ? 500 : 350))
            withAnimation(.easeOut(duration: 0.25)) { ripple = nil }
        }
    }

    /// Zooms by `factor` keeping the spot under the fingers where it is, and moves the picture with them.
    private func zoom(by factor: CGFloat, around center: CGPoint, moved: CGSize, container: CGSize) {
        let newScale = min(6, max(1, scale * factor))
        let ratio = newScale / scale
        let mid = CGPoint(x: container.width / 2, y: container.height / 2)
        offset = CGSize(width: center.x - mid.x - (center.x - mid.x - offset.width) * ratio + moved.width,
                        height: center.y - mid.y - (center.y - mid.y - offset.height) * ratio + moved.height)
        scale = newScale
    }

    /// Back to the whole screen at 1×; otherwise keeps the zoomed picture covering the view. Then the hub hears what the
    /// view shows.
    private func settle(_ container: CGSize) {
        guard let pictureSize else { return }
        let fitted = Self.fitted(pictureSize, in: container)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        withAnimation(.snappy) {
            if scale <= 1.01 {
                scale = 1
                offset = .zero
            } else {
                offset = CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
            }
        }
        if live {
            onViewport?(ScreenGeometry.sharperRegion(container: container, picture: pictureSize, scale: scale, offset: offset,
                                                     viewScale: displayScale))
        }
    }

    /// Scroll mode: the content follows the finger (finer when zoomed in), where the drag began.
    private func scroll(_ delta: CGSize, at start: CGPoint, ended: Bool, container: CGSize) {
        pendingScroll.width += delta.width
        pendingScroll.height += delta.height
        defer { if ended { pendingScroll = .zero } }
        guard abs(pendingScroll.width) + abs(pendingScroll.height) > 6, let target = normalized(start, container: container) else { return }
        anchor = target
        onInput(ScreenInputParams(displayId: displayId, action: .scroll, x: target.x, y: target.y,
                                  dx: pendingScroll.width * 2 / scale, dy: pendingScroll.height * 2 / scale))
        pendingScroll = .zero
    }

    /// The scroll bar: the thumb follows the finger, the Mac scrolls the same way (down shows what's below), further
    /// for a fast drag; let go and the thumb settles back.
    private func rail(_ delta: CGFloat, velocity: CGFloat, phase: ScreenTouchSurface.Phase, container: CGSize) {
        switch phase {
        case .began:
            railActive = true
        case .changed:
            break
        case .ended:
            railActive = false
            railScroll = 0
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { thumb = 0 }
            return
        }
        let travel = max(0, container.height / 2 - 60)
        thumb = min(max(thumb + delta, -travel), travel)
        railScroll += delta * (4 + min(abs(velocity) / 250, 14))
        guard abs(railScroll) >= 4 else { return }
        scrollMac(by: -railScroll, container: container)
        railScroll = 0
    }

    /// Scrolls the Mac where you last clicked (or the middle of what's on screen); positive shows what's above.
    private func scrollMac(by amount: Double, container: CGSize) {
        guard live, let target = anchor ?? normalized(CGPoint(x: container.width / 2, y: container.height / 2), container: container) else { return }
        onInput(ScreenInputParams(displayId: displayId, action: .scroll, x: target.x, y: target.y, dx: 0, dy: amount))
    }

    fileprivate static func fitted(_ size: CGSize, in container: CGSize) -> CGSize {
        ScreenGeometry.fitted(size, in: container)
    }

    /// Maps a point in the view to 0...1 on the Mac's display, undoing zoom, pan and the letterboxing.
    private func normalized(_ point: CGPoint, container: CGSize) -> CGPoint? {
        guard let pictureSize else { return nil }
        return ScreenGeometry.normalized(point, container: container, picture: pictureSize, scale: scale, offset: offset)
    }
}

/// The Mac's pointer, drawn here because the hub leaves it out of the picture, so it moves as soon as its position
/// arrives: at its spot on the display through the same fit, zoom and pan as the picture, at its size on the Mac but
/// never shorter than `PointerGeometry.minimumHeight`, its hot spot exactly on the spot. Only this view redraws as it
/// moves.
private struct PointerOverlay: View {
    var feed: VideoFeed
    /// The picture's size in pixels.
    var picture: CGSize
    /// The display's width in points.
    var displayWidth: Double
    var container: CGSize
    var scale: CGFloat
    var offset: CGSize

    var body: some View {
        if let pointer = feed.pointer, picture.width > 0, picture.height > 0, displayWidth > 0 {
            // View points per Mac point, zoom included.
            let points = RemoteScreenView.fitted(picture, in: container).width / displayWidth * scale
            let spot = ScreenGeometry.viewPoint(CGPoint(x: pointer.x, y: pointer.y), container: container, picture: picture,
                                                scale: scale, offset: offset)
            let frame = PointerGeometry.frame(spot: spot, shapeSize: pointer.shape.size, hotSpot: pointer.shape.hotSpot,
                                              pointsPerMacPoint: points)
            Image(uiImage: pointer.shape.image)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The ring that fills while a finger is held still: full means a right-click.
private struct HoldRing: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 48, height: 48)
        .allowsHitTesting(false)
    }
}

#if DEBUG
/// The touch surface's view, noting each touch it gets, beside the recognizers' view of them (for the gesture trace).
private final class TracedTouchView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        GestureTrace.shared.note("touch down")
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        GestureTrace.shared.note("touch up")
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        GestureTrace.shared.note("touch cancelled")
        super.touchesCancelled(touches, with: event)
    }
}

/// The touch surface's last few decisions (a double tap's second touch, a pick-up, a right-click…), for the layout
/// harness's readout and its UI tests.
@MainActor
final class GestureTrace {
    static let shared = GestureTrace()
    private(set) var notes: [String] = []
    /// Drags a still hold picked up, and drags the move started.
    var pickedUpByHolding = 0
    var startedByMoving = 0

    func note(_ event: String) {
        notes = Array((notes + [event]).suffix(14))
    }
}
#endif

/// A double tap's second touch resting: a ring that fills until it picks up what's under it. It's the carry ring's
/// size, larger than a right-click's, so the two holds look different as well as feel different.
private struct PickUpRing: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 60, height: 60)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a double-tap and drag holds the Mac's mouse button: a ring around the finger, big enough to show past it, for
/// as long as the button is down.
private struct CarryMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.25))
            Circle().stroke(Color.accentColor, lineWidth: 3)
            Circle().stroke(.white.opacity(0.7), lineWidth: 1).padding(3)
        }
        .frame(width: 60, height: 60)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a click landed: a ring, filled for a right-click.
private struct RippleMark: View {
    var right: Bool

    var body: some View {
        ZStack {
            if right { Circle().fill(Color.accentColor.opacity(0.35)) }
            Circle().stroke(Color.accentColor, lineWidth: 3)
        }
        .frame(width: right ? 42 : 34, height: right ? 42 : 34)
        .allowsHitTesting(false)
    }
}

/// The thin scroll bar along the right edge. It drives scrolling rather than showing a position (the Mac doesn't
/// say how long the page is): the thumb follows your finger and settles back to the middle.
private struct ScrollRail: View {
    var thumb: CGFloat
    var active: Bool
    var width: CGFloat

    var body: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(active ? 0.24 : 0.12))
                .frame(width: 3)
            Capsule()
                .fill(.white.opacity(active ? 0.9 : 0.5))
                .frame(width: active ? 6 : 4, height: 56)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .offset(y: thumb)
        }
        .padding(.vertical, 28)
        .frame(width: width)
        .animation(.snappy(duration: 0.2), value: active)
        .accessibilityHidden(true)
    }
}

/// The touch layer over the Mac's screen. Everything is a UIKit gesture recognizer: recognizers see each finger land
/// and lift as it happens, whatever the Spaces pager around them does with the view's own touch calls (it holds those
/// back while it decides whether a touch is a swipe). One finger is timed by a recognizer that begins as it lands
/// (lifted early it's a click, held still it's a right-click); others take the pinch, the two-finger tap, the drags
/// and the scroll bar.
private struct ScreenTouchSurface: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    enum Event {
        /// A finger has been still a moment: the right-click ring starts filling.
        case holdBegan(CGPoint)
        case holdEnded
        case tap(CGPoint)
        case rightClick(CGPoint)
        /// `factor` since the last event, around `center`; `moved` is how far the fingers moved together.
        case pinch(factor: CGFloat, center: CGPoint, moved: CGSize, phase: Phase)
        /// One finger: movement since the last event, and where it began.
        case drag(delta: CGSize, start: CGPoint, phase: Phase)
        /// A vertical drag along the right edge.
        case rail(delta: CGFloat, velocity: CGFloat, phase: Phase)
        /// A double tap's second touch, lifted without moving (however long it stayed down): the double click.
        case doubleTap(CGPoint)
        /// A double tap's second touch that moved, or rested for `pickUpDelay` (`pickedUp`): a drag with the Mac's mouse.
        case carry(point: CGPoint, phase: Phase, pickedUp: Bool = false)
        /// A double tap's second touch has rested a moment: the pick-up ring fills until it picks up, and goes when it
        /// picks up, or when the finger moves or lifts first.
        case pickUpBegan(CGPoint, remaining: TimeInterval)
        case pickUpEnded
    }

    /// A touch this soon after a tap, and this near it, is that tap's second: a double tap. The gesture harness can
    /// lengthen the window for XCUITest, whose gestures come slower than a hand's (`-screenGestureDoubleTapWindow 5`).
    static let doubleTapWindow: TimeInterval = {
        #if DEBUG
        let asked = UserDefaults.standard.double(forKey: "screenGestureDoubleTapWindow")
        if asked > 0 { return asked }
        #endif
        return 0.4
    }()
    static let doubleTapReach: CGFloat = 30
    /// How far a double tap's second touch moves before it drags: as far as a tap may wobble and still click.
    static let carrySlop: CGFloat = 10
    /// How long a double tap's second touch rests before it picks up: iOS's own touch and hold. (A right-click waits
    /// longer, so that a slow tap is still a click; a second touch never right-clicks, so it needn't.)
    static let pickUpDelay = 0.5
    /// When the pick-up ring shows: a quick double tap never sees it.
    static let pickUpRingDelay = 0.12

    /// The ring shows after this long (a tap never sees it).
    static let ringDelay = 0.22

    var scrollMode: Bool
    var zoomed: Bool
    var railWidth: CGFloat
    var holdDuration: Double
    /// Whether a double tap's second touch drags (the picture is live); otherwise it's a touch like any other.
    var carries = false
    var onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        #if DEBUG
        let view = TracedTouchView()
        #else
        let view = UIView()
        #endif
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.surfaceGone()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: ScreenTouchSurface
        /// The finger being timed: where it landed, and whether it has already right-clicked.
        private var pressing: (start: CGPoint, handled: Bool)?
        private var ringShown = false
        private var timers: [Task<Void, Never>] = []
        private var pinchCenter: CGPoint?
        private var pinchTouches = 0
        private var pinching = false
        private var dragStart = CGPoint.zero
        /// Where the finger landed. Which way a drag goes is judged from here, never from its speed, and its movement
        /// is measured from here, never by the pan's own translation: a quick drag can reach the recognizers all at
        /// once, with no speed yet, and a pan's translation starts at zero when it begins, which would lose all of it.
        private var touchDown: CGPoint?
        /// Where the dragging finger was at the last event (on the picture, and on the scroll bar).
        private var dragLast = CGPoint.zero
        private var railLast: CGFloat = 0
        private weak var pressRecognizer: UILongPressGestureRecognizer?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        private weak var dragRecognizer: UIPanGestureRecognizer?
        private weak var railRecognizer: UIPanGestureRecognizer?
        /// The last tap (a click): where, and when it lifted (system uptime), for a double tap's second touch.
        private var lastTap: (point: CGPoint, at: TimeInterval)?
        /// When the finger now down landed, by the touch's own time: a busy phone may handle it late, which mustn't
        /// stretch the gap after a tap past the double-tap window.
        private var touchDownTime: TimeInterval?
        private var pickUpRingShown = false
        /// A double tap's second touch: where it landed, and whether it drags yet.
        private var second: (start: CGPoint, carrying: Bool)?
        private var pickUp: Task<Void, Never>?
        /// When the second touch landed (for the debug trace).
        private var secondAt = Date.distantPast
        /// The Spaces pager, held still while a second touch is down.
        private weak var heldPager: UIScrollView?

        init(_ surface: ScreenTouchSurface) {
            self.surface = surface
        }

        func install(on view: UIView) {
            // Begins the moment a finger lands and ends the moment it lifts; it never stands in another's way.
            let press = UILongPressGestureRecognizer(target: self, action: #selector(fingerPress(_:)))
            press.minimumPressDuration = 0
            press.cancelsTouchesInView = false
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let drag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            drag.maximumNumberOfTouches = 1
            let rail = UIPanGestureRecognizer(target: self, action: #selector(rail(_:)))
            rail.maximumNumberOfTouches = 1
            for recognizer in [press, twoFingerTap, pinch, drag, rail] as [UIGestureRecognizer] {
                recognizer.delegate = self
                recognizer.delaysTouchesEnded = false
                view.addGestureRecognizer(recognizer)
            }
            pressRecognizer = press
            pinchRecognizer = pinch
            dragRecognizer = drag
            railRecognizer = rail
        }

        // MARK: One finger: click or right-click

        @objc func fingerPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            #if DEBUG
            if recognizer.state != .changed {
                GestureTrace.shared.note(String(format: "press %@ at %.0f,%.0f", Self.name(recognizer.state), point.x, point.y))
            }
            #endif
            switch recognizer.state {
            case .began:
                let landed = touchDownTime ?? ProcessInfo.processInfo.systemUptime
                #if DEBUG
                if let lastTap {
                    GestureTrace.shared.note(String(format: "touch %.0f ms after the tap, %.0f pt away",
                                                    (landed - lastTap.at) * 1000,
                                                    hypot(point.x - lastTap.point.x, point.y - lastTap.point.y)))
                }
                #endif
                if surface.carries, let lastTap, landed - lastTap.at < ScreenTouchSurface.doubleTapWindow,
                   hypot(point.x - lastTap.point.x, point.y - lastTap.point.y) < ScreenTouchSurface.doubleTapReach {
                    beginSecondTouch(at: point, in: view)
                } else {
                    startPress(at: point)
                }
            case .changed:
                if let second {
                    if second.carrying {
                        surface.onEvent(.carry(point: point, phase: .changed))
                    } else if hypot(point.x - second.start.x, point.y - second.start.y) > ScreenTouchSurface.carrySlop {
                        #if DEBUG
                        GestureTrace.shared.note(String(format: "carrying by moving after %.0f ms",
                                                        Date.now.timeIntervalSince(secondAt) * 1000))
                        GestureTrace.shared.startedByMoving += 1
                        #endif
                        startCarry()
                        surface.onEvent(.carry(point: point, phase: .changed))
                    }
                    return
                }
                // Moving turns it into a drag, a swipe or a scroll: no click.
                guard let pressing, !pressing.handled else { return }
                if hypot(point.x - pressing.start.x, point.y - pressing.start.y) > 10 { cancelPress() }
            case .ended:
                lastTap = nil
                touchDownTime = nil
                if let second {
                    #if DEBUG
                    GestureTrace.shared.note(String(format: "second touch lifted after %.0f ms: %@",
                                                    Date.now.timeIntervalSince(secondAt) * 1000,
                                                    second.carrying ? "drop" : "double click"))
                    #endif
                    endSecondTouch()
                    // Lifted without moving: the double click's second click.
                    surface.onEvent(second.carrying ? .carry(point: point, phase: .ended) : .doubleTap(second.start))
                    return
                }
                guard let pressing else { return }
                cancelPress()
                if !pressing.handled {
                    surface.onEvent(.tap(pressing.start))
                    lastTap = (pressing.start, ProcessInfo.processInfo.systemUptime)
                }
            default:
                lastTap = nil
                touchDownTime = nil
                if let second {
                    #if DEBUG
                    GestureTrace.shared.note(String(format: "second touch cancelled (state %ld) after %.0f ms",
                                                    recognizer.state.rawValue, Date.now.timeIntervalSince(secondAt) * 1000))
                    #endif
                    endSecondTouch()
                    if second.carrying { surface.onEvent(.carry(point: point, phase: .ended)) }
                }
                cancelPress()
            }
        }

        private func startPress(at start: CGPoint) {
            cancelPress()
            pressing = (start, false)
            let ringDelay = ScreenTouchSurface.ringDelay
            let hold = surface.holdDuration
            timers.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(ringDelay))
                guard !Task.isCancelled, let self, self.pressing?.handled == false else { return }
                self.ringShown = true
                self.surface.onEvent(.holdBegan(start))
            })
            timers.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(hold))
                // A busy phone runs this late, and the finger's lift may be waiting in line behind it: let it through,
                // so a tap is never taken for a hold.
                await Coordinator.letQueuedTouchesThrough()
                guard !Task.isCancelled, let self, self.pressing?.handled == false else { return }
                // Only a finger that is still down right-clicks.
                guard let press = self.pressRecognizer, press.state == .began || press.state == .changed else {
                    self.cancelPress()
                    return
                }
                self.pressing?.handled = true
                self.ringShown = false
                #if DEBUG
                GestureTrace.shared.note("right-click")
                #endif
                self.surface.onEvent(.rightClick(start))
            })
        }

        #if DEBUG
        static func name(_ state: UIGestureRecognizer.State) -> String {
            switch state {
            case .possible: "possible"
            case .began: "began"
            case .changed: "changed"
            case .ended: "ended"
            case .cancelled: "cancelled"
            case .failed: "failed"
            @unknown default: "state \(state.rawValue)"
            }
        }
        #endif

        /// Lets touches queued behind a late timer through: short waits until one comes back on time.
        static func letQueuedTouchesThrough() async {
            let clock = ContinuousClock()
            for _ in 0..<20 {
                let asked = clock.now
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled || clock.now - asked < .milliseconds(50) { break }
            }
        }

        // MARK: A double tap's second touch: a double click, or a drag with the Mac's mouse

        /// No right-click, swipe, scroll or pan takes it; held still for the hold time, it picks up what's under it.
        private func beginSecondTouch(at start: CGPoint, in view: UIView) {
            cancelPress()
            second = (start, false)
            // The Spaces pager stays where it is until the finger lifts.
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            if let pager = ancestor as? UIScrollView, pager.panGestureRecognizer.isEnabled {
                pager.panGestureRecognizer.isEnabled = false
                heldPager = pager
            }
            // Counted from when the finger landed, by the touch's own time: a busy phone may handle the touch late (in
            // the tests, by up to half a second), which mustn't push the pick-up past the moment the finger moves on.
            let now = ProcessInfo.processInfo.systemUptime
            let landedAgo = min(max(0, now - (touchDownTime ?? now)), ScreenTouchSurface.pickUpDelay)
            secondAt = Date(timeIntervalSinceNow: -landedAgo)
            let ringWait = max(0, ScreenTouchSurface.pickUpRingDelay - landedAgo)
            let pickUpWait = ScreenTouchSurface.pickUpDelay - landedAgo
            pickUp = Task { [weak self] in
                // The ring shows once the finger has rested a moment, and fills until it picks up.
                try? await Task.sleep(for: .seconds(ringWait))
                guard !Task.isCancelled, let self, self.second?.carrying == false else { return }
                self.pickUpRingShown = true
                self.surface.onEvent(.pickUpBegan(start, remaining: pickUpWait - ringWait))
                try? await Task.sleep(for: .seconds(pickUpWait - ringWait))
                // A busy phone runs this late, and the finger's lift may be waiting in line behind it: let it through.
                await Coordinator.letQueuedTouchesThrough()
                #if DEBUG
                GestureTrace.shared.note(String(format: "hold timer after %.0f ms: second %@, press state %ld",
                                                Date.now.timeIntervalSince(self.secondAt) * 1000,
                                                self.second.map { $0.carrying ? "carrying" : "down" } ?? "gone",
                                                self.pressRecognizer?.state.rawValue ?? -1))
                #endif
                // Only a finger that is still down picks up. That's our own record (`second` goes when the finger
                // lifts or the touch is cancelled), not the recognizer's state, which a long, still touch can leave
                // anywhere.
                guard !Task.isCancelled, self.second?.carrying == false else { return }
                #if DEBUG
                GestureTrace.shared.note("picked up by the hold")
                GestureTrace.shared.pickedUpByHolding += 1
                #endif
                self.startCarry(pickedUp: true)
            }
        }

        /// The second touch moved past the slop, or rested (`pickedUp`): the Mac's button goes down where it landed.
        private func startCarry(pickedUp: Bool = false) {
            guard let start = second?.start, second?.carrying == false else { return }
            pickUp?.cancel()
            pickUp = nil
            second?.carrying = true
            pickUpRingShown = false
            surface.onEvent(.carry(point: start, phase: .began, pickedUp: pickedUp))
        }

        private func hidePickUpRing() {
            guard pickUpRingShown else { return }
            pickUpRingShown = false
            surface.onEvent(.pickUpEnded)
        }

        /// The view went with a second touch down (the phone turned, or the page stopped being live): the pager pans
        /// again. (The view's own disappearance ends the Mac's drag.)
        func surfaceGone() {
            if second != nil { endSecondTouch() }
        }

        private func endSecondTouch() {
            pickUp?.cancel()
            pickUp = nil
            hidePickUpRing()
            second = nil
            if let heldPager { heldPager.panGestureRecognizer.isEnabled = heldPager.isScrollEnabled }
            heldPager = nil
        }

        private func cancelPress() {
            timers.forEach { $0.cancel() }
            timers = []
            pressing = nil
            if ringShown {
                ringShown = false
                surface.onEvent(.holdEnded)
            }
        }

        // MARK: Two fingers, drags and the scroll bar

        @objc func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            cancelPress()
            surface.onEvent(.rightClick(recognizer.location(in: view)))
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let center = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                cancelPress()
                pinching = true
                pinchCenter = center
                pinchTouches = recognizer.numberOfTouches
                surface.onEvent(.pinch(factor: recognizer.scale, center: center, moved: .zero, phase: .began))
            case .changed:
                // A finger lifted or added moves the centre without the fingers moving: no jump.
                var moved = CGSize.zero
                if recognizer.numberOfTouches == pinchTouches, let last = pinchCenter {
                    moved = CGSize(width: center.x - last.x, height: center.y - last.y)
                }
                pinchCenter = center
                pinchTouches = recognizer.numberOfTouches
                surface.onEvent(.pinch(factor: recognizer.scale, center: center, moved: moved, phase: .changed))
            default:
                pinching = false
                pinchCenter = nil
                surface.onEvent(.pinch(factor: 1, center: center, moved: .zero, phase: .ended))
            }
            recognizer.scale = 1
        }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let delta = CGSize(width: point.x - dragLast.x, height: point.y - dragLast.y)
            switch recognizer.state {
            case .began:
                cancelPress()
                // Everything since the finger landed.
                dragStart = touchDown ?? point
                dragLast = point
                surface.onEvent(.drag(delta: CGSize(width: point.x - dragStart.x, height: point.y - dragStart.y),
                                      start: dragStart, phase: .began))
            case .changed:
                dragLast = point
                // Two fingers are the pinch's (it moves the picture itself).
                guard !pinching, recognizer.numberOfTouches <= 1 else { return }
                surface.onEvent(.drag(delta: delta, start: dragStart, phase: .changed))
            default:
                // The last bit of movement can come with the lift: it counts.
                let last = recognizer.state == .ended && !pinching ? delta : .zero
                surface.onEvent(.drag(delta: last, start: dragStart, phase: .ended))
            }
        }

        @objc func rail(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let y = recognizer.location(in: view).y
            let velocity = recognizer.velocity(in: view).y
            switch recognizer.state {
            case .began:
                cancelPress()
                // Everything since the finger landed.
                let delta = y - (touchDown?.y ?? y)
                railLast = y
                surface.onEvent(.rail(delta: delta, velocity: velocity, phase: .began))
            case .changed:
                let delta = y - railLast
                railLast = y
                surface.onEvent(.rail(delta: delta, velocity: velocity, phase: .changed))
            default:
                // A quick drag can arrive almost whole with the lift: that movement scrolls too.
                if recognizer.state == .ended, y != railLast {
                    surface.onEvent(.rail(delta: y - railLast, velocity: velocity, phase: .changed))
                }
                surface.onEvent(.rail(delta: 0, velocity: 0, phase: .ended))
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = recognizer.view else { return true }
            if recognizer === pressRecognizer {
                // A second finger during a press makes it a pinch or a two-finger tap, never a click; during a double
                // tap's second touch, it ends that touch's drag.
                if pressing != nil { cancelPress() }
                if recognizer.numberOfTouches > 0, let second {
                    endSecondTouch()
                    lastTap = nil
                    if second.carrying { surface.onEvent(.carry(point: recognizer.location(in: view), phase: .ended)) }
                }
                if recognizer.numberOfTouches == 0 {
                    touchDown = touch.location(in: view)
                    touchDownTime = touch.timestamp
                }
            }
            // The scroll bar and the drags see only touches they could take, so the Spaces pager (which waits for
            // them to turn a touch down) never waits on them for a swipe.
            if recognizer === railRecognizer { return touch.location(in: view).x >= view.bounds.width - surface.railWidth }
            if recognizer === dragRecognizer { return surface.scrollMode || surface.zoomed }
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            // A double tap's second touch drags the Mac's mouse: no scroll, scroll bar or pan takes it.
            if second != nil, recognizer === dragRecognizer || recognizer === railRecognizer { return false }
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let location = pan.location(in: view)
            let translation = pan.translation(in: view)
            let start = touchDown ?? CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let vertical = abs(location.y - start.y) > abs(location.x - start.x)
            let onRail = start.x >= view.bounds.width - surface.railWidth && vertical
            if pan === railRecognizer { return onRail }
            // Outside scroll mode an unzoomed picture leaves sideways drags to the Spaces pager.
            return !onRail && (surface.scrollMode || surface.zoomed)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // The finger timer runs alongside everything; the pinch alongside a one-finger drag already under way.
            recognizer === pressRecognizer || other === pressRecognizer
                || (recognizer === pinchRecognizer && other === dragRecognizer)
                || (recognizer === dragRecognizer && other === pinchRecognizer)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // The Spaces pager's pan waits for the scroll bar and the drags to turn a touch down (they decide as it
            // starts moving), so a vertical drag on the bar is never taken for a swipe; zoomed in, or in Drag to
            // Scroll, the drag takes every one-finger drag, so the finger never pages. Zoomed in it waits for the
            // pinch too: two fingers move the picture, never the pager. Only its pan: the pager's other recognizers
            // (the one that holds back a touch while it decides) must not wait on ours.
            guard recognizer === railRecognizer || recognizer === dragRecognizer
                    || (recognizer === pinchRecognizer && surface.zoomed),
                  let pager = other.view as? UIScrollView else { return false }
            return other === pager.panGestureRecognizer
        }
    }
}

/// Typing on the Mac: text, and its keys drawn as they are on a Mac keyboard. Hold a modifier (it lights up), then
/// type a letter or press a key for a shortcut, such as ⌘ C.
struct MacKeyboardSheet: View {
    var displayId: UInt32
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var held: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        TextField(held.isEmpty ? "Type on the Mac" : "Letter for \(heldSymbols)", text: $text, axis: .vertical)
                            .focused($focused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                        Button("Type", systemImage: "arrow.up.circle.fill") { typeText() }
                            .labelStyle(.iconOnly)
                            .font(.largeTitle)
                            .disabled(text.isEmpty)
                    }
                    Text("Goes to whatever is focused on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Row 1: esc, tab, delete.
                    HStack(spacing: 8) {
                        key(.escape)
                        key(.tab)
                        Spacer(minLength: 0)
                        key(.delete)
                    }
                    // Row 2: modifiers, return.
                    HStack(spacing: 8) {
                        modifier(.shift, name: "shift")
                        modifier(.control, name: "control")
                        Spacer(minLength: 0)
                        key(.returnKey)
                    }
                    // Row 3: option, command, space; arrows in the inverted T.
                    HStack(alignment: .bottom, spacing: 8) {
                        modifier(.option, name: "option")
                        modifier(.command, name: "command")
                        key(.space)
                        Spacer(minLength: 0)
                        VStack(spacing: 4) {
                            KeyCapButton(key: .up, height: 30) { press(MacKey.up) }
                            HStack(spacing: 4) {
                                KeyCapButton(key: .left, height: 30) { press(MacKey.left) }
                                KeyCapButton(key: .down, height: 30) { press(MacKey.down) }
                                KeyCapButton(key: .right, height: 30) { press(MacKey.right) }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Mac Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var heldSymbols: String {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")].filter { held.contains($0.0) }.map(\.1).joined()
    }

    private func key(_ key: MacKey) -> some View {
        KeyCapButton(key: key) { press(key) }
    }

    private func modifier(_ key: MacKey, name: String) -> some View {
        let wireName = name == "command" ? "cmd" : name
        return KeyCapButton(key: key, isOn: held.contains(wireName)) {
            if held.contains(wireName) { held.remove(wireName) } else { held.insert(wireName) }
        }
    }

    private func typeText() {
        let value = text
        text = ""
        let mods = Array(held)
        Task {
            await store.perform {
                if mods.isEmpty {
                    try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .type, text: value))
                } else if let first = value.first {
                    // With modifiers held, a typed letter becomes a shortcut, e.g. ⌘ C.
                    try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .key,
                                                                                      key: String(first), modifiers: mods))
                }
            }
            held.removeAll()
        }
    }

    private func press(_ key: MacKey) {
        guard let name = key.macKey else { return }
        let mods = Array(held)
        Task {
            await store.perform {
                try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .key, key: name,
                                                                                  modifiers: mods))
            }
            held.removeAll()
        }
    }
}
