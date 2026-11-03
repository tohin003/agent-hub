import Foundation

// How Tailscale reaches the phone decides how the hub sends: straight between the devices it can resend lost picture
// pieces in time and push 10 Mbit/s; through a peer relay it adds light error correction; through DERP (Tailscale's
// shared TCP relays, often ≈2 Mbit/s and 300–500 ms round trips) it caps the rate and frame rate, leans on error
// correction and keeps bigger buffers. The numbers live in one table, `PathProfile.table`.

nonisolated public enum PathKind: String, Codable, Sendable, CaseIterable {
    /// Straight between the two devices (the same network, or through both NATs).
    case direct
    /// Through a Tailscale peer relay: another device on the tailnet forwarding UDP.
    case peerRelay
    /// Through one of Tailscale's DERP servers.
    case derp
    /// Not known yet (or Tailscale has no live session with the phone): treated like a peer relay.
    case unknown

    var code: UInt8 {
        switch self {
        case .unknown: 0
        case .direct: 1
        case .peerRelay: 2
        case .derp: 3
        }
    }

    init(code: UInt8) {
        switch code {
        case 1: self = .direct
        case 2: self = .peerRelay
        case 3: self = .derp
        default: self = .unknown
        }
    }
}

/// How to send on one kind of path.
nonisolated public struct PathProfile: Codable, Sendable, Equatable {
    public var path: PathKind
    /// Bounds for everything sent (picture, sound, resends and parity), bits per second.
    public var minBitrate: Int
    public var startBitrate: Int
    public var maxBitrate: Int
    public var maxFramesPerSecond: Int
    /// Parity packets per picture packet on Wi-Fi and on cellular, and the most the policy adds under heavier loss.
    public var fecRatio: Double
    public var cellularFecRatio: Double
    public var maxFecRatio: Double
    /// Resends are asked for while the round trip is at most this long; beyond it they'd arrive too late to help.
    public var nackMaxRoundTripMs: Double
    /// How long the phone waits for a picture before giving up on it: round trips × `frameDeadlineRoundTrips` plus
    /// `frameDeadlineExtraMs`, within `frameDeadlineMinMs...frameDeadlineMaxMs`, while resends are on; without them,
    /// `frameDeadlineMinMs` (reordering and jitter only).
    public var frameDeadlineRoundTrips: Double
    public var frameDeadlineExtraMs: Double
    public var frameDeadlineMinMs: Double
    public var frameDeadlineMaxMs: Double
    /// The most picture data allowed to wait in the hub's send queue; past it a frame is skipped, not queued.
    public var videoQueueMs: Double
    /// The congestion window's allowance over the base round trip: while more than the target rate's worth of
    /// (round trip + this) is sent and not yet reported, no new frame is taken (the one going out finishes; sound
    /// isn't held) until the network's queue drains. Delay-based control can't see a standing queue (its delay stops
    /// changing); this can.
    public var inFlightAllowanceMs: Double
    /// Earlier sound frames repeated in each sound packet, on Wi-Fi and on cellular.
    public var audioRedundancy: Int
    public var cellularAudioRedundancy: Int
    /// Opus's bitrate, and the loss its in-band error correction plans for at least.
    public var opusBitrate: Int
    public var opusExpectedLossPercent: Int
    /// The phone's sound buffer target (step 2's jitter buffer starts from it).
    public var audioBufferMs: Double
    /// Loss-based rate control: below `lossLow` the rate may grow, above `lossHigh` it backs off. Higher on paths
    /// whose loss is random rather than congestion, where error correction covers it.
    public var lossLow: Double
    public var lossHigh: Double
    /// How often the phone reports arrival times.
    public var feedbackIntervalMs: Double
    /// The round trip assumed until one is measured.
    public var assumedRoundTripMs: Double

    public static let table: [PathKind: PathProfile] = [
        .direct: PathProfile(
            path: .direct, minBitrate: 300_000, startBitrate: 3_000_000, maxBitrate: 10_000_000, maxFramesPerSecond: 60,
            fecRatio: 0, cellularFecRatio: 0.10, maxFecRatio: 0.20, nackMaxRoundTripMs: 300,
            frameDeadlineRoundTrips: 2, frameDeadlineExtraMs: 25, frameDeadlineMinMs: 60, frameDeadlineMaxMs: 250,
            videoQueueMs: 25, inFlightAllowanceMs: 80, audioRedundancy: 0, cellularAudioRedundancy: 1, opusBitrate: 128_000,
            opusExpectedLossPercent: 2, audioBufferMs: 30, lossLow: 0.02, lossHigh: 0.10, feedbackIntervalMs: 25,
            assumedRoundTripMs: 30),
        .peerRelay: PathProfile(
            path: .peerRelay, minBitrate: 300_000, startBitrate: 2_000_000, maxBitrate: 5_000_000, maxFramesPerSecond: 60,
            fecRatio: 0.10, cellularFecRatio: 0.15, maxFecRatio: 0.20, nackMaxRoundTripMs: 200,
            frameDeadlineRoundTrips: 2, frameDeadlineExtraMs: 30, frameDeadlineMinMs: 80, frameDeadlineMaxMs: 300,
            videoQueueMs: 30, inFlightAllowanceMs: 100, audioRedundancy: 1, cellularAudioRedundancy: 1, opusBitrate: 96_000,
            opusExpectedLossPercent: 5, audioBufferMs: 50, lossLow: 0.05, lossHigh: 0.20, feedbackIntervalMs: 25,
            assumedRoundTripMs: 80),
        .derp: PathProfile(
            path: .derp, minBitrate: 200_000, startBitrate: 1_000_000, maxBitrate: 2_000_000, maxFramesPerSecond: 30,
            fecRatio: 0.20, cellularFecRatio: 0.20, maxFecRatio: 0.30, nackMaxRoundTripMs: 150,
            frameDeadlineRoundTrips: 1.5, frameDeadlineExtraMs: 60, frameDeadlineMinMs: 120, frameDeadlineMaxMs: 600,
            videoQueueMs: 35, inFlightAllowanceMs: 200, audioRedundancy: 2, cellularAudioRedundancy: 2, opusBitrate: 64_000,
            opusExpectedLossPercent: 10, audioBufferMs: 100, lossLow: 0.05, lossHigh: 0.25, feedbackIntervalMs: 40,
            assumedRoundTripMs: 300),
        .unknown: PathProfile(
            path: .unknown, minBitrate: 300_000, startBitrate: 1_500_000, maxBitrate: 5_000_000, maxFramesPerSecond: 60,
            fecRatio: 0.10, cellularFecRatio: 0.15, maxFecRatio: 0.20, nackMaxRoundTripMs: 200,
            frameDeadlineRoundTrips: 2, frameDeadlineExtraMs: 30, frameDeadlineMinMs: 80, frameDeadlineMaxMs: 300,
            videoQueueMs: 30, inFlightAllowanceMs: 100, audioRedundancy: 1, cellularAudioRedundancy: 1, opusBitrate: 96_000,
            opusExpectedLossPercent: 5, audioBufferMs: 50, lossLow: 0.05, lossHigh: 0.20, feedbackIntervalMs: 25,
            assumedRoundTripMs: 80),
    ]

    public static func profile(for path: PathKind) -> PathProfile {
        table[path] ?? PathProfile.fallback
    }

    /// Never used while the table has every kind; keeps `profile(for:)` total without a force unwrap.
    private static let fallback = PathProfile(
        path: .unknown, minBitrate: 300_000, startBitrate: 1_000_000, maxBitrate: 2_000_000, maxFramesPerSecond: 30,
        fecRatio: 0.20, cellularFecRatio: 0.20, maxFecRatio: 0.30, nackMaxRoundTripMs: 150, frameDeadlineRoundTrips: 1.5,
        frameDeadlineExtraMs: 60, frameDeadlineMinMs: 120, frameDeadlineMaxMs: 600, videoQueueMs: 35,
        inFlightAllowanceMs: 200, audioRedundancy: 2, cellularAudioRedundancy: 2, opusBitrate: 64_000,
        opusExpectedLossPercent: 10, audioBufferMs: 100, lossLow: 0.05, lossHigh: 0.25, feedbackIntervalMs: 40,
        assumedRoundTripMs: 300)
}

