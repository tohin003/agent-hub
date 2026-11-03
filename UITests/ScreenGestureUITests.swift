import XCTest

/// The Screen tab's gestures, played as a finger plays them, on the debug-only harness (`-screenGestureTest YES`): the
/// real screen view over a made-up Mac screen, in the same tab, navigation stack and Spaces pager, showing what each
/// gesture sends. Run: `xcodebuild test -scheme AgentHub -destination 'platform=iOS Simulator,name=…'`.
@MainActor
final class ScreenGestureUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The picture of the page on screen. The pager keeps the other page's picture around, off screen or, once passed,
    /// with no frame at all; a gesture on that one goes nowhere.
    private var screen: XCUIElement {
        let pictures = app.descendants(matching: .any).matching(identifier: "remoteScreen")
        let window = app.windows.firstMatch.frame
        return pictures.allElementsBoundByIndex.first { picture in
            let frame = picture.frame
            return !frame.isNull && !frame.isInfinite && frame.width > 0 && window.contains(CGPoint(x: frame.midX, y: frame.midY))
        } ?? pictures.firstMatch
    }

    /// The harness, fresh for each test.
    private func launch(extra: [String] = []) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-screenGestureTest", "YES"] + extra
        app.launch()
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        // The pager settles on its first page after it appears; a touch during that is the pager's.
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// A finger's drag: it lands, moves at a hand's speed and rests a moment before lifting (a synthesized drag can
    /// otherwise arrive all at once on a busy simulator, which no finger does).
    private func drag(from start: XCUICoordinate, to end: XCUICoordinate) {
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.15)
    }

    private var last: String { app.staticTexts["lastInput"].label }
    private var count: Int { Int(app.staticTexts["inputCount"].label) ?? -1 }
    /// What was sent lately, for failure messages.
    private var recent: String { "sent: [\(app.staticTexts["recentInputs"].label)]" }

    /// Waits for the inputs to land (and past the hold, so a missed lift would show as a right-click).
    private func settle() { Thread.sleep(forTimeInterval: 1.0) }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        screen.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func testTapsClickAndHoldsRightClick() {
        launch()

        var before = count
        screen.tap()
        settle()
        XCTAssertEqual(last, "click 1", "a quick tap clicks; \(recent)")
        XCTAssertEqual(count, before + 1, "a quick tap sends one input; \(recent)")

        before = count
        screen.press(forDuration: 0.4)
        settle()
        XCTAssertEqual(last, "click 1", "a slow tap still clicks; \(recent)")
        XCTAssertEqual(count, before + 1, recent)

        before = count
        screen.press(forDuration: 1.2)
        settle()
        XCTAssertEqual(last, "rightClick", "holding right-clicks; \(recent)")
        XCTAssertEqual(count, before + 1, "holding sends one right-click; \(recent)")

        before = count
        screen.doubleTap()
        settle()
        XCTAssertEqual(last, "click 2", "a double tap double-clicks; \(recent)")
        XCTAssertEqual(count, before + 2, recent)

        before = count
        screen.twoFingerTap()
        settle()
        XCTAssertEqual(last, "rightClick", "a two-finger tap right-clicks; \(recent)")
        XCTAssertEqual(count, before + 1, "a two-finger tap sends one right-click and no click; \(recent)")
    }

    /// A finger never lands perfectly still: a tap that slides a few points is still a click, never a right-click.
    func testTapThatMovesSlightlyClicks() {
        launch()
        for (index, wobble) in [CGVector(dx: 3, dy: 2), CGVector(dx: -4, dy: 3), CGVector(dx: 2, dy: -5)].enumerated() {
            let before = count
            let start = point(0.3 + 0.2 * CGFloat(index), 0.5)
            start.press(forDuration: 0.03, thenDragTo: start.withOffset(wobble))
            settle()
            XCTAssertEqual(last, "click 1", "tap \(index + 1) moving \(wobble) clicks; \(recent)")
            XCTAssertEqual(count, before + 1, "tap \(index + 1) sends one input; \(recent)")
        }
    }

    func testScrollBarPinchAndDragToScroll() {
        launch()

        // The scroll bar along the right edge: dragging it down scrolls down, in any mode.
        var before = count
        drag(from: point(0.985, 0.4), to: point(0.985, 0.65))
        settle()
        XCTAssertEqual(last, "scroll down", "the scroll bar scrolls; \(recent); screen \(screen.frame) window \(app.windows.firstMatch.frame)")
        XCTAssertGreaterThan(count, before, recent)

        // Drag to scroll: a drag scrolls (content follows the finger), a pinch zooms, and a tap still clicks.
        let toggle = app.switches["scrollMode"]
        toggle.tap()
        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1", "scroll mode is on")
        before = count
        drag(from: point(0.5, 0.42), to: point(0.5, 0.6))
        settle()
        XCTAssertEqual(last, "scroll up", "a drag scrolls in scroll mode; \(recent)")
        XCTAssertGreaterThan(count, before, recent)

        before = count
        screen.pinch(withScale: 2.5, velocity: 2)
        settle()
        XCTAssertEqual(app.staticTexts["zoom"].label, "zoomed", "a pinch zooms in scroll mode")
        XCTAssertEqual(count, before, "a pinch sends nothing to the Mac; \(recent)")

        before = count
        screen.tap()
        settle()
        XCTAssertEqual(last, "click 1", "a tap clicks when zoomed; \(recent)")
        XCTAssertEqual(count, before + 1, recent)
    }

    func testSwipeChangesSpaceWithoutClicking() {
        launch()
        let before = count
        // Most of the way across: the pager turns the page whatever the speed.
        point(0.85, 0.5).press(forDuration: 0.05, thenDragTo: point(0.1, 0.5),
                               withVelocity: XCUIGestureVelocity(1500), thenHoldForDuration: 0)
        settle()
        XCTAssertEqual(app.staticTexts["page"].label, "page 1", "a sideways swipe moves to the next Space")
        XCTAssertEqual(count, before, "a swipe sends nothing to the Mac; \(recent)")
    }

    // MARK: Double-tap and drag

    /// The harness with a longer double-tap window: XCUITest's tap and its next gesture come slower than a hand's. On
    /// this busy Mac the first synthesized touch after a launch is sometimes lost, so a tap in the middle warms it up
    /// (it clicks once, far from where the tests touch next).
    private func launchForDoubleTaps() {
        launch(extra: ["-screenGestureDoubleTapWindow", "5"])
        for _ in 0..<3 where count == 0 {
            point(0.5, 0.55).tap()
            settle()
        }
        XCTAssertEqual(count, 1, "the warm-up tap clicked once; \(recent)")
        // Past the double-tap window, so the warm-up's click doesn't count towards the next.
        Thread.sleep(forTimeInterval: 5.2)
    }

    /// Live-drag messages so far: starts, moves, ends.
    private func drags() -> (starts: Int, moves: Int, ends: Int) {
        let numbers = app.staticTexts["dragCounts"].label.split(separator: " ").compactMap { Int($0) }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : (-1, -1, -1)
    }

    private var scrolls: Int { Int(app.staticTexts["scrollCount"].label.split(separator: " ").last ?? "") ?? -1 }
    private var lastClickPoint: String { app.staticTexts["lastClickPoint"].label }
    /// The last drag on the display: "x,y to x,y".
    private var lastDrag: String { app.staticTexts["lastDrag"].label }

    private func spot(_ text: some StringProtocol) -> CGPoint? {
        let numbers = text.split(separator: ",").compactMap { Double($0) }
        return numbers.count == 2 ? CGPoint(x: numbers[0], y: numbers[1]) : nil
    }

    /// A tap, then a second touch at the same spot that rests `hold` seconds, moves to `end` at a hand's speed and rests
    /// `rest` seconds before it lifts.
    private func doubleTapDrag(from start: XCUICoordinate, to end: XCUICoordinate, hold: TimeInterval = 0.05,
                               rest: TimeInterval = 0.2, speed: CGFloat = 400) {
        start.tap()
        start.press(forDuration: hold, thenDragTo: end, withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: rest)
    }

    /// One double-tap and drag: one start where the first tap clicked, moves, one end; no right-click; the pager stays.
    private func expectOneDrag(_ what: String, since before: (starts: Int, moves: Int, ends: Int), page: String = "page 0",
                               file: StaticString = #filePath, line: UInt = #line) {
        let now = drags()
        XCTAssertEqual(now.starts, before.starts + 1, "\(what): one start; \(recent)", file: file, line: line)
        XCTAssertGreaterThan(now.moves, before.moves, "\(what): the pointer follows; \(recent)", file: file, line: line)
        XCTAssertEqual(now.ends, before.ends + 1, "\(what): one end; \(recent)", file: file, line: line)
        XCTAssertEqual(last, "dragEnd", "\(what): \(recent)", file: file, line: line)
        XCTAssertFalse(recent.contains("rightClick"), "\(what): no right-click; \(recent)", file: file, line: line)
        XCTAssertEqual(app.staticTexts["page"].label, page, "\(what): the Spaces pager doesn't take it", file: file, line: line)
        // The button goes down where the double tap's first tap clicked: the same point on the display, zoomed or not.
        let from = lastDrag.components(separatedBy: " to ").first.flatMap { spot($0) }
        if let from, let click = spot(lastClickPoint) {
            XCTAssertEqual(from.x, click.x, accuracy: 0.004, "\(what): starts where the tap clicked (\(lastDrag), click \(lastClickPoint))", file: file, line: line)
            XCTAssertEqual(from.y, click.y, accuracy: 0.004, "\(what): starts where the tap clicked (\(lastDrag), click \(lastClickPoint))", file: file, line: line)
        } else {
            XCTFail("\(what): no drag or click point (\(lastDrag), click \(lastClickPoint))", file: file, line: line)
        }
    }

    /// Double-tap and drag drags with the Mac's mouse, the pager never takes it, and a held second touch picks up; a
    /// plain double tap still double-clicks and a single drag still swipes to the next Space.
    func testDoubleTapAndDragDragsTheMouse() {
        launchForDoubleTaps()

        var before = count
        // (On the picture: upright, the 16:10 picture spans about 0.31 to 0.69 of the view's height.)
        point(0.5, 0.4).doubleTap()
        settle()
        XCTAssertEqual(last, "click 2", "a plain double tap still double-clicks; \(recent)")
        XCTAssertEqual(count, before + 2, recent)
        XCTAssertEqual(drags().starts, 0, "and doesn't drag; \(recent)")

        // Sideways, the Spaces pager's way.
        var dragsBefore = drags()
        doubleTapDrag(from: point(0.7, 0.45), to: point(0.25, 0.5))
        settle()
        expectOneDrag("a sideways double-tap and drag", since: dragsBefore)
        if let to = lastDrag.components(separatedBy: " to ").last.flatMap({ spot($0) }) {
            XCTAssertEqual(to.x, 0.25, accuracy: 0.03, "it ends where the finger lifts; \(lastDrag)")
        }

        // Held still past the hold time: picked up (no double click, no right-click), then dragged.
        dragsBefore = drags()
        doubleTapDrag(from: point(0.3, 0.65), to: point(0.55, 0.75), hold: 1.3)
        settle()
        expectOneDrag("a double tap held, then dragged", since: dragsBefore)

        // Held and lifted where it is: picked up and dropped, still no double click.
        dragsBefore = drags()
        before = count
        let here = point(0.75, 0.6)
        here.tap()
        here.press(forDuration: 1.6)
        settle()
        let now = drags()
        XCTAssertEqual(now.starts, dragsBefore.starts + 1, "holding the second touch picks up; \(recent)")
        XCTAssertEqual(now.ends, dragsBefore.ends + 1, "lifting drops; \(recent)")
        XCTAssertFalse(recent.contains("click 2"), "a held second touch isn't a double click; \(recent)")

        // A single swipe still changes Space (a synthesized swipe that never reached the pager is made again, as in
        // the layout tests).
        before = count
        for _ in 0..<3 where app.staticTexts["page"].label == "page 0" {
            point(0.85, 0.2).press(forDuration: 0.05, thenDragTo: point(0.1, 0.2),
                                   withVelocity: XCUIGestureVelocity(1500), thenHoldForDuration: 0)
            settle()
        }
        XCTAssertEqual(app.staticTexts["page"].label, "page 1", "a single swipe still moves to the next Space")
        XCTAssertEqual(count, before, "and sends nothing; \(recent)")
    }

    /// With Drag to Scroll on, a double-tap and drag drags (a single drag still scrolls); zoomed in, it maps through the
    /// zoom like a tap (a single drag still pans); on its side it's the same.
    func testDoubleTapAndDragWithScrollZoomAndLandscape() {
        launchForDoubleTaps()

        let toggle = app.switches["scrollMode"]
        toggle.tap()
        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1", "scroll mode is on")
        var dragsBefore = drags()
        var scrollsBefore = scrolls
        doubleTapDrag(from: point(0.4, 0.4), to: point(0.4, 0.65))
        settle()
        expectOneDrag("a double-tap and drag with Drag to Scroll on", since: dragsBefore)
        XCTAssertEqual(scrolls, scrollsBefore, "it doesn't scroll; \(recent)")
        scrollsBefore = scrolls
        drag(from: point(0.7, 0.4), to: point(0.7, 0.6))
        settle()
        XCTAssertGreaterThan(scrolls, scrollsBefore, "a single drag still scrolls; \(recent)")

        // Zoomed in (a pinch zooms in scroll mode too), then Drag to Scroll off: a single drag pans the picture.
        screen.pinch(withScale: 2.5, velocity: 2)
        settle()
        XCTAssertEqual(app.staticTexts["zoom"].label, "zoomed")
        toggle.tap()
        if toggle.value as? String != "0" { toggle.switches.firstMatch.tap() }
        dragsBefore = drags()
        doubleTapDrag(from: point(0.45, 0.5), to: point(0.6, 0.6))
        settle()
        expectOneDrag("a double-tap and drag zoomed in", since: dragsBefore)
        // It didn't pan: a tap at the same spot clicks the same point of the display.
        let start = spot(lastDrag.components(separatedBy: " to ").first ?? "")
        Thread.sleep(forTimeInterval: 5.5)
        point(0.45, 0.5).tap()
        settle()
        if let start, let click = spot(lastClickPoint) {
            XCTAssertEqual(click.x, start.x, accuracy: 0.004, "the drag didn't pan the picture; \(lastClickPoint) vs \(lastDrag)")
        }
        let before = count
        let clickBefore = lastClickPoint
        Thread.sleep(forTimeInterval: 5.5)
        drag(from: point(0.5, 0.5), to: point(0.3, 0.5))
        settle()
        XCTAssertEqual(count, before, "a single drag zoomed in pans, sending nothing; \(recent)")
        point(0.45, 0.5).tap()
        settle()
        XCTAssertNotEqual(lastClickPoint, clickBefore, "a single drag still pans the zoomed picture")

        // On its side, zoomed back out.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        screen.pinch(withScale: 0.3, velocity: -2)
        settle()
        XCTAssertEqual(app.staticTexts["zoom"].label, "whole")
        Thread.sleep(forTimeInterval: 5.5)
        dragsBefore = drags()
        doubleTapDrag(from: point(0.65, 0.5), to: point(0.3, 0.55))
        settle()
        expectOneDrag("a double-tap and drag on its side", since: dragsBefore)
        XCUIDevice.shared.orientation = .portrait
    }
}
