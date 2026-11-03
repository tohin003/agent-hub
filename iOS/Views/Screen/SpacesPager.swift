import SwiftUI

/// The Screen tab's Spaces, a page each, paged sideways. `SpaceFollower` decides where the pager goes and when the Mac
/// switches; this view shows it and says where the finger left the pager. A page passed by a scroll the view made by
/// itself never counts, so a swipe asks the Mac exactly once, and the Mac switching by itself never comes back as a
/// request. While the finger can't page (zoomed in, Drag to Scroll), the Spaces bar and the Mac still move it.
struct SpacesPager<Page: View>: View {
    var follower: SpaceFollower
    /// The finger left the pager at rest on this page.
    var onSettle: (UInt64) -> Void
    @ViewBuilder var page: (SpaceInfo) -> Page
    @State private var position: UInt64?
    @State private var phase = ScrollPhase.idle
    /// The finger has moved the pager since it was last at rest: where it next comes to rest is the finger's.
    @State private var swiped = false

    var body: some View {
        ScrollView(.horizontal) {
            // Not lazy: a Mac has a handful of Spaces, and a lazy stack, with pages coming live and going while the
            // pager moved by itself, kept a page drawn where it no longer was and left the page it went to blank.
            HStack(spacing: 0) {
                ForEach(follower.spaces) { space in
                    page(space)
                        .containerRelativeFrame(.horizontal)
                        .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        // Never disabled while there's a page to go to: a scroll view that can't scroll doesn't move by itself either,
        // and the page must follow the Mac whatever the finger can do. Zoomed in or in Drag to Scroll the picture's own
        // gestures keep the finger from paging (`RemoteScreenView`).
        .scrollDisabled(follower.spaces.count < 2)
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { old, new, context in
            phase = new
            #if DEBUG
            PagerPacing.shared.note("\(old) → \(new)")
            #endif
            #if DEBUG
            if new == .idle { PagerPacing.shared.stop() } else { PagerPacing.shared.start() }
            #endif
            // The Mac is asked where the pager comes to rest, not at the release: asked mid-deceleration, the pages
            // change (the one left stops being live) while the pager is still on its way, and it came back to where it
            // started. The harness times the release to the request.
            #if DEBUG
            if old == .interacting, new == .decelerating { PagerPacing.shared.released(velocity: context.velocity?.dx) }
            #endif
            // However it comes to rest after the finger (decelerating, or animated onto the page), that rest is the
            // finger's; a move the pager makes by itself never has the finger on it.
            if new == .interacting { swiped = true }
            if new == .idle {
                if swiped, let position {
                    onSettle(position)
                } else if let page = follower.page, page != position {
                    // A move it skipped while a finger was on it (the Mac switched meanwhile): made now.
                    follow(to: page)
                }
                swiped = false
            }
        }
        .onAppear { position = follower.page }
        #if DEBUG
        .onChange(of: position) { old, new in
            PagerPacing.shared.note("at \(new.map(String.init) ?? "nil") from \(old.map(String.init) ?? "nil")")
        }
        #endif
        .onChange(of: follower.page) { _, page in
            // Never under the finger, nor while the finger's scroll is still decelerating (where it comes to rest goes
            // to the follower); the pager catches up once at rest.
            guard page != position, movesItself else { return }
            follow(to: page)
        }
    }

    /// The pager may move by itself: at rest, or during a move of its own (never during the finger's).
    private var movesItself: Bool { phase == .idle || phase == .animating }

    /// Moves the pager by itself, once the update that asked for it is done: the Mac switching by itself also brings
    /// the new page live, which rebuilds it in that same update, and the scroll view then kept the old page in place.
    private func follow(to page: UInt64?) {
        #if DEBUG
        PagerPacing.shared.note("follow to \(page.map(String.init) ?? "nil") from \(position.map(String.init) ?? "nil"), \(phase)")
        #endif
        Task {
            await Task.yield()
            guard page == follower.page, page != position, movesItself else { return }
            #if DEBUG
            PagerPacing.shared.start(stoppingAfter: 1)
            #endif
            withAnimation(.snappy) { position = page }
        }
    }
}

/// One Space's page: the Mac live when it's there, else that Space's latest still, or its name before there's one;
/// never black, never another Space's live picture. The page a switch is on its way to keeps its still, undimmed, until
/// the Mac has got there (macOS animates its own slide, which the live picture would replay after the page had already
/// moved), then the live picture takes over in 150 ms.
struct SpacePage<Picture: View>: View {
    var space: SpaceInfo
    var live: Bool
    /// Not the Mac's Space, nor where it's going: the banner asks for a swipe.
    var invitesSwitch: Bool
    var snapshot: UIImage?
    var feed: VideoFeed?
    /// The page's picture: the Mac live when `live`, else `snapshot`.
    @ViewBuilder var picture: Picture
    @State private var fadedIn = true

    var body: some View {
        picture
            // Which Space the picture is, for VoiceOver: "Desktop 1, Space 1 of 3".
            .accessibilityValue(Self.name(space))
            .overlay {
                if live, !fadedIn, let snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if !live, snapshot == nil { SpacePlaceholder(space: space).allowsHitTesting(false) }
            }
            .overlay(alignment: .top) {
                if invitesSwitch {
                    Label("Swipe here to switch the Mac to this Space", systemImage: "hand.draw")
                        .font(.footnote)
                        .padding(8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                }
            }
            .onChange(of: live) { _, live in
                guard live else {
                    fadedIn = true
                    return
                }
                // The still stays over the live picture until the Mac's next frame (the new Space's) has arrived.
                fadedIn = false
                Task {
                    await feed?.nextFrame(within: .milliseconds(400))
                    withAnimation(.easeOut(duration: 0.15)) { fadedIn = true }
                }
            }
    }
}

extension SpacePage {
    static func name(_ space: SpaceInfo) -> String {
        "\(space.title ?? "Desktop \(space.index + 1)"), Space \(space.index + 1)"
    }
}

/// A Space never seen yet: its name on a card, where its picture will be.
struct SpacePlaceholder: View {
    var space: SpaceInfo

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: space.isFullscreen ? "macwindow" : "menubar.dock.rectangle")
                .font(.largeTitle)
            Text(space.title ?? "Desktop \(space.index + 1)")
                .font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.14))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Frames and hitches while the pager moves (a hitch: a frame that came 1.5 refreshes or more after the one before), for
/// the layout harness's readout.
final class PagerPacing: NSObject {
    static let shared = PagerPacing()
    private(set) var last = (frames: 0, hitches: 0, worstMs: 0.0)
    /// The last release: its speed (points a millisecond), and how long after it the Mac was asked (`asked()`, from
    /// the harness's made-up Mac).
    private(set) var release = "none"
    private var releasedAt: CFTimeInterval?

    /// The pager's last few moves and phases, for the harness's readout (`pagerTrace`).
    private(set) var trace: [String] = []

    func note(_ event: String) {
        trace = Array((trace + [event]).suffix(10))
    }

    func released(velocity: CGFloat?) {
        releasedAt = CACurrentMediaTime()
        release = "v \(velocity.map { String(format: "%.3f", $0) } ?? "nil")"
    }

    /// The Mac was asked to switch: how long after the finger let go.
    func asked() {
        guard let releasedAt else { return }
        release += String(format: ", asked %.0f ms after the release", (CACurrentMediaTime() - releasedAt) * 1000)
        self.releasedAt = nil
    }
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var frames = 0
    private var hitches = 0
    private var worst = 0.0

    func start() {
        guard link == nil else { return }
        frames = 0
        hitches = 0
        worst = 0
        previous = nil
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// For a move the pager makes by itself, whose phases may not be reported: it stops after `seconds` unless the
    /// pager comes to rest first.
    func start(stoppingAfter seconds: Double) {
        start()
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            stop()
        }
    }

    func stop() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        last = (frames, hitches, worst * 1000)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let refresh = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if let previous {
            let gap = link.timestamp - previous
            frames += 1
            worst = max(worst, gap)
            if gap > 1.5 * refresh { hitches += 1 }
        }
        previous = link.timestamp
    }
}
#endif