/// How to protect the stream right now.
nonisolated public struct RecoveryPlan: Sendable, Equatable {
    /// Ask for and honour resends.
    public var nack: Bool
    public var fec: FECSettings
    public var audioRedundancy: Int
    /// µs the phone waits for a picture.
    public var frameDeadline: Int64
    public var opusExpectedLossPercent: Int
}

/// Picks NACK and/or error correction from the path, the phone's network, the round trip and the loss seen:
/// direct paths resend (with light parity on cellular); relays and cellular add 10–20% parity and resend while the
/// round trip allows; DERP adds 20% or more and mostly can't wait for resends.
nonisolated public enum RecoveryPolicy {
    public static func plan(profile: PathProfile, network: PhoneNetwork, roundTripMs: Double?, lossRate: Double) -> RecoveryPlan {
        let roundTrip = roundTripMs ?? profile.assumedRoundTripMs
        let cellular = network == .cellular
        let base = cellular ? profile.cellularFecRatio : profile.fecRatio
        let nack = roundTrip <= profile.nackMaxRoundTripMs
        // When more is lost than the base ratio covers, parity follows the loss (twice the rate) up to the cap; without
        // resends it's the only way back short of a refresh round trip, so it follows three times as steeply (5% loss
        // on DERP buys 30%, which leaves ≈0.1% of 7-piece frames unrebuildable). A path with no parity by design
        // (direct Wi-Fi) stays on resends alone.
        let ratio = base > 0 ? min(profile.maxFecRatio, max(base, (nack ? 2 : 6) * lossRate)) : 0
        // Waiting for a frame only pays while a resend can still come; without resends the wait covers reordering
        // and jitter, and a frame parity can't rebuild is given up at once so the refresh starts sooner.
        let deadlineMs = nack
            ? min(profile.frameDeadlineMaxMs, max(profile.frameDeadlineMinMs,
                                                  profile.frameDeadlineRoundTrips * roundTrip + profile.frameDeadlineExtraMs))
            : profile.frameDeadlineMinMs
        let expectedLoss = min(30, max(profile.opusExpectedLossPercent, Int((lossRate * 100).rounded())))
        return RecoveryPlan(nack: nack, fec: FECSettings(ratio: ratio),
                            audioRedundancy: cellular ? profile.cellularAudioRedundancy : profile.audioRedundancy,
                            frameDeadline: Int64(deadlineMs * 1000), opusExpectedLossPercent: expectedLoss)
    }
}

