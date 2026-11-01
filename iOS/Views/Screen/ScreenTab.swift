import SwiftUI

/// Your Mac's screen, live. Swipe sideways to move between Spaces (each full-screen session window is a Space),
/// tap to click, touch and hold to right-click, pinch to zoom in on a small button.
struct ScreenTab: View {
    var isActive: Bool
    @Environment(HubStore.self) private var store
    @State private var screen = ScreenClient()
    @State private var displays: [DisplayInfo] = []
    @State private var displayId: UInt32?
    @State private var pageId: UInt64?
    @State private var programmaticPage = false
    @State private var snapshots: [UInt64: UIImage] = [:]
    @State private var showingKeyboard = false
    @State private var scrollMode = false
    @State private var zoomed = false
    @State private var switching = false
    @State private var clicks = 0
    @State private var askToTurnOn = false
    @State private var afterTurningOn: (() -> Void)?
    @State private var turningOn = false

    private var sharing: Bool { store.screenSharing }

    private var display: DisplayInfo? { displays.first { $0.id == displayId } ?? displays.first }

    private var pages: [SpaceInfo] {
        guard let display else { return [] }
        return display.spaces.isEmpty ? [SpaceInfo(id: 0, index: 0, isFullscreen: false, isCurrent: true, title: display.name)] : display.spaces
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(pageTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .toolbarVisibility(zoomed ? .hidden : .automatic, for: .tabBar)
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
        .task(id: isActive && store.isConnected && sharing) {
            if isActive && store.isConnected && sharing {
                await loadDisplays()
                await startStream()
            } else {
                screen.stop()
            }
        }
        .onChange(of: screen.frames[display?.id ?? 0]) { _, image in
            if let image, let current = display?.spaces.first(where: \.isCurrent) { snapshots[current.id] = image }
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
        } else if let error = screen.error, screen.frames.isEmpty {
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
            pager(display)
                .safeAreaBar(edge: .bottom) {
                    if !zoomed { SpacesBar(spaces: pages, current: pageId, switching: switching, onStep: step, onMissionControl: missionControl) }
                }
        } else {
            ProgressView("Looking at your Mac…")
        }
    }

    private func pager(_ display: DisplayInfo) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages) { space in
                    let live = space.isCurrent || display.spaces.isEmpty
                    RemoteScreenView(image: live ? screen.frames[display.id] : (snapshots[space.id] ?? screen.frames[display.id]),
                                     live: live, displayId: display.id, scrollMode: scrollMode, zoomed: $zoomed) { input in
                        clicks += 1
                        Task { await send(input) }
                    }
                    .overlay(alignment: .top) {
                        if !live {
                            Label("Swipe here to switch the Mac to this Space", systemImage: "hand.draw")
                                .font(.footnote)
                                .padding(8)
                                .glassEffect(.regular, in: .capsule)
                                .padding(.top, 8)
                        }
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageId)
        .scrollDisabled(zoomed || pages.count < 2)
        .scrollIndicators(.hidden)
        .onChange(of: pageId) { old, new in
            guard old != nil, let new, !programmaticPage else {
                programmaticPage = false
                return
            }
            guard let target = pages.first(where: { $0.id == new }), !target.isCurrent else { return }
            Task { await switchSpace(to: target.index) }
        }
    }

    private var pageTitle: String {
        guard let display else { return "Screen" }
        let space = pages.first { $0.id == pageId } ?? pages.first { $0.isCurrent }
        if let space, space.isFullscreen, let title = space.title { return title }
        if let space, pages.count > 1 { return "Desktop \(space.index + 1)" }
        return display.name
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if screen.streaming {
                Label("\(Int(screen.framesPerSecond.rounded())) fps", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(sharing ? "Turn Off Live Screen" : "Turn On Live Screen",
                   systemImage: sharing ? "video.fill" : "video.slash") {
                if sharing {
                    Task {
                        screen.stop()
                        _ = await store.setScreenSharing(false)
                    }
                } else {
                    Task { await turnOn() }
                }
            }
            .tint(sharing ? .red : nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Keyboard", systemImage: "keyboard") { whenSharing { showingKeyboard = true } }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("Screen Options", systemImage: "slider.horizontal.3") {
                if displays.count > 1 {
                    Picker("Display", selection: Binding(get: { displayId ?? displays.first?.id ?? 0 }, set: { id in
                        displayId = id
                        Task { await startStream() }
                    })) {
                        ForEach(displays) { display in
                            Label(display.name, systemImage: display.isMain ? "display" : "display.2").tag(display.id)
                        }
                    }
                }
                Picker("Quality", selection: Binding(get: { screen.quality }, set: { quality in
                    screen.quality = quality
                    Task { try? await screen.switchDisplay(display?.id) }
                })) {
                    ForEach(ScreenClient.Quality.allCases) { quality in Text(quality.title).tag(quality) }
                }
                Toggle("Drag to Scroll", systemImage: "scroll", isOn: $scrollMode)
                Button("Mission Control", systemImage: "rectangle.3.group") { whenSharing { missionControl() } }
                Button("Refresh Spaces", systemImage: "arrow.clockwise") { whenSharing { Task { await loadDisplays() } } }
            }
        }
    }

    // MARK: Actions

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

    private func apply(_ list: [DisplayInfo]) {
        displays = list
        if displayId == nil || !list.contains(where: { $0.id == displayId }) { displayId = list.first?.id }
        let current = display?.spaces.first(where: \.isCurrent)?.id ?? pages.first?.id
        if pageId != current {
            programmaticPage = true
            withAnimation(.snappy) { pageId = current }
        }
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
        do {
            try await store.client.send(Method.screenInput, input)
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    private func switchSpace(to index: Int) async {
        guard let display else { return }
        switching = true
        defer { switching = false }
        do {
            let list: [DisplayInfo] = try await store.client.request(Method.screenSpace,
                                                                     ScreenSpaceParams(displayId: display.id, targetIndex: index),
                                                                     timeout: .seconds(20))
            apply(list)
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            await loadDisplays()
        }
    }

    private func step(_ direction: Int) {
        guard let display else { return }
        if display.spaces.isEmpty {
            Task {
                switching = true
                let list: [DisplayInfo]? = try? await store.client.request(Method.screenSpace, ScreenSpaceParams(displayId: display.id, step: direction))
                if let list { apply(list) }
                switching = false
            }
            return
        }
        guard let current = pages.firstIndex(where: { $0.id == pageId }) ?? pages.firstIndex(where: \.isCurrent) else { return }
        let target = min(max(current + direction, 0), pages.count - 1)
        guard target != current else { return }
        withAnimation(.snappy) { pageId = pages[target].id }
    }

    private func missionControl() {
        guard let display else { return }
        Task { await store.perform { try await store.client.send(Method.screenSpace, ScreenSpaceParams(displayId: display.id, missionControl: true)) } }
    }
}

/// The Spaces strip: previous and next, and a dot per Space with the current one filled.
struct SpacesBar: View {
    var spaces: [SpaceInfo]
    var current: UInt64?
    var switching: Bool
    var onStep: (Int) -> Void
    var onMissionControl: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button("Previous Space", systemImage: "chevron.left") { onStep(-1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                HStack(spacing: 7) {
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
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement()
                .accessibilityLabel("Space \((spaces.firstIndex { $0.id == current } ?? 0) + 1) of \(spaces.count)")
                Button("Next Space", systemImage: "chevron.right") { onStep(1) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                Button("Mission Control", systemImage: "rectangle.3.group", action: onMissionControl)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .padding(.bottom, 8)
    }
}
