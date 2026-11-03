import XCTest

/// The Screen tab laid on its side, on the debug-only layout harness (`-screenLayoutTest YES`): the Screen tab's own
/// stage, controls, readout and Spaces bar around a made-up Mac screen. Every control stays within reach beside the
/// picture and never over it, taps land where they should, a turn keeps the Space and starts the zoom over, sheets and
/// alerts work on its side, and the app stands upright again on the way out.
@MainActor
final class ScreenLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The picture of the page on screen. The pager keeps other pages' pictures around, off screen or, once passed, with
    /// no frame at all; a gesture on one of those goes nowhere.
    private var screen: XCUIElement {
        let pictures = app.descendants(matching: .any).matching(identifier: "remoteScreen")
        let window = self.window.frame
        return pictures.allElementsBoundByIndex.first { picture in
            let frame = picture.frame
            return !frame.isNull && !frame.isInfinite && frame.width > 0 && window.contains(CGPoint(x: frame.midX, y: frame.midY))
        } ?? pictures.firstMatch
    }
    private var window: XCUIElement { app.windows.firstMatch }

    /// The controls the landscape column holds, by their names.
    private let columnControls = ["Portrait", "Turn Off Live Screen", "Privacy Screen", "Keyboard", "Sound and Brightness",
                                  "Drag to Scroll", "Screen Options"]

    /// `frameLimit`: the readout as when the hub holds the frame rate down ("12/30 fps"), its widest. `video`: the
    /// picture through the video path the live screen uses.
    private func launch(aspect: Double? = nil, frameLimit: Int? = nil, video: Bool = false, extra: [String] = []) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-screenLayoutTest", "YES", "-harnessReadout", "YES"]
            + (aspect.map { ["-screenLayoutAspect", "\($0)"] } ?? [])
            + (frameLimit.map { ["-screenLayoutFrameLimit", "\($0)"] } ?? [])
            + (video ? ["-screenLayoutVideo", "YES"] : []) + extra
        app.launch()
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLayout(landscape: false), "the app starts upright")
        // The pager settles on its first page after it appears; a touch during that is the pager's.
        Thread.sleep(forTimeInterval: 1.5)
    }

    private var isLandscape: Bool { window.frame.width > window.frame.height }
    private var last: String { app.staticTexts["lastInput"].label }
    private var count: Int { Int(app.staticTexts["inputCount"].label) ?? -1 }
    private var page: String { app.staticTexts["page"].label }
    private var zoom: String { app.staticTexts["zoom"].label }

    /// Waits for the window and the layout to turn, then for the turn's animation to finish.
    @discardableResult
    /// The window's frame once a turn has finished: whole points, the same twice in a row (mid-turn, XCUITest reports
    /// the turning window's bounding box).
    private func settledWindowFrame(timeout: TimeInterval = 10) -> CGRect {
        var last = window.frame
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = window.frame
            if now == last, now.minX == now.minX.rounded(), now.minY == now.minY.rounded(), now.width == now.width.rounded(),
               now.height == now.height.rounded() {
                return now
            }
            last = now
        }
        return last
    }

    private func waitForLayout(landscape: Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if isLandscape == landscape, app.staticTexts["layout"].label == (landscape ? "landscape" : "portrait") {
                Thread.sleep(forTimeInterval: 1)
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < deadline
        return false
    }

    private func turnLandscape() {
        control("Landscape").tap()
        XCTAssertTrue(waitForLayout(landscape: true), "Landscape lays the app on its side; window \(window.frame)")
    }

    private func turnUpright() {
        control("Portrait").tap()
        XCTAssertTrue(waitForLayout(landscape: false), "Portrait stands the app upright; window \(window.frame)")
    }

    /// The control with this name that a finger can reach (a hidden bar's copy doesn't count).
    private func control(_ name: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name))
        return matches.allElementsBoundByIndex.first { $0.exists && $0.isHittable } ?? matches.firstMatch
    }

    private func visible(_ element: XCUIElement) -> Bool { element.exists && element.isHittable }

    /// Waits for the inputs to land (and past the hold, so a missed lift would show as a right-click).
    private func settle() { Thread.sleep(forTimeInterval: 1.0) }

    /// A menu's item by its title (a toggle's explanation may share its label).
    private func menuItem(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private var smoothSetting: String { app.staticTexts["smooth"].label }

    /// Keeps a screenshot with the results, and writes it to `SHOTS_DIR` when the run sets one
    /// (`TEST_RUNNER_SHOTS_DIR`): the layout harness's made-up Mac screen, never a real one.
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        screen.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func testLandscapeKeepsEveryControlBesideThePicture() {
        launch(frameLimit: 30)
        XCTAssertTrue(visible(app.buttons["streamStats"]), "the stream's numbers show upright")
        turnLandscape()

        let frame = window.frame
        let picture = screen.frame
        XCTAssertEqual(picture.height, frame.height, accuracy: 1, "the picture fills the height; picture \(picture)")
        XCTAssertEqual(picture.width, frame.height * 1.6, accuracy: 2, "a 16:10 picture keeps its shape; picture \(picture)")
        XCTAssertEqual(picture.midX, frame.midX, accuracy: 1, "the picture is centred; picture \(picture)")
        let bar = app.navigationBars.firstMatch
        XCTAssertFalse(bar.exists && bar.isHittable, "no navigation bar on its side")
        let tabs = app.tabBars.firstMatch
        XCTAssertFalse(tabs.exists && tabs.isHittable, "no tab bar on its side")

        for name in columnControls + ["Previous Space", "Next Space", "Stream statistics"] {
            let element = control(name)
            XCTAssertTrue(visible(element), "\(name) is within reach on its side")
            guard element.exists else { continue }
            let box = element.frame
            XCTAssertFalse(box.intersects(picture.insetBy(dx: 1, dy: 1)), "\(name) stays off the picture; \(box) vs \(picture)")
            XCTAssertTrue(frame.contains(box), "\(name) is on screen; \(box)")
            if name != "Stream statistics" {
                XCTAssertGreaterThanOrEqual(box.width, 44, "\(name) is a 44-point target; \(box)")
                XCTAssertGreaterThanOrEqual(box.height, 44, "\(name) is a 44-point target; \(box)")
            }
        }

        // Changes made on its side show in the navigation bar once upright.
        control("Privacy Screen").tap()
        control("Turn Off Live Screen").tap()
        control("Turn On Live Screen").tap()
        turnUpright()
        for name in ["Sound and Brightness", "Landscape", "Turn Off Live Screen", "Privacy Screen", "Keyboard",
                     "Screen Options"] {
            XCTAssertTrue(visible(control(name)), "\(name) is back in the navigation bar upright")
        }
        XCTAssertTrue(visible(app.tabBars.firstMatch), "the tab bar is back upright")
    }

    func testTapsLandWhereTheyShouldInLandscape() {
        launch()
        turnLandscape()
        // Where the scroll bar was is picture now: a tap there clicks there too.
        for (x, y) in [(0.25, 0.75), (0.8, 0.2), (0.97, 0.5), (0.5, 0.5)] {
            let before = count
            point(x, y).tap()
            settle()
            XCTAssertEqual(last, "click 1", "a tap at \(x), \(y) clicks")
            XCTAssertEqual(count, before + 1, "one input for one tap")
            let landed = app.staticTexts["lastPoint"].label.split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(landed.count, 2)
            if landed.count == 2 {
                XCTAssertEqual(landed[0], x, accuracy: 0.02, "the click lands where the finger did (x)")
                XCTAssertEqual(landed[1], y, accuracy: 0.02, "the click lands where the finger did (y)")
            }
        }
    }

    func testTurningKeepsTheSpaceAndStartsTheZoomOver() {
        launch()
        screen.pinch(withScale: 2.5, velocity: 2)
        settle()
        XCTAssertEqual(zoom, "zoomed", "a pinch zooms upright")
        turnLandscape()
        XCTAssertEqual(zoom, "whole", "a turn starts the zoom over")

        // The Spaces bar's own button (a synthesized swipe on the pager is unreliable on a busy simulator).
        control("Next Space").tap()
        settle()
        XCTAssertEqual(page, "page 2", "Next Space on its side moves to the next Space")

        turnUpright()
        XCTAssertEqual(page, "page 2", "standing upright keeps the Space")
        turnLandscape()
        XCTAssertEqual(page, "page 2", "laying it down again keeps the Space")
    }

    func testSheetsAndAlertsWorkInLandscape() {
        launch()
        turnLandscape()

        control("Keyboard").tap()
        XCTAssertTrue(app.navigationBars["Mac Keyboard"].waitForExistence(timeout: 10), "the keyboard opens on its side")
        XCTAssertTrue(isLandscape, "the keyboard sheet keeps the app on its side")
        control("Done").tap()
        XCTAssertTrue(app.navigationBars["Mac Keyboard"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForLayout(landscape: true), "still on its side after the keyboard")
        XCTAssertTrue(visible(control("Portrait")))

        control("Sound and Brightness").tap()
        XCTAssertTrue(app.navigationBars["Sound & Brightness"].waitForExistence(timeout: 10), "sound and brightness open")
        XCTAssertTrue(isLandscape)
        control("Done").tap()
        XCTAssertTrue(app.navigationBars["Sound & Brightness"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForLayout(landscape: true), "still on its side after sound and brightness")

        // With the live screen off, the keyboard asks to turn it on first.
        control("Turn Off Live Screen").tap()
        XCTAssertTrue(visible(control("Turn On Live Screen")), "the live screen switch turns off")
        control("Keyboard").tap()
        let alert = app.alerts["Turn on the live screen?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the alert shows on its side")
        XCTAssertTrue(isLandscape)
        alert.buttons["Turn On"].tap()
        XCTAssertTrue(app.navigationBars["Mac Keyboard"].waitForExistence(timeout: 10), "then the keyboard opens")
        control("Done").tap()
        XCTAssertTrue(app.navigationBars["Mac Keyboard"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(visible(control("Turn Off Live Screen")), "the live screen is on again")
    }

    func testLeavingTheTabOrTheAppStandsItUpright() {
        launch()
        turnLandscape()
        // As a notification would take you to Sessions while the tab bar is hidden.
        control("Leave Screen Tab").tap()
        XCTAssertTrue(waitForLayout(landscape: false), "leaving the Screen tab stands the app upright")

        app.tabBars.buttons["Screen"].tap()
        XCTAssertTrue(waitForLayout(landscape: false), "coming back, the Screen tab is upright until asked")
        turnLandscape()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(screen.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForLayout(landscape: false), "leaving the app stands it upright; window \(window.frame)")
    }

    func testWideDisplayFloatsTheControlsAndHidesThem() {
        launch(aspect: 16.0 / 9, frameLimit: 30)
        control("Landscape").tap()
        // Checked as soon as it turns: the controls fade a few seconds after they appear.
        let deadline = Date.now.addingTimeInterval(15)
        while !(isLandscape && app.staticTexts["layout"].label == "landscape") && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(isLandscape)
        for name in ["Portrait", "Screen Options", "Next Space"] {
            XCTAssertTrue(visible(control(name)), "\(name) shows over the picture's edge at first")
            XCTAssertTrue(window.frame.contains(control(name).frame), "\(name) is whole; \(control(name).frame)")
        }
        let picture = screen.frame
        XCTAssertEqual(picture.height, window.frame.height, accuracy: 1, "the wide picture still fills the height")

        Thread.sleep(forTimeInterval: 6)
        XCTAssertFalse(visible(control("Portrait")), "the controls fade")
        let show = control("Show Controls")
        XCTAssertTrue(visible(show), "a button stays to bring them back")
        XCTAssertGreaterThanOrEqual(show.frame.width, 44)
        show.tap()
        XCTAssertTrue(control("Portrait").waitForExistence(timeout: 5))
        XCTAssertTrue(visible(control("Portrait")), "the controls come back")
    }

    /// Opens Screen Options: in the bar, in the bar's overflow when the largest text sizes leave it no room there, or
    /// in the column on its side.
    private func openScreenOptions() {
        if !visible(control("Screen Options")) {
            let more = app.buttons.matching(NSPredicate(format: "label IN %@", ["More", "More Items", "Show More"])).firstMatch
            if more.exists {
                more.tap()
            } else {
                let labels = app.buttons.allElementsBoundByIndex.map(\.label)
                XCTFail("no Screen Options and no overflow; buttons: \(labels)")
            }
        }
        control("Screen Options").tap()
    }

    func testScreenOptionsOfferSmoothMotion() {
        launch()
        // As an earlier run may have left it.
        if smoothSetting == "smooth on" {
            openScreenOptions()
            menuItem("Smooth Motion").tap()
            settle()
        }
        XCTAssertEqual(smoothSetting, "smooth off")
        openScreenOptions()
        let item = menuItem("Smooth Motion")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Screen Options has Smooth Motion, with the quality choices")
        let explanation = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "stutter")).firstMatch
        XCTAssertTrue(explanation.exists, "with its one-line explanation")
        item.tap()
        settle()
        XCTAssertEqual(smoothSetting, "smooth on", "the switch turns it on")
        openScreenOptions()
        menuItem("Smooth Motion").tap()
        settle()
        XCTAssertEqual(smoothSetting, "smooth off", "and off again")
    }

    /// Screenshots of Screen Options with Smooth Motion: upright and on its side, dark and light, and at the largest
    /// text size. Only when the run asks for them (`TEST_RUNNER_SHOTS_DIR`).
    func testScreenOptionsShots() throws {
        guard ProcessInfo.processInfo.environment["SHOTS_DIR"] != nil else { throw XCTSkip("screenshots only when asked") }
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        for (appearance, look, extra) in [(XCUIDevice.Appearance.dark, "dark", [String]()), (.light, "light", []),
                                          (.dark, "largetext", largest)] {
            XCUIDevice.shared.appearance = appearance
            for landscape in [false, true] {
                launch(extra: extra)
                if landscape { turnLandscape() }
                openScreenOptions()
                let item = menuItem("Smooth Motion")
                // At the largest text sizes the menu scrolls: slow swipes on its list bring the switch into view. A menu that
                // opens upward (on its side, from the column) lists its items the other way round, so down too.
                let list = app.collectionViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Balanced")).firstMatch
                for attempt in 0..<8 where !(item.exists && item.isHittable) && list.exists {
                    if attempt < 4 { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
                }
                XCTAssertTrue(item.exists && item.isHittable, "Smooth Motion is in view")
                Thread.sleep(forTimeInterval: 1)
                shot("step4-options-\(landscape ? "landscape" : "upright")-\(look)")
                app.terminate()
            }
        }
        XCUIDevice.shared.appearance = .light
    }

    /// Zoomed in, taps land exactly where they should, through the video path the live screen uses. The picture's frame
    /// as XCUITest sees it follows the zoom, so a point on it is a point of the Mac's display: a tap there must click
    /// that very point.
    func testZoomedTapsLandExactly() {
        launch(video: true)
        let whole = screen.frame
        // Deep enough that the picture covers the view both ways.
        screen.pinch(withScale: 4, velocity: 3)
        settle()
        XCTAssertEqual(zoom, "zoomed")
        let zoomed = screen.frame
        XCTAssertGreaterThan(zoomed.width, whole.width * 1.5, "the picture grew: \(whole) to \(zoomed)")
        XCTAssertEqual(zoomed.width / zoomed.height, 1.6, accuracy: 0.02, "the frame is the 16:10 picture's own: \(zoomed)")
        for (x, y) in [(0.47, 0.46), (0.53, 0.52), (0.5, 0.55)] {
            let spot = CGPoint(x: zoomed.minX + x * zoomed.width, y: zoomed.minY + y * zoomed.height)
            XCTAssertTrue(window.frame.contains(spot), "the point is on screen: \(spot)")
            let before = count
            point(x, y).tap()
            settle()
            XCTAssertEqual(count, before + 1, "one click for one tap")
            let landed = app.staticTexts["lastPoint"].label.split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(landed.count, 2)
            if landed.count == 2 {
                XCTAssertEqual(landed[0], x, accuracy: 0.003, "the click is the display point under the finger (x)")
                XCTAssertEqual(landed[1], y, accuracy: 0.003, "the click is the display point under the finger (y)")
            }
        }
    }

    /// A choice in the open Screen Options menu (not a copy of it in the bar or the column).
    /// Drag to Scroll, from Screen Options (upright that's where it is), checked on the harness's readout.
    private func toggleDragToScroll() {
        let wanted = app.staticTexts["scroll"].label == "scroll on" ? "scroll off" : "scroll on"
        app.buttons["Screen Options"].firstMatch.tap()
        let choice = menuChoice("Drag to Scroll")
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Drag to Scroll is in Screen Options")
        choice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitFor("scroll", wanted), "Drag to Scroll: \(wanted)")
    }

    private func menuChoice(_ title: String) -> XCUIElement {
        app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// With the picture, the pointer and the numbers changing 60 times a second, each Screen Options choice takes one
    /// tap: Sharp, Drag to Scroll and Smooth Motion, ten times over, upright and on its side.
    func testScreenOptionsTakeOneTapWhileLive() {
        var misses: [String] = []
        var renders: [String] = []
        let rounds = Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "") ?? 10
        for landscape in [false, true] {
            // `TEST_RUNNER_AS_BEFORE_A1=1`: as the tab was before the fix, for comparison.
            let asBefore = ProcessInfo.processInfo.environment["AS_BEFORE_A1"] == "1" ? ["-screenLayoutAsBeforeA1", "YES"] : []
            launch(video: true, extra: ["-screenLayoutLive", "YES", "-screenLayoutResetSmooth", "YES"] + asBefore)
            if landscape { turnLandscape() }
            let side = landscape ? "on its side" : "upright"
            for round in 1...rounds {
                app.buttons["resetOptions"].tap()
                // Few queries: with the picture changing 60 times a second the app is never idle, and XCUITest waits
                // its idle timeout on each one.
                for (item, readout, expected) in [("Sharp", "quality", "quality sharp"), ("Drag to Scroll", "scroll", "scroll on"),
                                                  ("Smooth Motion", "smooth", "smooth on")] {
                    app.buttons["Screen Options"].firstMatch.tap()
                    let choice = menuChoice(item)
                    guard choice.waitForExistence(timeout: 5) else {
                        misses.append("\(side), round \(round): no \(item) in the menu")
                        continue
                    }
                    // At the item's place, as a finger would: an item the menu is rebuilding has no hit point for
                    // XCUITest to use, and the tap is then lost, as the person's was.
                    choice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    Thread.sleep(forTimeInterval: 1.0)
                    let shown = app.staticTexts[readout].label
                    if shown != expected {
                        misses.append("\(side), round \(round): \(item) took no effect (\(shown))")
                        // A menu still open would take the next tap: close it.
                        if menuChoice(item).exists { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap() }
                    }
                }
                renders.append(app.staticTexts["renders"].label)
            }
            app.terminate()
        }
        print("one tap each while live: \(misses.count) of \(6 * rounds) missed: \(misses); \(renders)")
        XCTAssertEqual(misses, [], "each choice takes one tap; \(renders.prefix(4))")
    }

    /// The window's safe area in its own coordinates, from the harness's readout.
    private var safeFrame: CGRect {
        let insets = app.staticTexts["safeArea"].label.split(separator: " ").dropFirst().compactMap { Double($0) }
        let frame = settledWindowFrame()
        guard insets.count == 4 else { return frame }
        return CGRect(x: frame.minX + insets[1], y: frame.minY + insets[0], width: frame.width - insets[1] - insets[3],
                      height: frame.height - insets[0] - insets[2])
    }

    /// On its side, every control of the column and the Spaces bar lies whole inside the safe area: their setup (an
    /// iPhone 17, a 2560×1664 display, a desktop and two full-screen apps, the frame rate held at 30), with six Spaces,
    /// at the largest text size, and on 16:10, 16:9 and ultra-wide displays; the Dynamic Island on either side.
    func testLandscapeControlsStayInsideTheSafeArea() {
        // The controls stay up: where the picture leaves no margin they overlay it and fade after 4 s, sooner than this
        // busy simulator gets through them all.
        let theirs = ["-screenLayoutSpaces", "dff", "-screenLayoutFrameLimit", "30", "-screenLayoutFPS", "24",
                      "-screenLayoutKeepControls", "YES"]
        let setups: [(String, [String])] = [
            ("theirs", ["-screenLayoutAspect", "1.538"] + theirs),
            ("six-spaces", ["-screenLayoutAspect", "1.538", "-screenLayoutSpaces", "dffddf", "-screenLayoutFrameLimit", "30",
                            "-screenLayoutFPS", "24", "-screenLayoutKeepControls", "YES"]),
            ("largest-text", ["-screenLayoutAspect", "1.538"] + theirs
                + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
            ("16x10", ["-screenLayoutAspect", "1.6"] + theirs),
            ("16x9", ["-screenLayoutAspect", "1.7778"] + theirs),
            ("ultrawide", ["-screenLayoutAspect", "2.37"] + theirs),
        ]
        var outside: [String] = []
        // `TEST_RUNNER_SETUPS=theirs,16x9` runs just those.
        let only = ProcessInfo.processInfo.environment["SETUPS"]?.split(separator: ",").map(String.init)
        for (name, extra) in setups where only?.contains(name) ?? true {
            for (side, orientation) in [("island-left", UIDeviceOrientation.landscapeRight), ("island-right", .landscapeLeft)] {
                launch(extra: extra)
                control("Landscape").tap()
                XCUIDevice.shared.orientation = orientation
                XCTAssertTrue(waitForLayout(landscape: true), "\(name) \(side) lays it on its side")
                let safe = safeFrame
                for control in columnControls + ["Previous Space", "Next Space", "Stream statistics"] {
                    let element = self.control(control)
                    guard element.exists else { continue }
                    if !safe.insetBy(dx: -0.5, dy: -0.5).contains(element.frame) || !element.isHittable {
                        outside.append("\(name) \(side): \(control) \(element.frame) outside \(safe)")
                    }
                }
                shot("fix5-landscape-\(name)-\(side)")
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
        }
        XCTAssertEqual(outside, [], "every control whole inside the safe area")
    }

    private var macSpace: String { app.staticTexts["macSpace"].label }
    private var switchRequests: String { app.staticTexts["switchRequests"].label }

    /// Waits up to `timeout` for a readout to say `expected`.
    @discardableResult
    private func waitFor(_ identifier: String, _ expected: String, timeout: TimeInterval = 4) -> Bool {
        let label = app.staticTexts[identifier]
        let deadline = Date.now.addingTimeInterval(timeout)
        while label.label != expected, Date.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
        return label.label == expected
    }

    /// A sideways swipe on the pager, most of the way across, as the gesture tests make it.
    /// Waits until the picture on screen is this Space's ("Space 2"), not just the follower's page: the pager moved.
    private func waitForShown(_ space: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if (screen.value as? String)?.hasSuffix(space) == true { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date.now < deadline
        return false
    }

    /// What's on screen, and the pager's last moves (the harness's trace, a second old at most).
    private var shown: String {
        Thread.sleep(forTimeInterval: 1.1)
        shownShots += 1
        shot("fix5-debug-shown-\(shownShots)")
        let pictures = app.descendants(matching: .any).matching(identifier: "remoteScreen").allElementsBoundByIndex
            .map { "\(($0.value as? String) ?? "?") at \(Int($0.frame.minX))" }
        return "\((screen.value as? String) ?? "nothing"); pictures: \(pictures); pager: \(app.staticTexts["pagerTrace"].label)"
    }
    private var shownShots = 0

    /// A pinch that zooms in. A synthesized pinch sometimes never reaches the picture on this busy Mac, so one that
    /// zoomed nothing is made again, up to three times in all, with what the screen showed kept for a look.
    private func zoomIn(_ when: String) {
        for attempt in 1...3 {
            screen.pinch(withScale: 2.5, velocity: 2)
            settle()
            if zoom == "zoomed" { return }
            print("pinch \(attempt) \(when) zoomed nothing: screen \(screen.frame), window \(window.frame), \(page)")
            shot("fix5-debug-pinch-\(attempt)")
        }
    }

    /// A swipe to the next Space, as a finger makes it. On this busy Mac a synthesized swipe sometimes never reaches the
    /// pager (the swipe tests' known flake), so a swipe that moved nothing, no page and no request, is made again, up to
    /// three times in all. A swipe the pager took but got wrong still fails the test.
    @discardableResult
    private func swipeToNextSpace() -> Int {
        let before = (page, switchRequests)
        for attempt in 1...3 {
            point(0.85, 0.5).press(forDuration: 0.05, thenDragTo: point(0.1, 0.5), withVelocity: XCUIGestureVelocity(1500),
                                   thenHoldForDuration: 0)
            let deadline = Date.now.addingTimeInterval(3)
            repeat {
                if page != before.0 || switchRequests != before.1 {
                    print("swipe to the next Space: taken on attempt \(attempt)")
                    return attempt
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date.now < deadline
            print("swipe \(attempt) moved nothing: screen \(screen.frame), window \(window.frame), last input \(last), \(page)")
        }
        return 4
    }

    /// Their three Spaces (a desktop, two full-screen apps), a Mac that takes 0.6 s to switch: a swipe and the Spaces bar
    /// each switch it exactly once and the page stays; the page follows the Mac when someone switches there; with Drag
    /// to Scroll on and zoomed in, the bar still switches and the page still follows.
    func testSpacesFollowTheMacAndSwitchOnce() {
        launch(extra: ["-screenLayoutSpaces", "dff", "-screenLayoutSwitchMs", "600"])
        XCTAssertEqual(page, "page 1")
        swipeToNextSpace()
        XCTAssertTrue(waitFor("macSpace", "mac space 2"), "a swipe switches the Mac: \(macSpace)")
        XCTAssertEqual(page, "page 2", "and the page stays there")
        XCTAssertTrue(waitForShown("Space 2"), "Space 2 is on screen: \(shown)")
        XCTAssertTrue(waitFor("switchRequests", "switches 1"), "once: \(switchRequests)")

        control("Next Space").tap()
        XCTAssertTrue(waitFor("macSpace", "mac space 3"), "the Spaces bar switches the Mac: \(macSpace)")
        XCTAssertEqual(page, "page 3")
        XCTAssertTrue(waitForShown("Space 3"), "Space 3 is on screen: \(shown)")
        XCTAssertEqual(switchRequests, "switches 2")

        app.buttons["macSwitch"].tap()
        XCTAssertTrue(waitFor("page", "page 1"), "the page follows the Mac: \(page)")
        XCTAssertTrue(waitForShown("Space 1"), "Space 1 is on screen: \(shown)")
        XCTAssertEqual(switchRequests, "switches 2", "following the Mac asks it nothing")

        // Drag to Scroll: a drag scrolls the Mac, the bar still switches Spaces.
        toggleDragToScroll()
        control("Next Space").tap()
        XCTAssertTrue(waitFor("macSpace", "mac space 2"), "Drag to Scroll: the bar switches: \(macSpace)")
        XCTAssertTrue(waitFor("page", "page 2"))
        XCTAssertTrue(waitForShown("Space 2"), "Drag to Scroll: Space 2 is on screen: \(shown)")
        app.buttons["macSwitch"].tap()
        XCTAssertTrue(waitFor("page", "page 3"), "Drag to Scroll: the page follows the Mac: \(page)")
        XCTAssertTrue(waitForShown("Space 3"), "Drag to Scroll: Space 3 is on screen: \(shown)")
        toggleDragToScroll()

        // Zoomed in, on its side (upright the Spaces bar steps aside for a zoomed picture; on its side it stays in the
        // column): the bar switches and the new Space starts whole; the page follows the Mac too.
        turnLandscape()
        zoomIn("zoomed, before the bar")
        XCTAssertEqual(zoom, "zoomed")
        control("Previous Space").tap()
        XCTAssertTrue(waitFor("macSpace", "mac space 2"), "zoomed: the bar switches: \(macSpace)")
        XCTAssertTrue(waitFor("page", "page 2"))
        XCTAssertTrue(waitForShown("Space 2"), "zoomed: Space 2 is on screen: \(shown)")
        XCTAssertEqual(zoom, "whole", "the new Space starts whole")
        zoomIn("zoomed, before the Mac switches")
        app.buttons["macSwitch"].tap()
        XCTAssertTrue(waitFor("page", "page 3"), "zoomed: the page follows the Mac: \(page)")
        XCTAssertTrue(waitForShown("Space 3"), "zoomed: Space 3 is on screen: \(shown)")
        XCTAssertTrue(waitFor("zoom", "whole"), "the Space that came live starts whole, and the tab knows it")
        turnUpright()
        XCTAssertEqual(switchRequests, "switches 4")
    }

    /// The same pace as the Screen tab was before A1's fix (its body rebuilding with every reading), for comparison: it
    /// measures, and asserts only that the swipe and the step happened.
    func testSwitchingSpacesPaceAsBeforeA1() {
        launch(video: true, extra: ["-screenLayoutLive", "YES", "-screenLayoutSpaces", "dff", "-screenLayoutAsBeforeA1", "YES"])
        swipeToNextSpace()
        XCTAssertTrue(waitFor("macSpace", "mac space 2"))
        Thread.sleep(forTimeInterval: 1.2)
        let swipe = app.staticTexts["pacing"].label
        control("Next Space").tap()
        XCTAssertTrue(waitFor("macSpace", "mac space 3"))
        Thread.sleep(forTimeInterval: 1.2)
        let step = app.staticTexts["pacing"].label
        print("switching pace before A1's fix: swipe \(swipe); Spaces bar \(step); \(app.staticTexts["renders"].label)")
    }

    /// The pager's frames and hitches during a swipe and a Spaces-bar step, with the picture and the numbers changing
    /// 60 times a second (a hitch: a frame 1.5 refreshes or more after the one before).
    func testSwitchingSpacesKeepsThePace() {
        launch(video: true, extra: ["-screenLayoutLive", "YES", "-screenLayoutSpaces", "dff"])
        swipeToNextSpace()
        XCTAssertTrue(waitFor("macSpace", "mac space 2"))
        Thread.sleep(forTimeInterval: 1.2)
        let swipe = app.staticTexts["pacing"].label
        control("Next Space").tap()
        XCTAssertTrue(waitFor("macSpace", "mac space 3"))
        Thread.sleep(forTimeInterval: 1.2)
        let step = app.staticTexts["pacing"].label
        print("switching pace: swipe \(swipe); Spaces bar \(step); \(app.staticTexts["renders"].label)")
        // On this busy Mac the simulator's own pacing varies (0 to 4 hitches from run to run, either way): the test
        // asks that the pager moved and never stalled, and the numbers go in the report.
        for reading in [swipe, step] {
            let words = reading.split(separator: " ")
            let frames = words.dropFirst(2).first.flatMap { Int($0) } ?? 0
            let worst = words.dropFirst(6).first.flatMap { Int($0) } ?? 999
            XCTAssertGreaterThan(frames, 5, "the pager moved: \(reading)")
            XCTAssertLessThan(worst, 250, "no stall: \(reading)")
        }
    }

    /// Zoomed in, a double-tap and drag ends exactly where the finger lifts and doesn't pan the picture: the picture's
    /// frame follows the zoom, so its points are the display's.
    func testZoomedDoubleTapDragLandsExactly() {
        launch(video: true, extra: ["-screenGestureDoubleTapWindow", "5"])
        screen.pinch(withScale: 4, velocity: 3)
        settle()
        XCTAssertEqual(zoom, "zoomed")
        let zoomed = screen.frame
        let before = count
        point(0.47, 0.46).tap()
        point(0.47, 0.46).press(forDuration: 0.05, thenDragTo: point(0.53, 0.52), withVelocity: XCUIGestureVelocity(300),
                                thenHoldForDuration: 0.2)
        settle()
        XCTAssertEqual(last, "dragEnd", "a double-tap and drag drags")
        XCTAssertGreaterThanOrEqual(count, before + 4, "a click, a start, moves and an end")
        let landed = app.staticTexts["lastPoint"].label.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(landed.count, 2)
        if landed.count == 2 {
            XCTAssertEqual(landed[0], 0.53, accuracy: 0.003, "the drop is the display point under the finger (x)")
            XCTAssertEqual(landed[1], 0.52, accuracy: 0.003, "the drop is the display point under the finger (y)")
        }
        XCTAssertEqual(screen.frame.minX, zoomed.minX, accuracy: 1, "the drag didn't pan the picture")
        XCTAssertEqual(screen.frame.minY, zoomed.minY, accuracy: 1, "the drag didn't pan the picture")
    }

    /// The drag cue mid-drag, upright and on its side: double-tap, hold to pick up, drag slowly, then rest six seconds
    /// while `S/fix5-drag-shots.sh` takes the simulator's screen from outside. Only when the run asks for screenshots.
    func testDragCueShots() throws {
        guard ProcessInfo.processInfo.environment["SHOTS_DIR"] != nil else { throw XCTSkip("screenshots only when asked") }
        launch(extra: ["-screenGestureDoubleTapWindow", "5"])
        for landscape in [false, true] {
            if landscape { turnLandscape() }
            let start = point(0.3, 0.4)
            start.tap()
            start.press(forDuration: 1.2, thenDragTo: point(0.62, 0.58), withVelocity: XCUIGestureVelocity(120),
                        thenHoldForDuration: 6)
            settle()
            XCTAssertEqual(last, "dragEnd", "the drag ended (\(landscape ? "on its side" : "upright"))")
            Thread.sleep(forTimeInterval: 5.5)
        }
    }

    // MARK: Double-tap and hold: the pick-up, at a finger's timing

    /// The harness's live-drag counts: starts, moves, ends, moves to where the pointer already was (the phone's "still
    /// down" while a finger rests), and where the last drag started on the display.
    private func dragStats() -> (starts: Int, moves: Int, ends: Int, still: Int, from: String) {
        let words = app.staticTexts["dragStats"].label.split(separator: " ").map(String.init)
        func number(_ index: Int) -> Int { words.indices.contains(index) ? Int(words[index]) ?? -1 : -1 }
        return (number(1), number(2), number(3), number(5), words.indices.contains(7) ? words[7] : "none")
    }

    private var gestureTrace: String { app.staticTexts["gestureTrace"].label }

    /// How the drags so far started: picked up by a still hold, or by the finger moving first.
    private func dragStarts() -> (held: Int, moved: Int) {
        let words = app.staticTexts["dragStarts"].label.split(separator: " ").map(String.init)
        return (words.indices.contains(1) ? Int(words[1]) ?? -1 : -1, words.indices.contains(3) ? Int(words[3]) ?? -1 : -1)
    }

    /// Double-tap and hold, then drag, played with a finger's timing (XCUITest's own taps can't follow each other inside
    /// the real 0.4 s window): the second touch 0.15 s after the tap's lift, still for 1 s on a dock icon (a file) and
    /// for 5 s on a line of text, then moved and lifted, with the picture, the pointer and the numbers changing 60
    /// times a second. Each picks up while the finger rests, stays picked up through the rest (the phone's "still down"
    /// every second), drags and drops; none right-clicks.
    func testPickUpByHoldingAtAFingersTimingWhileLive() throws {
        guard SynthesizedGesture.isAvailable else { throw XCTSkip("XCTest's event records aren't there") }
        launch(video: true, extra: ["-screenLayoutLive", "YES"])
        // Upright the 16:10 picture fills the width and about 0.28–0.72 of the view's height.
        let cases: [(what: String, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat), hold: TimeInterval)] = [
            ("a dock icon (a file), held 1 s", (0.40, 0.69), (0.62, 0.47), 1.0),
            ("a line of text, held 5 s", (0.30, 0.41), (0.55, 0.43), 5.0),
        ]
        for item in cases {
            let before = dragStats()
            let startsBefore = dragStarts()
            let start = point(item.from.0, item.from.1).screenPoint
            let end = point(item.to.0, item.to.1).screenPoint
            try SynthesizedGesture.doubleTapHoldDrag(from: start, to: end, gap: 0.15, hold: item.hold, in: self)
            // The readout refreshes once a second.
            Thread.sleep(forTimeInterval: 1.6)
            let after = dragStats()
            let trace = gestureTrace
            print("pick-up, \(item.what): drags \(after) (before \(before)); inputs \(count), last \(last); trace: \(trace)")
            let starts = dragStarts()
            XCTAssertEqual(starts.held, startsBefore.held + 1, "\(item.what): picked up while the finger rested; \(trace)")
            XCTAssertEqual(starts.moved, startsBefore.moved, "\(item.what): not left to the move to start it; \(trace)")
            XCTAssertEqual(after.starts, before.starts + 1, "\(item.what): one drag; \(trace)")
            XCTAssertEqual(after.ends, before.ends + 1, "\(item.what): dropped on the lift; \(trace)")
            XCTAssertGreaterThan(after.moves - after.still, before.moves - before.still, "\(item.what): it dragged; \(trace)")
            if item.hold >= 5 {
                XCTAssertGreaterThanOrEqual(after.still - before.still, 3, "\(item.what): still down, every second; \(trace)")
            }
            XCTAssertFalse(trace.contains("right-click"), "\(item.what): no right-click; \(trace)")
        }
    }

    /// Diagnostics, run on demand (`TEST_RUNNER_PICKUP_DIAGNOSTICS=1`): which first taps of a double tap the picture
    /// sees, by the tap's length, with and without the live picture's load. It prints the gesture trace; it asserts
    /// nothing.
    func testPickUpDiagnostics() throws {
        guard ProcessInfo.processInfo.environment["PICKUP_DIAGNOSTICS"] == "1" else { throw XCTSkip("diagnostics on demand") }
        guard SynthesizedGesture.isAvailable else { throw XCTSkip("XCTest's event records aren't there") }
        for live in [true, false] {
            launch(video: true, extra: live ? ["-screenLayoutLive", "YES"] : [])
            Thread.sleep(forTimeInterval: 2)
            for (index, tap) in [0.05, 0.1, 0.15].enumerated() {
                let x = 0.25 + 0.2 * CGFloat(index)
                try SynthesizedGesture.doubleTapHoldDrag(from: point(x, 0.41).screenPoint, to: point(x + 0.1, 0.5).screenPoint,
                                                         tap: tap, gap: 0.15, hold: 1, in: self)
                Thread.sleep(forTimeInterval: 1.6)
                print("diagnostics: \(live ? "live" : "still"), first tap \(Int(tap * 1000)) ms: inputs \(count), last \(last); trace: \(gestureTrace)")
            }
            app.terminate()
        }
    }
}
