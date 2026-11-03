import Foundation

/// What the Screen tab's readout shows about the live picture. `ScreenClient` keeps it up to date.
struct StreamStats: Equatable {
    var framesPerSecond: Double = 0
    /// Picture data received over the last couple of seconds.
    var megabitsPerSecond: Double = 0
    /// "HEVC 4:4:4", "HEVC", "H.264" or "JPEG"; empty before the first frame.
    var codec: String = ""
    /// Round trip to the Mac in milliseconds, measured by the UDP session while the picture comes over it; nil
    /// otherwise (the Screen tab then shows the control connection's).
    var roundTripMs: Double?
    /// How the picture comes: "Direct", "Relay" or "DERP" (Tailscale's path) over UDP, "UDP" before Tailscale says
    /// which, "TCP" over the WebSocket; empty before the first frame.
    var path: String = ""
    /// Delay from the Mac's screen to this phone's in milliseconds, when known: each frame's capture time against the
    /// Mac's clock as the phone tracks it (`MacClock`), the display's refresh and any lip-sync hold included
    /// (`MediaSync.shownPictureDelay`). Until the Mac's clock is known, capture to decoded over UDP.
    var delayMs: Double?
    /// The frame rate the hub holds the picture to, when the link or the motion keeps it under the most it runs at
    /// (`ScreenStreamInfo`); nil while it runs at full rate.
    var frameRateLimit: Int?
}
