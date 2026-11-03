import SwiftUI

/// The Screen tab around the picture.
/// - Portrait: the stream's numbers in a line above the picture and the Spaces bar below it; the controls are in the
///   navigation bar.
/// - Landscape: the bars give way and the picture fills the height. The controls stand in a glass column in one
///   margin and the numbers and Spaces in the other, inside the safe area (clear of the Dynamic Island), and nothing
///   covers the picture. When a wide display leaves the margins too narrow for that, both float over the picture's
///   edges and fade after a few seconds; the button left at the edge brings them back.
///
/// The picture keeps its place in the view tree in both, so turning the phone keeps the Space you're on.
struct ScreenStage<Picture: View>: View {
    var landscape: Bool
    /// The Mac display's width over its height.
    var aspectRatio: CGFloat
    var zoomed: Bool
    var controls: ScreenControls
    /// The stream's numbers; nil until the picture streams.
    var stats: StreamStatsView?
    var spaces: SpacesBar
    @ViewBuilder var picture: Picture
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        // The outer reader keeps to the safe area and the inner one, on its side, takes the whole screen; between
        // them they give the insets (a reader that ignores the safe area reports none of its own).
        GeometryReader { safe in
            GeometryReader { full in
                let layout = StageLayout(full: full.frame(in: .global), safe: safe.frame(in: .global),
                                         rightToLeft: layoutDirection == .rightToLeft, aspectRatio: aspectRatio,
                                         landscape: landscape)
                ZStack {
                    picture
                        .frame(width: layout.picture.width, height: layout.picture.height)
                    if landscape {
                        LandscapeMargins(layout: layout, controls: controls, stats: stats, spaces: spaces)
                    }
                }
                .frame(width: full.size.width, height: full.size.height)
            }
            .ignoresSafeArea(edges: landscape ? .all : [])
        }
        .background(landscape ? Color.black : Color.clear)
        .safeAreaBar(edge: .top) {
            if !landscape, let stats { stats.padding(.horizontal) }
        }
        .safeAreaBar(edge: .bottom) {
            if !landscape && !zoomed { spaces }
        }
        .toolbarVisibility(landscape ? .hidden : .automatic, for: .navigationBar)
        .preference(key: StageHidesBarsKey.self, value: landscape)
        // Full screen on its side: the home indicator fades, and a swipe up from the bottom of the picture (the Dock
        // is there) goes to the Mac first; a second one leaves the app.
        .persistentSystemOverlays(landscape ? .hidden : .automatic)
        .defersSystemGestures(on: landscape ? .bottom : [])
    }
}

/// Whether the stage has the bars hidden (on its side, with the picture up). The tab takes its toolbar items out
/// meanwhile: an item that changes inside a hidden navigation bar (Landscape becoming Portrait) can come back blank,
/// so the items go in fresh, as they are then, when the bar comes back.
nonisolated struct StageHidesBarsKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Where everything goes on a landscape phone.
private struct StageLayout {
    /// A column's control, and the air between a column and the picture.
    static let control: CGFloat = 44
    static let gap: CGFloat = 4

    /// The picture's size; it's centred on the whole screen.
    var picture: CGSize
    /// Each margin column's width.
    var column: CGFloat
    /// The margins are too narrow for the columns: they float over the picture instead.
    var overlay: Bool
    /// The safe area within the whole screen, which the columns keep to.
    var insets: EdgeInsets

    /// `full` and `safe` are the whole stage and its safe part, in the same coordinates.
    init(full: CGRect, safe: CGRect, rightToLeft: Bool, aspectRatio: CGFloat, landscape: Bool) {
        let left = max(0, safe.minX - full.minX)
        let right = max(0, full.maxX - safe.maxX)
        insets = EdgeInsets(top: max(0, safe.minY - full.minY), leading: rightToLeft ? right : left,
                            bottom: max(0, full.maxY - safe.maxY), trailing: rightToLeft ? left : right)
        let size = full.size
        guard landscape, size.width > 0, size.height > 0 else {
            picture = size
            column = 0
            overlay = false
            return
        }
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 10
        // The picture fills the height (or, for a very wide display, the width).
        picture = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        // What each side leaves inside the safe area, less a little air beside the picture.
        let margin = (size.width - picture.width) / 2 - max(insets.leading, insets.trailing) - Self.gap
        overlay = margin < Self.control
        column = overlay ? Self.control + 2 * Self.gap : margin
    }
}

