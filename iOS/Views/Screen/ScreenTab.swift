import SwiftUI

/// Your Mac's screen, live. Swipe sideways to move between Spaces (each full-screen session window is a Space),
/// tap to click, touch and hold (or tap with two fingers) to right-click, pinch to zoom in on a small button, and
/// drag the thin bar on the right to scroll. The speaker button holds the Mac's volume and brightness, and plays the
/// Mac's sound here. Landscape lays the phone on its side for a bigger picture, with every control beside it
/// (`ScreenStage`); the rest of the app stays upright.
struct ScreenTab: View {
    var isActive: Bool
    @Environment(HubStore.self) private var store
    @State private var screen = ScreenClient()
    @State private var displays: [DisplayInfo] = []
    @State private var displayId: UInt32?
    /// Which Space's page shows, and when the Mac switches (`SpaceFollower`).
    @State private var follower = SpaceFollower()
    /// Each Space's latest still, refreshed while it's live, for its page when it isn't.
    @State private var snapshots: [UInt64: UIImage] = [:]
    /// The still before each Space's latest, and when the latest was taken: a still taken just before the Mac switched
    /// by itself may already show the next Space.
    @State private var olderSnapshots: [UInt64: (image: UIImage, taken: ContinuousClock.Instant)] = [:]
    @State private var showingKeyboard = false
    @State private var scrollMode = false
    @State private var zoomed = false
    /// The hub rejected a live drag (it's older than double-tap and drag): drags go as one, from `oneShotDragStart`.
    @State private var oneShotDrags = false
    @State private var oneShotDragStart: ScreenInputParams?
    @State private var clicks = 0
    @State private var askToTurnOn = false
    @State private var afterTurningOn: (() -> Void)?
    @State private var turningOn = false
    @State private var sound = MacAudioClient()
    @State private var showingControls = false
    /// The stage has the navigation bar hidden (on its side, with the picture up).
    @State private var barsHidden = false
    @AppStorage("screen.playMacSound") private var playSound = false
    /// Set in the sound sheet; the sync rule follows it (`MediaSync`).
    @AppStorage("screen.lipSync") private var lipSync = false
    /// Set in Screen Options; the picture's timing follows it (`VideoFeed.smooth`).
    @AppStorage("screen.smooth") private var smooth = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var sharing: Bool { store.screenSharing }

    /// On its side: the picture fills the height and the controls stand beside it.
    private var landscape: Bool { verticalSizeClass == .compact }

    private var display: DisplayInfo? { displays.first { $0.id == displayId } ?? displays.first }

    private var pages: [SpaceInfo] {
        guard let display else { return [] }
        return display.spaces.isEmpty ? [SpaceInfo(id: 0, index: 0, isFullscreen: false, isCurrent: true, title: display.name)] : display.spaces
    }

    var body: some View {
        let _ = RenderCount.tick("tab")
        NavigationStack {
            content
                .navigationTitle(pageTitle)
                .navigationBarTitleDisplayMode(.inline)
                // Out of the hidden bar while the controls stand beside the picture (`StageHidesBarsKey`).
                .toolbar {
                    if !barsHidden { controls.toolbar }
                }
                .toolbarVisibility(zoomed || landscape ? .hidden : .automatic, for: .tabBar)
                .onPreferenceChange(StageHidesBarsKey.self) { hidden in barsHidden = hidden }
        }
        .alert("Turn on the live screen?", isPresented: $askToTurnOn) {
            Button("Turn On") { Task { await turnOn() } }
            Button("Cancel", role: .cancel) { afterTurningOn = nil }
        } message: {
            Text("Agent Hub records your Mac's screen while you watch it here, and stops when you leave or turn it off.")
        }
        .sheet(isPresented: $showingKeyboard) {
            if let display {
                MacKeyboardSheet(displayId: display.id)
                    .presentationDetents([.height(320), .medium])
            }
        }
        .sheet(isPresented: $showingControls) {
            MacControlsSheet(displayId: display?.id, playSound: $playSound, sound: sound, sharing: sharing)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        // In the background the picture pauses; the Mac's sound, if it's on, plays on.
        .task(id: isActive && store.isConnected && sharing && scenePhase != .background) {
            if isActive && store.isConnected && sharing && scenePhase != .background {
                await loadDisplays()
                await startStream()
            } else {
                screen.stop()
            }
        }
        .onChange(of: lipSync, initial: true) { _, on in MediaSync.shared.lipSync = on }
        .onChange(of: smooth, initial: true) { _, on in VideoFeed.smooth = on }
        .onChange(of: screen.quality) { Task { try? await screen.switchDisplay(display?.id) } }
        // The hub it reconnects to may be newer: live drags again.
        .onChange(of: store.isConnected) { oneShotDrags = false }
        .task(id: isActive && store.isConnected && sharing && playSound) {
            if isActive && store.isConnected && sharing && playSound, let host = store.connectedHost {
                sound.start(settings: store.settings, host: host)
            } else {
                sound.stop()
            }
        }
        // Whoever switched the Mac's Space (someone at the Mac, or another phone), the page follows.
        .onChange(of: screen.spacesUpdate) { _, update in
            if let update { apply(update.displays) }
        }
        // The live Space's still, every two seconds, for its page once it isn't live (full-screen apps' too).
        .task(id: follower.current) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                snapshotLiveSpace()
            }
        }
        // A turn starts the picture over at its whole size, in its new shape.
        .onChange(of: landscape) { zoomed = false }
        // The rest of the app stands upright: leaving the tab, or the app, turns it back.
        .onChange(of: isActive) { _, active in
            if !active { OrientationLock.shared.standUpright() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { OrientationLock.shared.standUpright() }
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: clicks)
    }

