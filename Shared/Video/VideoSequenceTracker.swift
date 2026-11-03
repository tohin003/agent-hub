import Foundation

/// Which of the hub's video frames the phone can use. Each frame builds on the ones before it, so after a gap in the
/// sequence (the hub skipped frames) or a frame that failed to decode, nothing is shown until a frame marked `refresh`
/// (or a keyframe) arrives, and meanwhile the phone asks for one (`needsRefresh`, sent in its feedback). A stream that
/// starts mid-way (its first frame isn't one to start from) asks too.
nonisolated public struct VideoSequenceTracker: Sendable, Equatable {
    /// The phone lost its place: it's waiting for a refresh frame or a keyframe, and asks the hub for one.
    public private(set) var needsRefresh = false
    /// The newest frame decoded and shown since the stream started.
    public private(set) var newestDecoded: UInt32?
    /// The newest frame received, used or not.
    private var newestReceived: UInt32?

    public init() {}

    /// Whether to decode this frame: a keyframe or a refresh frame always; any other only when it follows the last one
    /// received and nothing has been lost since the last refresh.
    public mutating func shouldDecode(sequence: UInt32, flags: VideoFrameMessage.Flags) -> Bool {
        defer { newestReceived = sequence }
        if flags.contains(.keyframe) || flags.contains(.refresh) { return true }
        guard !needsRefresh, let previous = newestReceived, sequence == previous &+ 1 else {
            needsRefresh = true
            return false
        }
        return true
    }

    /// The frame decoded and is on screen: a keyframe or refresh frame puts the phone back on track.
    public mutating func decoded(sequence: UInt32, flags: VideoFrameMessage.Flags) {
        newestDecoded = sequence
        if flags.contains(.keyframe) || flags.contains(.refresh) { needsRefresh = false }
    }

    /// The frame didn't decode: what follows it can't be trusted.
    public mutating func failed() {
        needsRefresh = true
    }

    /// A new stream (another display, or the hub started over): nothing decoded yet, nothing to ask for until a frame
    /// shows something was missed.
    public mutating func reset() {
        self = VideoSequenceTracker()
    }
}
