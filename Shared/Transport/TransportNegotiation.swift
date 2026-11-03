import Foundation

// Setting up the UDP media path over the paired WebSocket: the phone asks on its screen connection, the hub makes a
// session (a random id and 256-bit key, handed over the authenticated WebSocket inside WireGuard) and answers with
// where to send the hello. If the hello gets no answer within a second, the phone keeps using the WebSocket.

nonisolated extension Method {
    /// On a screen connection, from the phone: move picture and sound to UDP (`ScreenTransportParams` →
    /// `ScreenTransportResult`). Taps and typing stay on the WebSocket.
    public static let screenTransport = "screen.transport"
}

nonisolated public struct ScreenTransportParams: Codable, Sendable, Equatable {
    /// Transport versions the phone speaks.
    public var versions: [Int]
    /// From the phone's path monitor; cellular gets error correction even on a direct path.
    public var network: PhoneNetwork
    public var video: Bool
    public var audio: Bool
    /// Sound codecs the phone decodes, best first.
    public var audioCodecs: [String]

    public init(versions: [Int] = [Int(TransportWire.version)], network: PhoneNetwork, video: Bool = true,
                audio: Bool = true, audioCodecs: [String] = [TransportAudioFormat.opus.codec]) {
        self.versions = versions
        self.network = network
        self.video = video
        self.audio = audio
        self.audioCodecs = audioCodecs
    }
}

nonisolated public struct ScreenTransportResult: Codable, Sendable, Equatable {
    public var version: Int
    /// The Mac's tailnet address the UDP socket listens on, and its port.
    public var host: String
    public var port: Int
    public var sessionId: UInt32
    /// The session key: 32 random bytes (base64 in JSON). Never log it.
    public var key: Data
    /// How Tailscale reaches the phone now, and the profile in force.
    public var path: PathKind
    public var profile: PathProfile
    /// How the sound comes, when it was asked for.
    public var audio: TransportAudioFormat?

    public init(version: Int = Int(TransportWire.version), host: String, port: Int, sessionId: UInt32, key: Data,
                path: PathKind, profile: PathProfile, audio: TransportAudioFormat?) {
        self.version = version
        self.host = host
        self.port = port
        self.sessionId = sessionId
        self.key = key
        self.path = path
        self.profile = profile
        self.audio = audio
    }

    /// The session's keys; nil for a malformed answer.
    public var keys: TransportKeys? { TransportKeys(sessionID: sessionId, sessionKey: key) }
}

/// How sound travels over UDP.
nonisolated public struct TransportAudioFormat: Codable, Sendable, Equatable {
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var frameDurationMs: Double
    public var bitrate: Int

    public init(codec: String, sampleRate: Int, channels: Int, frameDurationMs: Double, bitrate: Int) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDurationMs = frameDurationMs
        self.bitrate = bitrate
    }

    /// Opus, 48 kHz stereo, 10 ms frames; the bitrate follows the path profile.
    public static let opus = TransportAudioFormat(codec: "opus", sampleRate: 48_000, channels: 2, frameDurationMs: 10,
                                                  bitrate: 128_000)
}