    @ViewBuilder private var content: some View {
        if !store.isConnected {
            NotConnectedView()
        } else if !sharing {
            ContentUnavailableView {
                Label("Live Screen Is Off", systemImage: "video.slash")
            } description: {
                Text("Agent Hub isn't recording your Mac's screen. Turn it on to see it and tap on it from here.")
            } actions: {
                Button {
                    Task { await turnOn() }
                } label: {
                    if turningOn { ProgressView() } else { Text("Turn On Live Screen") }
                }
                .buttonStyle(.glassProminent)
                .disabled(turningOn)
            }
        } else if let error = screen.error, !screen.hasPicture {
            ContentUnavailableView {
                Label("Screen Unavailable", systemImage: "display.trianglebadge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Ask the Mac for Permission") {
                    Task { await store.perform { try await store.client.send(Method.macPermission, PermissionParams(kind: "screen")) } }
                }
                Button("Try Again") { Task { await startStream() } }
                    .buttonStyle(.glassProminent)
            }
        } else if let display {
            // The live numbers are read by the readout alone (`StreamStatsView.live`): read here, every change rebuilt the
            // whole tab, the Screen Options menu with it, and an open menu then lost the tap under the finger.
            ScreenStage(landscape: landscape, aspectRatio: display.aspectRatio, zoomed: zoomed, controls: controls,
                        stats: screen.streaming ? StreamStatsView(stats: StreamStats(), live: { [screen, store] in
                            (screen.stats, screen.stats.roundTripMs ?? store.client.latency.map { $0 / .milliseconds(1) })
                        }) : nil,
                        spaces: SpacesBar(spaces: pages, current: follower.page, switching: follower.switching != nil,
                                          onStep: step, onMissionControl: missionControl)) {
                pager(display)
            }
        } else {
            ProgressView("Looking at your Mac…")
        }
    }

    private func pager(_ display: DisplayInfo) -> some View {
        SpacesPager(follower: follower, onSettle: { page in act(follower.settled(on: page)) }) { space in
            let live = display.spaces.isEmpty || follower.isLive(space.id)
            let invites = !display.spaces.isEmpty && follower.invitesSwitch(space.id)
            SpacePage(space: space, live: live, invitesSwitch: invites, snapshot: snapshots[space.id],
                      feed: screen.feeds[display.id]) {
                RemoteScreenView(image: live ? screen.frames[display.id] : snapshots[space.id],
                                 live: live, displayId: display.id, scrollMode: scrollMode, showsRail: !landscape,
                                 zoomed: $zoomed,
                                 video: live ? screen.feeds[display.id] : nil,
                                 displayWidth: display.width,
                                 onViewport: live ? { visible in screen.setViewport(visible, display: display.id) } : nil,
                                 dimmed: invites) { input in
                    if input.action == .click { clicks += 1 }
                    Task { await send(input) }
                }
                // A fresh view when the phone turns, so the zoom starts over in the new shape. (Not when the page comes
                // live or goes: rebuilt while the pager scrolled, the old picture stayed drawn over the new page. The
                // picture starts whole again by itself then.)
                .id(landscape)
            }
        }
    }