// MARK: Which path Tailscale uses

/// How Tailscale reaches one peer.
nonisolated public struct TailscalePeerPath: Sendable, Equatable {
    public var kind: PathKind
    /// The peer's direct address (`CurAddr`), the peer relay's (`PeerRelay`) or the DERP region's code (`Relay`).
    public var via: String?

    public init(kind: PathKind, via: String? = nil) {
        self.kind = kind
        self.via = via
    }
}

/// Reads `tailscale status --json`, as Tailscale's own `status` command does: a peer with a current address is
/// direct, one with a peer relay goes through it, and an active one with neither goes through its DERP region.
nonisolated public enum TailscalePathClassifier {
    public static func classify(statusJSON: Data, peerAddress: String) -> TailscalePeerPath {
        guard let target = IPAddressBytes.parse(peerAddress),
              let status = try? JSONDecoder().decode(Status.self, from: statusJSON),
              let peer = status.peers?.values.first(where: { peer in
                  peer.addresses.contains { IPAddressBytes.parse($0) == target }
              }) else { return TailscalePeerPath(kind: .unknown) }
        if let address = peer.currentAddress, !address.isEmpty { return TailscalePeerPath(kind: .direct, via: address) }
        if let relay = peer.peerRelay, !relay.isEmpty { return TailscalePeerPath(kind: .peerRelay, via: relay) }
        // The home DERP region is listed even for idle peers; it only says where traffic goes while active.
        if peer.active, let region = peer.derpRegion, !region.isEmpty { return TailscalePeerPath(kind: .derp, via: region) }
        return TailscalePeerPath(kind: .unknown)
    }

    private struct Status: Decodable {
        var peers: [String: Peer]?

        enum CodingKeys: String, CodingKey {
            case peers = "Peer"
        }
    }

    private struct Peer: Decodable {
        var addresses: [String]
        var currentAddress: String?
        var derpRegion: String?
        var peerRelay: String?
        var active: Bool

        enum CodingKeys: String, CodingKey {
            case addresses = "TailscaleIPs"
            case currentAddress = "CurAddr"
            case derpRegion = "Relay"
            case peerRelay = "PeerRelay"
            case active = "Active"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
            currentAddress = try container.decodeIfPresent(String.self, forKey: .currentAddress)
            derpRegion = try container.decodeIfPresent(String.self, forKey: .derpRegion)
            peerRelay = try container.decodeIfPresent(String.self, forKey: .peerRelay)
            active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        }
    }
}

