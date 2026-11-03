import SwiftUI

/// How often views are rebuilt, for the layout harness's readout and its tests: in debug builds only (release does
/// nothing). The Screen tab, its controls and the Screen Options menu count themselves.
enum RenderCount {
    #if DEBUG
    private static var counts: [String: Int] = [:]
    private static var rates: [String: Int] = [:]
    private static var since = Date.now

    static func tick(_ name: String) { counts[name, default: 0] += 1 }

    /// Rebuilds a second, by name, over the last whole second.
    static func perSecond() -> [String: Int] {
        let elapsed = Date.now.timeIntervalSince(since)
        if elapsed >= 1 {
            rates = counts.mapValues { Int((Double($0) / elapsed).rounded()) }
            counts = [:]
            since = .now
        }
        return rates
    }
    #else
    @inline(__always) static func tick(_ name: String) {}
    #endif
}