    private var pageTitle: String {
        guard let display else { return "Screen" }
        let space = pages.first { $0.id == follower.page } ?? pages.first { $0.isCurrent }
        if let space, space.isFullscreen, let title = space.title { return title }
        if let space, pages.count > 1 { return "Desktop \(space.index + 1)" }
        return display.name
    }

    /// The tab's controls, for the navigation bar in portrait and the column beside the picture in landscape.
    private var controls: ScreenControls {
        ScreenControls(landscape: landscape, canRotate: OrientationLock.shared.canRotate, sharing: sharing,
                       privacy: store.privacyScreen, soundPlaying: sound.playing, scrollMode: $scrollMode,
                       displays: displays,
                       displayId: Binding(get: { displayId ?? displays.first?.id ?? 0 }, set: { id in
                           displayId = id
                           Task { await startStream() }
                       }),
                       // A binding SwiftUI can tell is the same from one build to the next (a new Binding(get:set:)
                       // each time made the open menu update under the finger); the stream follows in onChange.
                       quality: $screen.quality,
                       smooth: $smooth,
                       rotate: rotate,
                       toggleSharing: toggleSharing,
                       setPrivacy: { on in Task { await store.setPrivacyScreen(on) } },
                       showKeyboard: { whenSharing { showingKeyboard = true } },
                       showSoundAndBrightness: { showingControls = true },
                       missionControl: { whenSharing { missionControl() } },
                       refreshSpaces: { whenSharing { Task { await loadDisplays() } } })
    }

    // MARK: Actions

    /// On its side, or upright again.
    private func rotate() {
        if landscape {
            OrientationLock.shared.standUpright()
        } else {
            OrientationLock.shared.allowLandscape()
        }
    }

    private func toggleSharing() {
        if sharing {
            Task {
                screen.stop()
                _ = await store.setScreenSharing(false)
            }
        } else {
            Task { await turnOn() }
        }
    }

    /// Runs an action that needs the live screen; while it's off, asks to turn it on first, then carries on.
    private func whenSharing(_ action: @escaping () -> Void) {
        if sharing {
            action()
        } else {
            afterTurningOn = action
            askToTurnOn = true
        }
    }

    private func turnOn() async {
        turningOn = true
        defer { turningOn = false }
        guard await store.setScreenSharing(true) else { return }
        let next = afterTurningOn
        afterTurningOn = nil
        next?()
    }

    private func loadDisplays() async {
        guard let list: [DisplayInfo] = try? await store.client.request(Method.screenDisplays, Empty()) else { return }
        apply(list)
    }

    /// The Mac's displays and Spaces as they are now: the page follows its current Space (unless a switch the phone
    /// asked for is on its way).
    private func apply(_ list: [DisplayInfo]) {
        displays = list
        if displayId == nil || !list.contains(where: { $0.id == displayId }) { displayId = list.first?.id }
        // The Mac switched by itself: the still taken in the second before may be mid-slide, so the one before stands.
        if follower.switching == nil, let left = follower.current, !pages.contains(where: { $0.id == left && $0.isCurrent }),
           let older = olderSnapshots[left], ContinuousClock.now - older.taken < .seconds(1) {
            snapshots[left] = older.image
        }
        act(follower.received(pages))
    }

    /// Does what the follower says: the pager follows `follower.page` by itself; a switch goes to the Mac.
    private func act(_ action: SpaceFollower.Action) {
        guard case let .switchMac(index, _) = action, let display else { return }
        // The Space being left keeps a still of how it looked; zoomed in, the hub goes back to the whole display once,
        // now, and the new Space's page starts whole.
        snapshotLiveSpace()
        if zoomed {
            screen.setViewport(nil, display: display.id, immediately: true)
            zoomed = false
        }
        Task {
            do {
                let list: [DisplayInfo] = try await store.client.request(Method.screenSpace,
                                                                         ScreenSpaceParams(displayId: display.id, targetIndex: index),
                                                                         timeout: .seconds(20))
                displays = list
                act(follower.switched(pages))
            } catch {
                store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
                act(follower.switched(nil))
                await loadDisplays()
            }
        }
    }

