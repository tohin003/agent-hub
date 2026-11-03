#if DEBUG
import CoreVideo
import SwiftUI

/// For screenshots and UI tests (`-screenLayoutTest YES`, debug builds only): the Screen tab's own layout (the stage,
/// the controls in the navigation bar or beside the picture, the stream's numbers and the Spaces bar) around a made-up
/// Mac screen, in the same tabs and navigation stack, upright and on its side. Nothing connects; the sheets open with
/// nothing behind them. `-screenLayoutAspect 1.78` draws a wider display (the landscape overlay),
/// `-screenLayoutStart landscape` lays it on its side at once, `-screenLayoutSheet keyboard|sound` opens a sheet,
/// `-screenLayoutSwitchesOn YES` turns on Drag to Scroll and the privacy screen, `-screenLayoutVideo YES` shows the
/// picture through the video path (`VideoFeed`, `VideoSurfaceView`) with the Mac's pointer drawn here,
/// `-screenLayoutFrameLimit 30` shows the readout as when the hub holds the frame rate down, and `-harnessReadout YES`
/// shows what the picture sends, for the UI tests. With the live screen off, Keyboard asks to turn it on, as the tab
/// does.
struct ScreenLayoutHarness: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = HubStore()
    @State private var sound = MacAudioClient()
    @State private var section = 1
    @State private var scrollMode = false
    @State private var zoomed = false
    /// The pager and the made-up Mac's Spaces: the one it's on, and the switches asked of it.
    @State private var follower = SpaceFollower()
    @State private var macSpace = 0
    @State private var switchRequests = 0
    /// The window's safe area, for the tests that keep every control inside it.
    @State private var safeArea = EdgeInsets()
    @State private var quality = ScreenClient.Quality.balanced
    /// The Screen tab's own setting, so the options menu shows it as it is.
    @AppStorage("screen.smooth") private var smooth = false
    @State private var displayId: UInt32 = 1
    @State private var sharing = true
    @State private var privacy: Bool? = false
    @State private var playSound = false
    @State private var showingKeyboard = false
    @State private var showingControls = false
    @State private var askToTurnOn = false
    @State private var barsHidden = false
    @State private var inputs: [String] = []
    @State private var lastPoint = "none"
    /// Live-drag messages so far (starts, moves, ends, and moves to where the pointer already was: the phone's "still
    /// down" while a finger rests), and where the last drag started.
    @State private var drags = (starts: 0, moves: 0, ends: 0, still: 0)
    @State private var dragFrom = "none"
    /// The current Space's picture as decoded video, with the pointer (`-screenLayoutVideo YES`); nil: as an image.
    @State private var feed: VideoFeed?

    private let aspect: CGFloat
    private let image: UIImage
    private let readout = UserDefaults.standard.bool(forKey: "harnessReadout")
    /// `-screenLayoutLive YES`: the picture, the pointer and the numbers change 60 times a second, as a busy screen's do.
    private let liveMode = UserDefaults.standard.bool(forKey: "screenLayoutLive")
    /// `-screenLayoutAsBeforeA1 YES`: as the Screen tab was before fix 5's A1, the body reads the live numbers (so it
    /// rebuilds with each) and the controls get new bindings each build. Only to measure what the fix changed.
    private let asBeforeA1 = UserDefaults.standard.bool(forKey: "screenLayoutAsBeforeA1")
    @State private var live = HarnessLive()
    /// The made-up Mac's Spaces, "d" a desktop and "f" a full-screen app (`-screenLayoutSpaces dff`: theirs; by default
    /// two desktops and a full-screen Terminal), and how long it takes to switch (`-screenLayoutSwitchMs 600`).
    private let spaceKinds: [Bool] = {
        let asked = UserDefaults.standard.string(forKey: "screenLayoutSpaces") ?? "ddf"
        return asked.compactMap { $0 == "f" ? true : $0 == "d" ? false : nil }
    }()
    private let switchDelay = Duration.milliseconds(max(0, UserDefaults.standard.integer(forKey: "screenLayoutSwitchMs") > 0
        ? UserDefaults.standard.integer(forKey: "screenLayoutSwitchMs") : 600))
    private let stats = StreamStats(framesPerSecond: UserDefaults.standard.double(forKey: "screenLayoutFPS") > 0
                                        ? UserDefaults.standard.double(forKey: "screenLayoutFPS") : 12,
                                    megabitsPerSecond: 3.4, codec: "HEVC 4:4:4", path: "Direct",
                                            delayMs: 45,
                                            frameRateLimit: UserDefaults.standard.integer(forKey: "screenLayoutFrameLimit") > 0
                                                ? UserDefaults.standard.integer(forKey: "screenLayoutFrameLimit") : nil)

    init() {
        let asked = UserDefaults.standard.double(forKey: "screenLayoutAspect")
        aspect = asked > 0 ? asked : 16.0 / 10
        image = Self.makeImage(aspect: aspect)
        if UserDefaults.standard.bool(forKey: "screenLayoutVideo") { _feed = State(initialValue: Self.makeFeed(showing: image)) }
    }

    private var landscape: Bool { verticalSizeClass == .compact }

    private var display: DisplayInfo {
        DisplayInfo(id: 1, name: "Studio Display", width: 1600, height: 1600 / aspect, isMain: true, spaces: spaces)
    }

    /// The made-up Mac's Spaces, with the one it's on current.
    private var spaces: [SpaceInfo] { spaces(current: macSpace) }

    private func spaces(current: Int) -> [SpaceInfo] {
        let apps = ["Mail", "Terminal", "Xcode", "Safari", "Notes"]
        var fullScreen = 0
        return spaceKinds.enumerated().map { index, isFullscreen in
            defer { if isFullscreen { fullScreen += 1 } }
            return SpaceInfo(id: UInt64(index + 1), index: index, isFullscreen: isFullscreen, isCurrent: index == current,
                             title: isFullscreen ? apps[(spaceKinds.count == 3 && spaceKinds == [false, false, true] ? 1 : fullScreen) % apps.count] : nil)
        }
    }

    /// As the Screen tab does what its follower says, with the made-up Mac taking `switchDelay` to get there.
    private func act(_ action: SpaceFollower.Action) {
        guard case let .switchMac(index, _) = action else { return }
        switchRequests += 1
        // As the tab does: the new Space's page starts whole.
        zoomed = false
        PagerPacing.shared.asked()
        Task {
            try? await Task.sleep(for: switchDelay)
            macSpace = index
            act(follower.switched(spaces))
        }
    }

    /// Someone at the made-up Mac moves to its next Space (round to the first after the last).
    private func macSwitchesByItself() {
        macSpace = (macSpace + 1) % max(spaceKinds.count, 1)
        act(follower.received(spaces))
    }

    var body: some View {
        let _ = RenderCount.tick("tab")
        TabView(selection: $section) {
            Tab("Sessions", systemImage: "bubble.left.and.text.bubble.right", value: 0) {
                Text("Sessions")
            }
            Tab("Screen", systemImage: "display", value: 1) {
                NavigationStack {
                    ScreenStage(landscape: landscape, aspectRatio: display.aspectRatio, zoomed: zoomed, controls: controls,
                                // As the Screen tab: the live numbers are read by the readout alone.
                                stats: asBeforeA1 && liveMode
                                    ? StreamStatsView(stats: live.stats, roundTripMs: 18)
                                    : StreamStatsView(stats: stats, roundTripMs: 18,
                                                      live: liveMode ? { [live] in (stats: live.stats, roundTripMs: Double(18)) } : nil),
                                spaces: SpacesBar(spaces: spaces, current: follower.page, switching: follower.switching != nil,
                                                  onStep: step, onMissionControl: {})) {
                        pager
                    }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if !barsHidden { controls.toolbar }
                    }
                    .toolbarVisibility(zoomed || landscape ? .hidden : .automatic, for: .tabBar)
                    .onPreferenceChange(StageHidesBarsKey.self) { hidden in barsHidden = hidden }
                }
            }
            Tab("Mac", systemImage: "laptopcomputer", value: 2) {
                Text("Mac")
            }
        }
        .environment(store)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { safeArea = geometry.safeAreaInsets }
                    .onChange(of: geometry.safeAreaInsets) { _, insets in safeArea = insets }
            }
        }
        .alert("Turn on the live screen?", isPresented: $askToTurnOn) {
            Button("Turn On") {
                sharing = true
                showingKeyboard = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agent Hub records your Mac's screen while you watch it here, and stops when you leave or turn it off.")
        }
        .sheet(isPresented: $showingKeyboard) {
            MacKeyboardSheet(displayId: displayId)
                .environment(store)
                .presentationDetents([.height(320), .medium])
        }
        .sheet(isPresented: $showingControls) {
            MacControlsSheet(displayId: displayId, playSound: $playSound, sound: sound, sharing: sharing)
                .environment(store)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        // Upright, in the black above the picture; on its side, along the picture's top edge. Clear of every control.
        .overlay(alignment: .top) {
            if readout { readoutStrip.padding(.top, landscape ? 0 : 130) }
        }
        .task {
            let defaults = UserDefaults.standard
            _ = follower.received(spaces)
            if defaults.bool(forKey: "screenLayoutResetSmooth") { smooth = false }
            if liveMode { live.start(feed: feed, base: stats) }
            if defaults.bool(forKey: "screenLayoutSwitchesOn") {
                scrollMode = true
                privacy = true
            }
            try? await Task.sleep(for: .milliseconds(600))
            if defaults.string(forKey: "screenLayoutStart") == "landscape" { OrientationLock.shared.allowLandscape() }
            guard let sheet = defaults.string(forKey: "screenLayoutSheet") else { return }
            // After the turn has finished: a sheet asked for mid-turn may not appear.
            try? await Task.sleep(for: .seconds(3))
            showingKeyboard = sheet == "keyboard"
            showingControls = sheet == "sound"
        }
        // As the Screen tab does.
        .onChange(of: landscape) { zoomed = false }
        .onChange(of: section) { _, section in
            if section != 1 { OrientationLock.shared.standUpright() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { OrientationLock.shared.standUpright() }
        }
    }

    private var pager: some View {
        SpacesPager(follower: follower, onSettle: { page in act(follower.settled(on: page)) }) { space in
            let live = follower.isLive(space.id)
            let invites = follower.invitesSwitch(space.id)
            SpacePage(space: space, live: live, invitesSwitch: invites, snapshot: image, feed: feed) {
                RemoteScreenView(image: image, live: live, displayId: displayId, scrollMode: scrollMode,
                                 showsRail: !landscape, zoomed: $zoomed, video: live ? feed : nil,
                                 displayWidth: display.width, dimmed: invites) { input in
                    record(input)
                }
                .id(landscape)
            }
        }
    }

    private var controls: ScreenControls {
        ScreenControls(landscape: landscape, canRotate: OrientationLock.shared.canRotate, sharing: sharing,
                       privacy: privacy, soundPlaying: playSound, scrollMode: $scrollMode, displays: [display],
                       displayId: asBeforeA1 ? Binding(get: { displayId }, set: { displayId = $0 }) : $displayId,
                       quality: asBeforeA1 ? Binding(get: { quality }, set: { quality = $0 }) : $quality, smooth: $smooth,
                       rotate: {
                           if landscape { OrientationLock.shared.standUpright() } else { OrientationLock.shared.allowLandscape() }
                       },
                       toggleSharing: { sharing.toggle() },
                       setPrivacy: { on in privacy = on },
                       showKeyboard: {
                           if sharing { showingKeyboard = true } else { askToTurnOn = true }
                       },
                       showSoundAndBrightness: { showingControls = true },
                       missionControl: {},
                       refreshSpaces: {})
    }

    private var title: String {
        let space = spaces.first { $0.id == follower.page } ?? spaces[0]
        return space.title ?? "Desktop \(space.index + 1)"
    }

    private func step(_ direction: Int) {
        act(follower.step(direction))
    }

    private func record(_ input: ScreenInputParams) {
        switch input.action {
        case .click: inputs.append("click \(input.clickCount ?? 1)")
        case .scroll: inputs.append((input.dy ?? 0) < 0 ? "scroll down" : (input.dy ?? 0) > 0 ? "scroll up" : "scroll sideways")
        default: inputs.append(input.action.rawValue)
        }
        if let x = input.x, let y = input.y { lastPoint = String(format: "%.3f,%.3f", x, y) }
        switch input.action {
        case .dragStart:
            drags.starts += 1
            dragFrom = lastPoint
        case .dragMove:
            drags.moves += 1
            if lastPoint == dragFrom { drags.still += 1 }
        case .dragEnd:
            drags.ends += 1
        default:
            break
        }
    }

    /// What the picture sent, and a way out of the tab while its bar is hidden (as a notification would take you).
    private var readoutStrip: some View {
        HStack(spacing: 8) {
            Button("Leave Screen Tab") { section = 0 }
            Button("Mac Switches") { macSwitchesByItself() }
                .accessibilityIdentifier("macSwitch")
            Button("Reset Options") {
                quality = .balanced
                scrollMode = false
                smooth = false
            }
            .accessibilityIdentifier("resetOptions")
            Group {
                Text(inputs.last ?? "none").accessibilityIdentifier("lastInput")
                Text(lastPoint).accessibilityIdentifier("lastPoint")
                Text("\(inputs.count)").accessibilityIdentifier("inputCount")
                Text("drags \(drags.starts) \(drags.moves) \(drags.ends) still \(drags.still) from \(dragFrom)")
                    .accessibilityIdentifier("dragStats")
                Text(zoomed ? "zoomed" : "whole").accessibilityIdentifier("zoom")
                Text("page \(follower.page.map(String.init) ?? "none")").accessibilityIdentifier("page")
                Text("mac space \(macSpace + 1)").accessibilityIdentifier("macSpace")
                Text(String(format: "safe %.0f %.0f %.0f %.0f", safeArea.top, safeArea.leading, safeArea.bottom, safeArea.trailing))
                    .accessibilityIdentifier("safeArea")
                Text("switches \(switchRequests)").accessibilityIdentifier("switchRequests")
                Text(landscape ? "landscape" : "portrait").accessibilityIdentifier("layout")
                Text(smooth ? "smooth on" : "smooth off").accessibilityIdentifier("smooth")
                Text("quality \(quality.rawValue)").accessibilityIdentifier("quality")
                Text(scrollMode ? "scroll on" : "scroll off").accessibilityIdentifier("scroll")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let rates = RenderCount.perSecond()
                    Text("renders tab \(rates["tab"] ?? 0) controls \(rates["controls"] ?? 0) menu \(rates["menu"] ?? 0)")
                        .accessibilityIdentifier("renders")
                    let pacing = PagerPacing.shared.last
                    Text("pager frames \(pacing.frames) hitches \(pacing.hitches) worst \(Int(pacing.worstMs)) ms; \(PagerPacing.shared.release)")
                        .accessibilityIdentifier("pacing")
                    Text(PagerPacing.shared.trace.joined(separator: "; "))
                        .accessibilityIdentifier("pagerTrace")
                    Text(GestureTrace.shared.notes.joined(separator: "; "))
                        .accessibilityIdentifier("gestureTrace")
                    Text("held \(GestureTrace.shared.pickedUpByHolding) moved \(GestureTrace.shared.startedByMoving)")
                        .accessibilityIdentifier("dragStarts")
                }
            }
            .allowsHitTesting(false)
        }
        // One line, whatever the text size, from the leading edge (its buttons on screen): past the trailing edge its
        // labels are still there for the tests, and it never grows over the controls. `minWidth: 0` keeps the frame the
        // screen's width; without it, the frame takes the line's width and centres it, buttons off screen.
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .dynamicTypeSize(.small)
        .font(.caption2.monospaced())
        .padding(.horizontal, 6)
        .background(.background.opacity(0.8))
    }

    /// The picture as the video path shows it: the image as a decoded frame (BGRA, IOSurface-backed, as the decoder
    /// gives them), and the Mac's arrow over the window, as the hub sends its position and shape. The arrow is twice the
    /// standard size (as with a larger pointer in the Mac's Accessibility settings), so it's easy to find on a phone.
    private static func makeFeed(showing image: UIImage) -> VideoFeed? {
        guard let picture = image.cgImage else { return nil }
        let width = picture.width, height = picture.height
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let pixels = made else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let feed = VideoFeed(displayID: 1)
        feed.show(VideoDecoder.Picture(pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: pixels), width: width, height: height,
                                       decodeMs: 0))
        let size = CGSize(width: 34, height: 46)
        let arrow = UIGraphicsImageRenderer(size: size).image { _ in
            let corners: [CGPoint] = [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 38), CGPoint(x: 11, y: 30), CGPoint(x: 17, y: 44),
                                      CGPoint(x: 24, y: 41), CGPoint(x: 18, y: 28), CGPoint(x: 30, y: 28)]
            let path = UIBezierPath()
            path.move(to: corners[0])
            for corner in corners.dropFirst() { path.addLine(to: corner) }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 3
            UIColor.white.setStroke()
            path.stroke()
            UIColor.black.setFill()
            path.fill()
        }
        let shape = PointerShape(id: 1, image: arrow, size: size, hotSpot: CGPoint(x: 2, y: 2))
        feed.movePointer(to: CursorPositionMessage(displayID: 1, x: 0.42, y: 0.38, visible: true, shapeID: 1), shapes: [1: shape])
        return feed
    }

    /// A made-up Mac screen: wallpaper, a menu bar, a window and the Dock, over a faint grid so a zoom shows.
    private static func makeImage(aspect: CGFloat) -> UIImage {
        let size = CGSize(width: 1600, height: (1600 / aspect).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.10, green: 0.16, blue: 0.36, alpha: 1).cgColor,
                          UIColor(red: 0.42, green: 0.26, blue: 0.52, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                                     options: [])
            }
            UIColor(white: 1, alpha: 0.06).setFill()
            for x in stride(from: 0, to: size.width, by: 100) { context.fill(CGRect(x: x, y: 0, width: 2, height: size.height)) }
            for y in stride(from: 0, to: size.height, by: 100) { context.fill(CGRect(x: 0, y: y, width: size.width, height: 2)) }
            // The menu bar.
            UIColor(white: 1, alpha: 0.16).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 34))
            UIColor(white: 1, alpha: 0.85).setFill()
            for (index, width) in [26.0, 70, 46, 46, 60].enumerated() {
                context.fill(CGRect(x: 24 + Double(index) * 90, y: 12, width: width, height: 10))
            }
            // A window, as a terminal.
            let window = CGRect(x: 220, y: 110, width: 900, height: min(560, size.height - 260))
            UIColor(white: 0.12, alpha: 1).setFill()
            UIBezierPath(roundedRect: window, cornerRadius: 18).fill()
            for (index, color) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: window.minX + 22 + CGFloat(index) * 30, y: window.minY + 17,
                                            width: 18, height: 18)).fill()
            }
            UIColor(white: 0.75, alpha: 1).setFill()
            for (row, width) in [620.0, 480, 700, 300, 560, 640, 420, 520, 380, 600].enumerated()
            where 90 + Double(row) * 40 < window.height - 30 {
                context.fill(CGRect(x: window.minX + 40, y: window.minY + 90 + Double(row) * 40, width: width, height: 14))
            }
            // The Dock.
            let dock = CGRect(x: size.width / 2 - 360, y: size.height - 110, width: 720, height: 90)
            UIColor(white: 1, alpha: 0.25).setFill()
            UIBezierPath(roundedRect: dock, cornerRadius: 26).fill()
            let icons: [UIColor] = [.systemBlue, .systemGray, .systemOrange, .systemGreen, .systemPurple, .systemTeal,
                                    .systemPink, .systemIndigo, .systemYellow]
            for (index, color) in icons.enumerated() {
                color.setFill()
                UIBezierPath(roundedRect: CGRect(x: dock.minX + 20 + CGFloat(index) * 77, y: dock.minY + 12, width: 66,
                                                 height: 66), cornerRadius: 15).fill()
            }
        }
    }
}
/// The harness's busy screen (`-screenLayoutLive YES`): 60 times a second the numbers change, the picture is shown again
/// and the pointer moves, as with a video or a scroll on the Mac.
@Observable
final class HarnessLive {
    var stats = StreamStats()
    @ObservationIgnored private var running: Task<Void, Never>?

    func start(feed: VideoFeed?, base: StreamStats) {
        guard running == nil else { return }
        stats = base
        let picture = feed?.latest
        let size = feed?.size ?? .zero
        running = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                tick += 1
                guard let self else { return }
                self.stats.framesPerSecond = 55 + Double(tick % 6)
                self.stats.delayMs = 30 + Double(tick % 9)
                if let feed, let picture {
                    feed.show(VideoDecoder.Picture(pixelBuffer: picture, width: Int(size.width), height: Int(size.height), decodeMs: 0))
                    feed.movePointer(to: CursorPositionMessage(displayID: 1, x: 0.4 + 0.1 * sin(Double(tick) / 30),
                                                               y: 0.4, visible: true, shapeID: 1), shapes: [:])
                }
            }
        }
    }
}
#endif
