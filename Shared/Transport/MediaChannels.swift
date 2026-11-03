import Foundation

// The small messages that ride the UDP session beside the picture (`AppMessage`), by channel. Both are unreliable and
// latest-wins, so each carries everything its receiver needs on its own.

nonisolated public enum MediaChannel {
    /// Phone → hub: `ScreenFeedback` as JSON, the same message the screen WebSocket carries.
    public static let feedback: UInt8 = 1
    /// Hub → phone: `CursorPositionMessage`'s 18 bytes. Pointer shapes (PNGs, which mustn't be lost) stay on the
    /// WebSocket.
    public static let pointer: UInt8 = 2
}

nonisolated extension AppMessage {
    /// Feedback for the hub; nil if it wouldn't fit one datagram (it never comes close: ≈150 bytes).
    public static func feedback(_ feedback: ScreenFeedback) -> AppMessage? {
        guard let data = try? WireCoding.encoder.encode(feedback), data.count <= AppMessage.maxDataSize else { return nil }
        return AppMessage(channel: MediaChannel.feedback, data: data)
    }

    public static func pointer(_ position: CursorPositionMessage) -> AppMessage {
        AppMessage(channel: MediaChannel.pointer, data: position.encoded())
    }

    /// The feedback in a feedback message.
    public var screenFeedback: ScreenFeedback? {
        guard channel == MediaChannel.feedback else { return nil }
        return try? WireCoding.decoder.decode(ScreenFeedback.self, from: data)
    }

    /// The pointer's position in a pointer message.
    public var pointerPosition: CursorPositionMessage? {
        guard channel == MediaChannel.pointer else { return nil }
        return CursorPositionMessage.parse(data)
    }
}