    /// A still of the live Space, for its page once it isn't live. Not while a switch is on its way: the picture may
    /// already be the next Space's.
    private func snapshotLiveSpace() {
        guard let display, follower.switching == nil, let current = follower.current,
              let still = screen.snapshot(display: display.id) else { return }
        if let previous = snapshots[current] { olderSnapshots[current] = (previous, .now) }
        snapshots[current] = still
    }

    private func startStream() async {
        guard let host = store.connectedHost else { return }
        if screen.streaming {
            try? await screen.switchDisplay(display?.id)
        } else {
            await screen.start(settings: store.settings, host: host, display: display?.id)
        }
    }

    private func send(_ input: ScreenInputParams) async {
        let liveDrag = [.dragStart, .dragMove, .dragEnd].contains(input.action)
        if liveDrag, oneShotDrags {
            await sendAsOneDrag(input)
            return
        }
        do {
            try await store.client.send(Method.screenInput, input)
        } catch let error as WireError where liveDrag && error.code == WireError.badRequest("").code {
            // A hub from before live drags: from now on a drag goes as one, when it ends.
            oneShotDrags = true
            await sendAsOneDrag(input)
        } catch {
            // One message for a drag, not one for each move.
            guard input.action != .dragMove, input.action != .dragEnd else { return }
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    /// A live drag for a hub that knows only the one-shot drag: its start kept, and one drag from there at its end.
    private func sendAsOneDrag(_ input: ScreenInputParams) async {
        switch input.action {
        case .dragStart:
            oneShotDragStart = input
        case .dragEnd:
            guard let start = oneShotDragStart else { return }
            oneShotDragStart = nil
            await send(ScreenInputParams(displayId: input.displayId, action: .drag, x: start.x, y: start.y,
                                         toX: input.x, toY: input.y))
        default:
            break
        }
    }

    /// The Spaces bar: the page goes at once, zoomed in or in Drag to Scroll too, and the Mac follows.
    private func step(_ direction: Int) {
        guard let display else { return }
        if display.spaces.isEmpty {
            // A Mac whose Spaces can't be listed: the keys, and its word for where it is.
            Task {
                let list: [DisplayInfo]? = try? await store.client.request(Method.screenSpace, ScreenSpaceParams(displayId: display.id, step: direction))
                if let list { apply(list) }
            }
            return
        }
        act(follower.step(direction))
    }

    private func missionControl() {
        guard let display else { return }
        Task { await store.perform { try await store.client.send(Method.screenSpace, ScreenSpaceParams(displayId: display.id, missionControl: true)) } }
    }
}

/// The Spaces strip: previous and next, and a dot per Space with the current one filled. Across the bottom in
/// portrait; down the margin in landscape, where Mission Control is in Screen Options.
struct SpacesBar: View {
    var spaces: [SpaceInfo]
    var current: UInt64?
    var switching: Bool
    var axis: Axis = .horizontal
    var onStep: (Int) -> Void
    var onMissionControl: () -> Void

    var body: some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 8))
        GlassEffectContainer(spacing: 10) {
            stack {
                Button("Previous Space", systemImage: "chevron.left") { onStep(-1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityShowsLargeContentViewer()
                dots
                Button("Next Space", systemImage: "chevron.right") { onStep(1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityShowsLargeContentViewer()
                if axis == .horizontal {
                    Button("Mission Control", systemImage: "rectangle.3.group", action: onMissionControl)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityShowsLargeContentViewer()
                }
            }
        }
        // The glyphs grow with the text up to what a 44-point circle holds; beyond that the large content viewer
        // shows them, as in the system's bars.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.bottom, axis == .horizontal ? 8 : 0)
    }

    private var dots: some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 7)) : AnyLayout(VStackLayout(spacing: 7))
        return stack {
            ForEach(spaces) { space in
                Group {
                    if space.isFullscreen {
                        RoundedRectangle(cornerRadius: 2).frame(width: 12, height: 8)
                    } else {
                        Circle().frame(width: 8, height: 8)
                    }
                }
                .foregroundStyle(space.id == current ? Color.primary : Color.secondary.opacity(0.4))
            }
            if switching { ProgressView().controlSize(.mini) }
        }
        .padding(axis == .horizontal ? .horizontal : .vertical, axis == .horizontal ? 14 : 12)
        .frame(width: axis == .vertical ? 44 : nil, height: axis == .horizontal ? 44 : nil)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel("Space \((spaces.firstIndex { $0.id == current } ?? 0) + 1) of \(spaces.count)")
    }
}