/// The landscape margins: the numbers and Spaces on the leading side, the controls on the trailing side. In the
/// overlay fallback they fade a few seconds after the last touch on them (never while VoiceOver or Switch Control is
/// on), leaving a button to bring them back. Faded, they stay in place, so a menu opened from them stays open.
private struct LandscapeMargins: View {
    var layout: StageLayout
    var controls: ScreenControls
    var stats: StreamStatsView?
    var spaces: SpacesBar
    @State private var hidden = false
    @State private var touches = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fades: Bool { layout.overlay && !voiceOver && !switchControl && !Self.keptUpForTests }

    /// The layout harness can keep the controls from fading (`-screenLayoutKeepControls YES`), for a test that checks
    /// them one by one on a slow simulator.
    private static let keptUpForTests: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "screenLayoutKeepControls")
        #else
        false
        #endif
    }()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                leading
                    .frame(width: layout.column)
                Spacer(minLength: 0)
                ScreenControlColumn(controls: controls)
                    .frame(width: layout.column)
            }
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .simultaneousGesture(TapGesture().onEnded { touches += 1 })
            if hidden {
                HStack {
                    Spacer()
                    Button("Show Controls", systemImage: "ellipsis") {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { hidden = false }
                        touches += 1
                    }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: layout.column)
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, layout.insets.leading)
        .padding(.trailing, layout.insets.trailing)
        .padding(.top, layout.insets.top + 8)
        .padding(.bottom, layout.insets.bottom + 8)
        // The margins are black whatever the appearance, like the picture's own letterbox.
        .environment(\.colorScheme, .dark)
        .task(id: fades ? touches : -1) {
            guard fades, !hidden else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { hidden = true }
        }
        .onChange(of: fades) { _, fades in
            if !fades { hidden = false }
        }
    }

    /// The numbers at the top and the Spaces at the bottom, the Spaces always whole. In a short column (the frame rate
    /// held at "24/30", more Spaces, larger text) the numbers give way first: the timing only, then the frame rate, then
    /// none (VoiceOver and the large content viewer still give them). Before, the column scrolled instead, and the end of
    /// the Spaces bar (Next Space) was cut off at the bottom.
    private var leading: some View {
        ViewThatFits(in: .vertical) {
            column(.all)
            column(.timing)
            column(.frameRate)
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                spaces.axis(.vertical)
            }
            ScrollView {
                spaces.axis(.vertical)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func column(_ limit: StreamStatsView.Limit) -> some View {
        VStack(spacing: 10) {
            numbers(limit)
            Spacer(minLength: 0)
            spaces.axis(.vertical)
        }
    }

    /// Over the picture (the overlay fallback) the numbers sit on glass, to stay legible on any screen. That column is
    /// short (a wide display), so it leaves out the path, which VoiceOver still says: with it, Next Space was cut off.
    @ViewBuilder private func numbers(_ limit: StreamStatsView.Limit) -> some View {
        if let stats {
            stats.axis(.vertical)
                .path(!layout.overlay)
                .limit(limit)
                .padding(.vertical, layout.overlay ? 6 : 0)
                .glassEffect(layout.overlay ? .regular : .identity, in: .rect(cornerRadius: 18))
        }
    }
}

extension StreamStatsView {
    /// The same readout, laid out along `axis`.
    func axis(_ axis: Axis) -> StreamStatsView {
        var copy = self
        copy.axis = axis
        return copy
    }

    /// The same readout, with or without the path.
    func path(_ shown: Bool) -> StreamStatsView {
        var copy = self
        copy.showingPath = shown
        return copy
    }

    /// The same readout, with only some of its numbers.
    func limit(_ limit: Limit) -> StreamStatsView {
        var copy = self
        copy.limit = limit
        return copy
    }
}

extension SpacesBar {
    /// The same bar, laid out along `axis`.
    func axis(_ axis: Axis) -> SpacesBar {
        var copy = self
        copy.axis = axis
        return copy
    }
}

extension DisplayInfo {
    /// Width over height, for fitting its picture (16:10 until the Mac says).
    var aspectRatio: CGFloat { width > 0 && height > 0 ? width / height : 16.0 / 10 }
}
