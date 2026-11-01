import SwiftUI

/// The blob answering a touch, for hero spots (ported from Pebble Remote's PebbleTouchAvatar, which follows the Mac
/// companion's rules: Pet.vue, companionState.ts rows 13 and 16, companionPointer.ts):
/// - a finger held on the blob presses it in (it gives, then springs back with a wobble when let go), makes it
///   attentive, and its eyes follow the finger;
/// - a tap jiggles it and makes it happy for a moment (1.2 s), with a little hop and a light tap of the haptics;
/// - three taps in quick succession make it celebrate (the happy mood's hops and sparkles);
/// - while an agent works or something needs the person, a touch only turns its eyes and jiggles it: the face never
///   invents a mood while work is under way, so it never hides what is happening.
///
/// Under Reduce Motion it stays still, as every blob does. Decorative for VoiceOver: a touch changes nothing but its
/// face.
public struct BlobTouchView: View {
    let mood: BlobMood
    let logos: [TerminalLogo]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the finger is once it has been held on the blob a moment, while it stays down. Only a hold follows the
    /// finger: a swipe that merely starts on the blob scrolls the list underneath, as anywhere else.
    @GestureState private var finger: CGPoint?
    /// The face a tap, or a burst of taps, shows until it ends.
    @State private var reaction: BlobPose?
    /// Where the eyes still look after a tap while the blob is busy (a glance), until it ends.
    @State private var glance: CGVector?
    @State private var ending: Task<Void, Never>?
    @State private var recentTaps: [Date] = []
    /// Counts taps that changed the face, for the haptic; `celebrated` says which kind the last one was.
    @State private var reactionCount = 0
    @State private var celebrated = false
    @State private var jiggles = 0
    @State private var size = CGSize.zero

    /// How long a tap's happy face holds (companionState.ts `TAP_MS`).
    static let tapHold = 1.2
    /// How long the celebration holds.
    static let celebrationHold = 2.6
    /// Taps this close together, three of them, are a burst.
    static let burstWindow = 1.4
    /// How long a glance holds while the blob is busy.
    static let glanceHold = 1.0

    public init(mood: BlobMood = .idle, logos: [TerminalLogo] = []) {
        self.mood = mood
        self.logos = logos
    }

    public var body: some View {
        BlobView(pose: shownPose, animated: true, logos: logos, look: look, pressed: finger != nil && !reduceMotion,
                 jiggles: jiggles)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(.circle)
            .simultaneousGesture(touch)
            .sensoryFeedback(trigger: reactionCount) { _, _ in
                celebrated ? SensoryFeedback.success : SensoryFeedback.impact(weight: .light, intensity: 0.7)
            }
            .onChange(of: mood) {
                // The real state wins at once: work starting ends any reaction.
                if !rests { endReaction() }
            }
            .onDisappear { endReaction() }
    }

    /// Resting (nothing running, nothing waiting): only then does a touch change the face.
    private var rests: Bool { mood == .idle || mood == .sleeping }

    private var reacts: Bool { rests && !reduceMotion }

    /// The reaction or the finger's attention over a resting mood; the mood's own pose otherwise.
    private var shownPose: BlobPose {
        guard reacts else { return BlobPose(mood) }
        if let reaction { return reaction }
        if finger != nil { return .hover }
        return BlobPose(mood)
    }

    /// The finger's direction while it is down, then a glance's; nil lets the eyes rest.
    private var look: CGVector? {
        guard !reduceMotion else { return nil }
        if let finger { return direction(to: finger) }
        return glance
    }

    /// A tap, or a hold that then follows the finger. A touch that moves before the hold fails both, so the list
    /// underneath scrolls.
    private var touch: some Gesture {
        let hold = LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($finger) { value, state, _ in
                if case .second(true, let drag?) = value { state = drag.location }
            }
        return SpatialTapGesture()
            .onEnded { value in tapped(at: value.location) }
            .exclusively(before: hold)
    }

    /// From the blob's centre to the finger, reaching full turn at its rim.
    private func direction(to point: CGPoint) -> CGVector {
        let reach = min(size.width, size.height) * 0.4
        guard reach > 0 else { return .zero }
        return CGVector(dx: min(max((point.x - size.width / 2) / reach, -1), 1),
                        dy: min(max((point.y - size.height / 2) / reach, -1), 1))
    }

    private func tapped(at point: CGPoint) {
        guard !reduceMotion else { return }
        jiggles += 1
        if reacts {
            let now = Date.now
            recentTaps = recentTaps.filter { now.timeIntervalSince($0) < Self.burstWindow } + [now]
            celebrated = recentTaps.count >= 3
            if celebrated { recentTaps = [] }
            reactionCount += 1
            hold(celebrated ? .happy : .tap, glance: nil, for: celebrated ? Self.celebrationHold : Self.tapHold)
        } else {
            hold(nil, glance: direction(to: point), for: Self.glanceHold)
        }
    }

    private func hold(_ face: BlobPose?, glance: CGVector?, for seconds: Double) {
        reaction = face
        self.glance = glance
        ending?.cancel()
        ending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            reaction = nil
            self.glance = nil
        }
    }

    private func endReaction() {
        ending?.cancel()
        ending = nil
        reaction = nil
        glance = nil
    }
}
