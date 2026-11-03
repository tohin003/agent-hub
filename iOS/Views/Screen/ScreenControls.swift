import SwiftUI

/// The Screen tab's controls, defined once for both arrangements so they can't drift apart: the navigation bar in
/// portrait, and a glass column beside the picture in landscape. Each control has the same name, symbol, state and
/// action in both, and the same name for VoiceOver.
struct ScreenControls {
    enum Item: Hashable {
        case orientation, liveScreen, privacy, keyboard, sound, scrollMode, options
    }

    /// The Screen tab is laid on its side.
    var landscape: Bool
    /// Whether the app turns when asked (an iPhone).
    var canRotate: Bool
    /// Whether the live screen is on.
    var sharing: Bool
    /// Whether the Mac's privacy screen is up; nil when the hub has none.
    var privacy: Bool?
    /// The Mac's sound is playing on this phone.
    var soundPlaying: Bool
    @Binding var scrollMode: Bool
    var displays: [DisplayInfo]
    @Binding var displayId: UInt32
    @Binding var quality: ScreenClient.Quality
    /// Smooth: frames at an even pace, a little later.
    @Binding var smooth: Bool
    var rotate: () -> Void
    var toggleSharing: () -> Void
    var setPrivacy: (Bool) -> Void
    var showKeyboard: () -> Void
    var showSoundAndBrightness: () -> Void
    var missionControl: () -> Void
    var refreshSpaces: () -> Void

    /// The privacy switch shows while the live screen is on, and while the Mac is still covered.
    var showsPrivacy: Bool { privacy == true || (privacy != nil && sharing) }

    /// The landscape column, top to bottom: the way back upright first, then the screen, input and sound.
    var columnItems: [Item] {
        var items: [Item] = canRotate ? [.orientation] : []
        items.append(.liveScreen)
        if showsPrivacy { items.append(.privacy) }
        items += [.keyboard, .sound, .scrollMode, .options]
        return items
    }

    /// The navigation bar's controls in portrait. The stream's numbers sit in a line under it, where they fit whole.
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { control(.sound) }
        if canRotate {
            ToolbarItem(placement: .topBarLeading) { control(.orientation) }
        }
        ToolbarItem(placement: .primaryAction) { control(.liveScreen) }
        if showsPrivacy {
            ToolbarItem(placement: .primaryAction) { control(.privacy).toggleStyle(.button) }
        }
        ToolbarItem(placement: .primaryAction) { control(.keyboard) }
        ToolbarItem(placement: .primaryAction) { control(.options) }
    }

    /// One control, unstyled: the toolbar and the column each dress it their own way.
    @ViewBuilder func control(_ item: Item) -> some View {
        let _ = RenderCount.tick("controls")
        switch item {
        case .orientation:
            Button(landscape ? "Portrait" : "Landscape",
                   systemImage: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate", action: rotate)
                .accessibilityHint(landscape ? "Stands the app upright again."
                                             : "Turns the app on its side, so your Mac's screen fills it.")
        case .liveScreen:
            Button(sharing ? "Turn Off Live Screen" : "Turn On Live Screen",
                   systemImage: sharing ? "video.fill" : "video.slash", action: toggleSharing)
                .tint(sharing ? .red : nil)
        case .privacy:
            Toggle("Privacy Screen", systemImage: "lock.display",
                   isOn: Binding(get: { privacy == true }, set: { on in setPrivacy(on) }))
                .accessibilityHint("Covers your Mac's screen with a message while you control it from here. At the Mac, Touch ID or your password takes it down.")
        case .keyboard:
            Button("Keyboard", systemImage: "keyboard", action: showKeyboard)
        case .sound:
            Button("Sound and Brightness", systemImage: soundPlaying ? "speaker.wave.2.fill" : "speaker.wave.2",
                   action: showSoundAndBrightness)
                .accessibilityValue(soundPlaying ? "The Mac's sound is playing here" : "")
        case .scrollMode:
            Toggle("Drag to Scroll", systemImage: "scroll", isOn: $scrollMode)
                .accessibilityHint("Dragging on the picture scrolls your Mac.")
        case .options:
            Menu("Screen Options", systemImage: "slider.horizontal.3") { options }
        }
    }

    @ViewBuilder private var options: some View {
        let _ = RenderCount.tick("menu")
        if displays.count > 1 {
            Picker("Display", selection: $displayId) {
                ForEach(displays) { display in
                    Label(display.name, systemImage: display.isMain ? "display" : "display.2").tag(display.id)
                }
            }
        }
        Picker("Quality", selection: $quality) {
            ForEach(ScreenClient.Quality.allCases) { quality in Text(quality.title).tag(quality) }
        }
        Toggle(isOn: $smooth) {
            Text("Smooth Motion")
            Text("Evens out stutter, a refresh later.")
        }
        Toggle("Drag to Scroll", systemImage: "scroll", isOn: $scrollMode)
        Button("Mission Control", systemImage: "rectangle.3.group", action: missionControl)
        Button("Refresh Spaces", systemImage: "arrow.clockwise", action: refreshSpaces)
    }
}

/// The controls down a landscape margin: a 44-point glass circle each, icon only (VoiceOver and the large content
/// viewer still have the names). A switch that's on shows filled, on Starlight glass. On a short screen they close
/// up, and scroll if even that's too tall.
struct ScreenControlColumn: View {
    var controls: ScreenControls

    var body: some View {
        ViewThatFits(in: .vertical) {
            column(spacing: 8)
            column(spacing: 3)
            ScrollView {
                column(spacing: 8)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .buttonStyle(ColumnButtonStyle())
        .toggleStyle(ColumnToggleStyle())
        .labelStyle(.iconOnly)
        .tint(.primary)
        // The glyphs grow with the text up to what a 44-point circle holds; beyond that the large content viewer
        // shows them, as in the system's bars.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func column(spacing: CGFloat) -> some View {
        GlassEffectContainer(spacing: spacing) {
            VStack(spacing: spacing) {
                ForEach(controls.columnItems, id: \.self) { item in
                    controls.control(item)
                        .accessibilityShowsLargeContentViewer()
                }
            }
        }
    }
}

/// A column button: its icon centred in a 44-point glass circle, all of which takes the tap.
private struct ColumnButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.tint))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
    }
}

/// A column switch: a column button that flips it, filled and on Starlight glass while it's on (not by colour alone).
private struct ColumnToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .symbolVariant(configuration.isOn ? .fill : .none)
        }
        .buttonStyle(ColumnButtonStyle(isOn: configuration.isOn))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
