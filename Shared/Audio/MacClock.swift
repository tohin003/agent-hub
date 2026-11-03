import Foundation
import Synchronization

/// The Mac's host clock as this phone sees it: `offset` added to a time on the Mac's clock (µs, 32 bits, as frames
/// and sound carry it) gives the phone's time for it, so a capture time becomes "this long ago".
///
/// Two sources, the better first:
/// - **The UDP session** while it runs (`MediaReceiver.hubClockOffset`): the shortest trip a packet made in the last
///   10–20 s, less half the shortest round trip. Thousands of packets a minute make it steady.
/// - **`mac.clock` exchanges** over the WebSocket otherwise. Each gives the Mac's time between a request and its
///   answer; the one with the shortest round trip in the last 30 s wins, its midpoint taken as the Mac's moment. A
///   minimum filter, robust to jitter: a late answer only ever widens the window, and the narrowest window is kept.
///
/// Either way the error is at most half the round trip, and far less when the way there and back are alike.
nonisolated public final class MacClock: Sendable {
    public static let shared = MacClock()

    /// How long a UDP estimate stays the one used after the last frame that brought it.
    public static let transportFresh: Int64 = 3_000_000
    /// How long a WebSocket exchange counts.
    public static let window: Int64 = 30_000_000

    private struct Exchange: Sendable {
        var offset: UInt32
        var roundTrip: Int64
        var at: Int64
    }

    private struct State: Sendable {
        var hub: String?
        var transport: (offset: UInt32, at: Int64)?
        var exchanges: [Exchange] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// The UDP session's estimate, as it comes with frames or sound.
    public func transport(offset: UInt32, now: Int64 = TransportClock.now()) {
        state.withLock { $0.transport = (offset, now) }
    }

    /// A `mac.clock` exchange: sent at `sent` and answered at `received` (phone µs), the Mac's time `hostTime` (µs).
    public func exchange(sent: Int64, hostTime: Int64, received: Int64) {
        guard received >= sent else { return }
        let midpoint = sent + (received - sent) / 2
        let sample = Exchange(offset: UInt32(truncatingIfNeeded: midpoint &- hostTime), roundTrip: received - sent,
                              at: received)
        state.withLock { state in
            state.exchanges.removeAll { received - $0.at > Self.window }
            state.exchanges.append(sample)
        }
    }

    /// The offset now, nil while nothing is known.
    public func offset(now: Int64 = TransportClock.now()) -> UInt32? {
        state.withLock { state in
            if let transport = state.transport, now - transport.at <= Self.transportFresh { return transport.offset }
            return state.exchanges.filter { now - $0.at <= Self.window }.min { $0.roundTrip < $1.roundTrip }?.offset
        }
    }

    /// The round trip of the exchange in use (µs), nil when the UDP estimate is in use or there is none: how far off
    /// the WebSocket estimate can be (at most half of it).
    public func exchangeRoundTrip(now: Int64 = TransportClock.now()) -> Int64? {
        state.withLock { state in
            if let transport = state.transport, now - transport.at <= Self.transportFresh { return nil }
            return state.exchanges.filter { now - $0.at <= Self.window }.map(\.roundTrip).min()
        }
    }

    /// Milliseconds from a moment on the Mac's clock (µs) to `now` on this phone's; nil without an offset.
    public func milliseconds(since macTime: Int64, now: Int64 = TransportClock.now()) -> Double? {
        offset(now: now).map { TransportClock.milliseconds(since: macTime, hubClockOffset: $0, now: now) }
    }

    /// The phone's time (µs) for a moment on the Mac's clock, near `now`; nil without an offset.
    public func phoneTime(ofMac macTime: Int64, now: Int64 = TransportClock.now()) -> Int64? {
        milliseconds(since: macTime, now: now).map { now - Int64($0 * 1000) }
    }

    /// Another Mac, or a new pairing: nothing known.
    public func reset() {
        state.withLock { $0 = State() }
    }

    /// The hub the phone talks to now: another one's clock is another clock, so what was known goes.
    public func use(hub: String) {
        state.withLock { state in
            guard state.hub != hub else { return }
            state = State(hub: hub)
        }
    }
}
