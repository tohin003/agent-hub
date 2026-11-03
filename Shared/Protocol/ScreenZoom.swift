import Foundation

/// A part of a display, as fractions of its width and height from its top-left corner: the part a zoomed-in phone
/// shows (`ScreenViewportParams`), and the part a video frame shows (`VideoFrameMessage.region`).
nonisolated public struct ScreenRegion: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let whole = ScreenRegion(x: 0, y: 0, width: 1, height: 1)

    /// Covers the whole display, give or take rounding.
    public var isWhole: Bool { width >= 0.995 && height >= 0.995 }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// `screen.viewport`, from a phone on its screen connection, no reply: the part of the display its view shows once a
/// zoom or a pan settles; nil when that's the whole display. The hub captures what's around it at the display's own
/// resolution, so zoomed-in text is sharp, and marks each frame with the part it shows. Taps and the pointer keep the
/// whole display's coordinates either way.
nonisolated public struct ScreenViewportParams: Codable, Sendable, Equatable {
    public var displayId: UInt32
    public var visible: ScreenRegion?

    public init(displayId: UInt32, visible: ScreenRegion?) {
        self.displayId = displayId
        self.visible = visible
    }
}

/// `screen.stream`, from the hub to a phone watching video: the frame rate the capture runs at now, which follows the
/// link and how much of the screen moves, and the most it runs at (the display's refresh rate, or what was asked for).
nonisolated public struct ScreenStreamInfo: Codable, Sendable, Equatable {
    public var framesPerSecond: Int
    public var maxFramesPerSecond: Int

    public init(framesPerSecond: Int, maxFramesPerSecond: Int) {
        self.framesPerSecond = framesPerSecond
        self.maxFramesPerSecond = maxFramesPerSecond
    }
}
