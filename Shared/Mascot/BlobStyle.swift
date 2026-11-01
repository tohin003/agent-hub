import SwiftUI

/// The blob's moods: each one is a pose the app shows for a real state of the hub and its agents, never one made up
/// from elapsed time.
nonisolated public enum BlobMood: String, CaseIterable, Sendable {
    /// Calm, ready: the resting face, blinking now and then, the gaze drifting.
    case idle
    /// An agent is working: the eyes read along a line and look up to think, three dots pulse above, the body bobs and
    /// the agents orbit faster.
    case working
    /// Something needs you: wide round eyes turned to you, an orange badge pops onto the blob and pulses.
    case attention
    /// A job finished well: happy squinting eyes, little hops, sparkles.
    case happy
    /// Not connected, or resting: drowsy eyes, a lean, "z z", the orbit stills and dims.
    case sleeping
    /// Something went wrong: sad eyes, a sag, a drop of sweat.
    case problem
}

/// The blob's colours. The body is a sphere in Starlight, the warm champagne silver of Apple's MacBook Air; shading
/// stops run from `highlight` (toward the light, top left) through `body` to `shade` at the far edge, with `depth` in
/// the core shadow.
nonisolated public struct BlobPalette: Sendable {
    /// The lit side of the sphere.
    public var highlight: Color
    /// The body's own tone.
    public var body: Color
    /// The edge turned away from the light.
    public var shade: Color
    /// The warm tone deep in the shadow (a hint of the champagne's gold).
    public var depth: Color
    /// Light bounced back from the ground onto the lower rim (golden, for Starlight).
    public var glow: Color
    /// The thin rim light along the lower right edge, which separates the blob from a dark background.
    public var rim: Color
    public var eye: Color
    /// The "needs you" badge.
    public var badge: Color
    /// The cues drawn beside the blob (thinking dots, sparkles, "z z", a drop): on the background, so they follow it.
    public var cue: Color
    /// The agents' orbit line.
    public var orbit: Color
    /// The contact shadow under the blob.
    public var shadow: Color
    /// false: the whole blob in `body`, unshaded (template images, tinted icons).
    public var shaded: Bool
    /// true: the eyes are holes (transparent) instead of painted in `eye`.
    public var eyesCutOut: Bool

    public init(highlight: Color, body: Color, shade: Color, depth: Color, glow: Color, rim: Color, eye: Color,
                badge: Color, cue: Color, orbit: Color, shadow: Color, shaded: Bool = true, eyesCutOut: Bool = false) {
        self.highlight = highlight
        self.body = body
        self.shade = shade
        self.depth = depth
        self.glow = glow
        self.rim = rim
        self.eye = eye
        self.badge = badge
        self.cue = cue
        self.orbit = orbit
        self.shadow = shadow
        self.shaded = shaded
        self.eyesCutOut = eyesCutOut
    }

    /// A one-colour blob: body, badge, cues and orbit in `color`, the eyes cut out (the badge keeps a notch around it,
    /// so it still reads). For template images (the Mac menu bar) and tinted Home Screen icons; pass `badge` to keep
    /// the badge in its own colour.
    public static func flat(_ color: Color, badge: Color? = nil) -> BlobPalette {
        BlobPalette(highlight: color, body: color, shade: color, depth: color, glow: color, rim: color, eye: color,
                    badge: badge ?? color, cue: color, orbit: color, shadow: .clear, shaded: false, eyesCutOut: true)
    }

    /// Starlight: a glossy champagne-silver sphere with warm graphite eyes. Made for dark backgrounds (the app icon's
    /// black, dark mode); `starlight(for:)` gives the cues and orbit a darker ink on light ones.
    public static let starlight = BlobPalette(
        highlight: rgb(0xFBF8F2),
        body: rgb(0xEAE2D4),
        shade: rgb(0xD1C7B7),
        depth: rgb(0xAFA492),
        glow: rgb(0xF0D9AE),
        rim: rgb(0xFFF7E8),
        eye: rgb(0x2A2622),
        badge: rgb(0xFF9F0A),
        cue: rgb(0xE6DCC9),
        orbit: rgb(0xEDE4D3),
        shadow: rgb(0x1E1608))

    /// One colour (white), eyes cut out: for template and tinted uses.
    public static let mono = BlobPalette.flat(.white)

    /// Starlight with the cues and orbit inked for the background: the sphere itself is the same object in both.
    public static func starlight(for colorScheme: ColorScheme) -> BlobPalette {
        guard colorScheme == .light else { return starlight }
        var palette = starlight
        palette.cue = rgb(0xA4957D)
        palette.orbit = rgb(0x9C8E77)
        palette.badge = rgb(0xFF9500)
        return palette
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
