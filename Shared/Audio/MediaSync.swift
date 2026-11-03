import Foundation
import Synchronization

/// The sync rule (plan step 2): sound is never ahead of the picture it belongs with, and may trail it by up to 40 ms.
///
/// - **Lowest delay** (the default) never holds the picture back. Sound that is faster than the picture waits for it
///   (its buffer grows); sound that is slower (AirPods add 125–220 ms of their own) simply trails.
/// - **Lip-sync** holds the picture back to meet the sound, so the sound trails it by about 20 ms (the middle of what's
///   allowed).
///
/// Delays are ms from the Mac's capture to the phone's screen (the picture) or speaker (the sound), measured on the
/// phone through `MacClock`.
nonisolated public struct SyncRule: Sendable, Equatable {
    /// The most the sound may trail the picture.
    public static let maxTrailMs: Double = 40
    /// Where lip-sync puts the sound: this far behind the picture.
    public static let lipSyncTrailMs: Double = 20
    /// Where the sound floor puts it, at least: this far behind, so the buffer's own wobble around its level (a few
    /// ms) never puts it ahead.
    public static let floorTrailMs: Double = 5

    public var lipSync = false

    public init(lipSync: Bool = false) {
        self.lipSync = lipSync
    }

    /// How long to hold the picture back: 0 in lowest delay; in lip-sync, what brings it to `lipSyncTrailMs` before
    /// the sound.
    public func pictureHold(pictureDelay: Double, soundDelay: Double) -> Double {
        guard lipSync else { return 0 }
        return max(0, soundDelay - Self.lipSyncTrailMs - pictureDelay)
    }

    /// The least delay the sound may have: the picture's, hold included, and a little more, so it's never ahead.
    public static func soundFloor(pictureDelay: Double, hold: Double) -> Double {
        pictureDelay + hold + floorTrailMs
    }

    /// The least sound the phone's buffer must hold for that: the floor less what the sound spends on the way (its
    /// mean arrival delay) and in the output (its latency). The mean, not the quickest: the sound's delay is the
    /// buffer's mean level plus its mean arrival, and a floor built on the quickest would hold more than needed. In
    /// lip-sync that excess would raise the sound, which raises the hold, which raises the floor again; with the mean
    /// the hold leaves the sound `lipSyncTrailMs` of room and the loop settles.
    public static func bufferFloor(soundFloor: Double, meanArrivalMs: Double, outputLatencyMs: Double) -> Double {
        max(0, soundFloor - meanArrivalMs - outputLatencyMs)
    }
}

/// Where the picture and the sound meet, on the phone: the picture side reports each frame's delay to the screen, the
/// sound side its delay to the speaker. Back come the hold on the picture (lip-sync) and the least delay the sound may
/// have (never ahead). Thread-safe; one per app, since the picture and the sound come over separate connections.
nonisolated public final class MediaSync: Sendable {
    public static let shared = MediaSync()

    /// The picture's delay is the median over this window.
    public static let window: Int64 = 2_000_000
    /// Sound not reported for this long has stopped: no hold for it.
    public static let soundFresh: Int64 = 1_000_000
    /// How fast the hold grows (ms of hold per second): the picture slows by at most 15% meanwhile, rather than stop.
    public static let holdGrowthPerSecond: Double = 150
    /// How fast it shrinks: quickly, since until it has the sound is ahead of the picture (the picture skips ahead a
    /// little instead).
    public static let holdShrinkPerSecond: Double = 1500

    private struct State: Sendable {
        var rule = SyncRule()
        var pictures: [(at: Int64, ms: Double)] = []
        var sound: (at: Int64, ms: Double)?
        var hold = 0.0
        var holdUpdated: Int64?
    }

    private let state = Mutex(State())

    public init() {}

    public var lipSync: Bool {
        get { state.withLock { $0.rule.lipSync } }
        set { state.withLock { $0.rule.lipSync = newValue } }
    }

    /// A picture reached the screen `delayMs` after its capture, before any hold.
    public func pictureShown(delayMs: Double, now: Int64 = TransportClock.now()) {
        state.withLock { state in
            state.pictures.append((now, delayMs))
            state.pictures.removeAll { now - $0.at > Self.window }
        }
    }

    /// The sound now reaches the speaker `delayMs` after its capture (the output's own latency included).
    public func soundPlaying(delayMs: Double, now: Int64 = TransportClock.now()) {
        state.withLock { $0.sound = (now, delayMs) }
    }

    /// The sound stopped, or its output changed (AirPods came or went): its delay is no longer known, so the picture
    /// stops waiting for it at once, and the refilled buffer isn't sized by the old route's delay.
    public func soundStopped() {
        state.withLock { $0.sound = nil }
    }

    /// The picture's own delay (the median of the last 2 s), nil without a picture lately.
    public func pictureDelay(now: Int64 = TransportClock.now()) -> Double? {
        state.withLock { Self.median(of: $0.pictures, now: now) }
    }

    /// The sound's delay, nil when it isn't playing.
    public func soundDelay(now: Int64 = TransportClock.now()) -> Double? {
        state.withLock { state in
            state.sound.flatMap { now - $0.at <= Self.soundFresh ? $0.ms : nil }
        }
    }

    /// The hold on the picture now, ms: moves toward what the rule asks, up at `holdGrowthPerSecond` and down at
    /// `holdShrinkPerSecond`.
    public func pictureHold(now: Int64 = TransportClock.now()) -> Double {
        state.withLock { state in
            let wanted = Self.wantedHold(state, now: now)
            let elapsed = state.holdUpdated.map { Double(now - $0) / 1e6 } ?? 0
            state.holdUpdated = now
            let seconds = max(elapsed, 0)
            state.hold += max(-Self.holdShrinkPerSecond * seconds, min(Self.holdGrowthPerSecond * seconds, wanted - state.hold))
            if !state.rule.lipSync, state.hold < 1 { state.hold = 0 }
            return state.hold
        }
    }

    /// The least delay the sound should have so it isn't ahead of the picture; nil without a picture lately. A hold
    /// on its way down counts only as far as it's going: the sound would otherwise be held back to meet a picture
    /// that's about to come forward.
    public func soundFloor(now: Int64 = TransportClock.now()) -> Double? {
        state.withLock { state in
            let hold = min(state.hold, Self.wantedHold(state, now: now))
            return Self.median(of: state.pictures, now: now).map { SyncRule.soundFloor(pictureDelay: $0, hold: hold) }
        }
    }

    /// What the readout shows: the picture's delay with its hold.
    public func shownPictureDelay(now: Int64 = TransportClock.now()) -> Double? {
        state.withLock { state in Self.median(of: state.pictures, now: now).map { $0 + state.hold } }
    }

    /// The picture stopped (another display, the stream ended).
    public func resetPicture() {
        state.withLock { state in
            state.pictures.removeAll()
            state.hold = 0
            state.holdUpdated = nil
        }
    }

    /// What the rule asks of the hold now: 0 without both a picture and a sound lately.
    private static func wantedHold(_ state: State, now: Int64) -> Double {
        guard let picture = median(of: state.pictures, now: now),
              let sound = state.sound.flatMap({ now - $0.at <= soundFresh ? $0.ms : nil }) else { return 0 }
        return state.rule.pictureHold(pictureDelay: picture, soundDelay: sound)
    }

    private static func median(of samples: [(at: Int64, ms: Double)], now: Int64) -> Double? {
        let recent = samples.filter { now - $0.at <= window }.map(\.ms).sorted()
        guard !recent.isEmpty else { return nil }
        return recent[recent.count / 2]
    }
}