/// IP addresses as bytes, so "fd7a:115c:a1e0::1" and "FD7A:115C:A1E0:0:0:0:0:1" compare equal.
nonisolated enum IPAddressBytes {
    static func parse(_ text: String) -> [UInt8]? {
        var host = text.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }
}

/// Who may send to the hub's UDP socket: tailnet devices (and loopback, as for the WebSocket). The hello's seal is
/// what really admits a phone; this just drops everything else before any work.
nonisolated public enum TailnetAddress {
    /// 100.64.0.0/10 and Tailscale's fd7a:115c:a1e0::/48.
    public static func isTailnet(_ address: String) -> Bool {
        guard let bytes = IPAddressBytes.parse(address) else { return false }
        if bytes.count == 4 { return bytes[0] == 100 && bytes[1] & 0xC0 == 0x40 }
        return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    public static func isLoopback(_ address: String) -> Bool {
        guard let bytes = IPAddressBytes.parse(address) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        return bytes == [UInt8](repeating: 0, count: 15) + [1]
    }
}

#if os(macOS)
/// Watches how Tailscale reaches one phone, on the Mac: reads `tailscale status --json` every 2 s for the first 30 s
/// of a stream (Tailscale usually moves from DERP to a direct path within seconds of traffic starting), every 10 s
/// after that, and at once when asked (the phone said hello from a new network). A read costs the CLI ≈45 ms of CPU
/// (0.4 s the first time), so ≈2% of a core while fast and 0.4% after. Reports only changes.
nonisolated public final class TailscalePathMonitor: @unchecked Sendable {
    public struct Schedule: Sendable {
        public var fastInterval: Double = 2
        public var fastPeriod: Double = 30
        public var slowInterval: Double = 10

        public init() {}
    }

    private let queue = DispatchQueue(label: "agenthub.transport.path", qos: .utility)
    private let cli: String
    private let peerAddress: String
    private let schedule: Schedule
    private let onChange: @Sendable (TailscalePeerPath) -> Void
    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var fastUntil: DispatchTime = .now()
    private var last: TailscalePeerPath?

    /// Nil when the Tailscale CLI isn't installed.
    public init?(peerAddress: String, cli: String? = TailscalePathMonitor.findCLI(), schedule: Schedule = Schedule(),
                 onChange: @escaping @Sendable (TailscalePeerPath) -> Void) {
        guard let cli else { return nil }
        self.cli = cli
        self.peerAddress = peerAddress
        self.schedule = schedule
        self.onChange = onChange
    }

    public static func findCLI() -> String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func start() {
        checkNow()
    }

    /// Reads the path now and goes back to the fast pace.
    public func checkNow() {
        queue.async {
            self.fastUntil = .now() + self.schedule.fastPeriod
            self.check()
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func check() {
        if let json = Self.status(cli: cli) {
            let path = TailscalePathClassifier.classify(statusJSON: json, peerAddress: peerAddress)
            if path != last {
                last = path
                onChange(path)
            }
        }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTime.now() < fastUntil ? schedule.fastInterval : schedule.slowInterval
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    /// The CLI's JSON, or nil if it failed or took longer than 5 s.
    static func status(cli: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
#endif
