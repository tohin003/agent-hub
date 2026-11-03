import CoreMedia
import CoreVideo
import Foundation
import Network
import Testing

/// Hub code against phone code over real UDP sockets on this Mac, through a relay that delays, drops and limits
/// packets like the emulator's links.
///
/// - **Hub side:** the hardware `VideoEncoder` encodes a moving picture at 60 fps. Each frame goes through
///   `VideoPacing.admit(_:to:now:send:)` into the real `UDPServerSession`, as `ScreenService` does for a phone on UDP.
///   Refreshes are asked for with the session's `hasRoom`, and the encoder's bitrate follows the session's targets
///   (`VideoPacing.encoderSettings`).
/// - **Phone side:** the real `UDPMediaClient` feeds `VideoSequenceTracker` and the hardware `VideoDecoder`. Its
///   feedback goes back over UDP (`MediaChannel.feedback`, recent tokens repeated) at least every 17 ms, as
///   `ScreenFeedbackSender` sends it.
///
/// Delays are capture → decoded on the same clock, so they're exact. The emulator tests cover the same logic in
/// simulated time; this checks it with real sockets, timers and codecs.
@Suite("UDP end to end", .serialized)
struct UDPEndToEndTests {
    struct Result {
        var encoded = 0
        var refused = 0
        var decoded = 0
        var keyframes = 0
        var refreshes = 0
        var lost = 0
        var delays: [Double] = []
        /// The phone's own delay estimate (through the session's clock offset) less the true delay.
        var estimateErrors: [Double] = []
        var recoveries: [Double] = []
        var unrecovered = false
        var meanTarget = 0.0
        var requests = (refresh: 0, keyframe: 0)
        /// Frames the phone's tracker left out (after a gap) and frames that didn't decode.
        var trackerSkips = 0
        var decodeFailures = 0
        var relay = LossyRelay.Counts()
        /// The session's target every 250 ms, kbit/s: "!" overuse, "_" underuse, "a" application-limited, then what
        /// the reports say got through.
        var trace = ""
        /// The hub's requests and refresh frames over time (`HubHarness.timeline`).
        var hubTimeline = ""

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
        }

        var summary: String {
            String(format: "%d encoded, %d decoded (%.1f%%), %d refused at the hub; delay p50 %.1f p95 %.1f max %.1f ms "
                + "(the phone's estimate off by p50 %+.1f ms); "
                + "%d frames given up, recovered in p50 %.0f max %.0f ms (%d LTR refreshes, %d keyframes); "
                + "%d refreshes and %d keyframes asked for; %d frames left out after a gap, %d failed to decode; "
                + "mean target %.2f Mbit/s; relay %d forwarded, %d lost, %d over the queue",
                   encoded, decoded, 100 * Double(decoded) / Double(max(encoded, 1)), refused,
                   percentile(delays, 0.5), percentile(delays, 0.95), delays.max() ?? .nan,
                   percentile(estimateErrors, 0.5), lost,
                   percentile(recoveries, 0.5), recoveries.max() ?? .nan, refreshes, keyframes,
                   requests.refresh, requests.keyframe, trackerSkips, decodeFailures,
                   meanTarget / 1_000_000, relay.forwarded, relay.lost, relay.overflow)
        }
    }

    /// One run: a session through the relay with these links, video for `seconds`.
    static func run(toHub: LossyRelay.Link, toPhone: LossyRelay.Link, seconds: Double,
                    profile: PathKind = .direct) async throws -> Result {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let relay = LossyRelay(toHub: toHub, toPhone: toPhone)
        let relayPort = try await relay.start(hubPort: port)
        defer { relay.stop() }
        let (sessionID, key) = TransportKeys.generate()
        let keys = try #require(TransportKeys(sessionID: sessionID, sessionKey: key))
        let session = server.makeSession(keys: keys, profile: .profile(for: profile))
        let client = UDPMediaClient(host: "127.0.0.1", port: relayPort, keys: keys, network: .wifi)
        defer { client.close() }
        let hub = try HubHarness(session: session)
        let phone = PhoneHarness(client: client)
        session.setEventHandler { hub.handle($0) }
        client.setHandlers(onEvent: { phone.handle($0) }, onFailure: { _ in phone.failed() })
        try await client.connect(timeout: 2)
        phone.startFeedback()
        hub.start()
        var trace: [String] = []
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .milliseconds(Int(seconds * 1000)) {
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = session.snapshot
            trace.append(String(format: "%.0f%@%@%@", Double(snapshot.targetBitrate) / 1000,
                                snapshot.usage == .overusing ? "!" : snapshot.usage == .underusing ? "_" : "",
                                snapshot.applicationLimited ? "a" : "",
                                snapshot.acknowledgedBitrate.map { "/\($0 / 1000)" } ?? ""))
        }
        hub.stop()
        // The last frames' resends and repairs.
        try await Task.sleep(for: .milliseconds(500))
        phone.stop()
        var result = phone.result()
        let counts = hub.counts()
        result.encoded = counts.encoded
        result.refused = counts.refused
        result.keyframes = counts.keyframes
        result.refreshes = counts.refreshes
        result.meanTarget = counts.meanTarget
        result.requests = counts.requests
        result.hubTimeline = counts.timeline
        result.relay = relay.counts(.toPhone)
        result.trace = trace.joined(separator: " ")
        return result
    }

    @Test(.timeLimit(.minutes(1)))
    func aCleanPathShowsEveryFrameQuickly() async throws {
        let link = LossyRelay.Link(delay: 15_000)
        let result = try await Self.run(toHub: link, toPhone: link, seconds: 6)
        reportMetric("real UDP, 30 ms round trip, no loss: \(result.summary)")
        #expect(result.decoded >= result.encoded * 95 / 100)
        #expect(result.percentile(result.delays, 0.5) < 45)
        // The readout's delay, from the session's clock offset, matches the true one.
        #expect(abs(result.percentile(result.estimateErrors, 0.5)) < 5)
        #expect(!result.unrecovered)
    }

    @Test(.timeLimit(.minutes(1)))
    func threePercentLossAtFortyMillisecondsIsRepaired() async throws {
        let link = LossyRelay.Link(delay: 20_000, loss: 0.03)
        let result = try await Self.run(toHub: link, toPhone: link, seconds: 8)
        reportMetric("real UDP, 40 ms round trip, 3% loss each way: \(result.summary)")
        #expect(result.relay.lost > 15)
        #expect(result.decoded >= result.encoded * 95 / 100)
        #expect(result.percentile(result.delays, 0.95) < 150)
        #expect(!result.unrecovered)
    }

    @Test(.timeLimit(.minutes(1)))
    func burstsTooLongToRepairRecoverFromALongTermReference() async throws {
        // Bursts of ≈8 packets (0.4% of packets start one): longer than parity covers and too long to resend in time
        // at 120 ms, so some frames are given up, and the phone asks for a refresh.
        let toPhone = LossyRelay.Link(delay: 60_000, burst: (enter: 0.004, stay: 0.88))
        let toHub = LossyRelay.Link(delay: 60_000)
        let result = try await Self.run(toHub: toHub, toPhone: toPhone, seconds: 10, profile: .peerRelay)
        reportMetric("real UDP, 120 ms round trip, bursty loss: \(result.summary)")
        #expect(result.decoded >= result.encoded * 80 / 100)
        #expect(!result.unrecovered)
        // (A frame given up in the last second may not have been made good yet when the run ends.)
        if !result.recoveries.isEmpty {
            #expect(result.refreshes > 0)
            #expect(result.percentile(result.recoveries, 0.5) < 600)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFiveMegabitLinkKeepsTheQueueShort() async throws {
        let toPhone = LossyRelay.Link(delay: 15_000, rate: 5_000_000)
        let toHub = LossyRelay.Link(delay: 15_000)
        let result = try await Self.run(toHub: toHub, toPhone: toPhone, seconds: 8)
        reportMetric("real UDP, 5 Mbit/s bottleneck, 30 ms round trip: \(result.summary)")
        reportMetric("real UDP, 5 Mbit/s bottleneck, the target every 250 ms: \(result.trace)")
        // Near the link, not collapsed to the trickle a mostly still picture needs.
        #expect(result.meanTarget < 5_500_000)
        #expect(result.meanTarget > 2_500_000)
        #expect(result.decoded >= result.encoded * 85 / 100)
        #expect(result.percentile(result.delays, 0.95) < 200)
    }

    /// A quarter of a second of nothing every 2.5 s (a Wi-Fi hiccup): frames are given up at their deadline, the phone
    /// asks for a refresh, and the picture is back from a long-term reference, without a keyframe.
    @Test(.timeLimit(.minutes(1)))
    func aHiccupIsRecoveredFromALongTermReference() async throws {
        let toPhone = LossyRelay.Link(delay: 15_000, blackout: (every: 2_500_000, length: 250_000))
        let toHub = LossyRelay.Link(delay: 15_000)
        let result = try await Self.run(toHub: toHub, toPhone: toPhone, seconds: 10)
        reportMetric("real UDP, 30 ms round trip, 250 ms hiccups every 2.5 s: \(result.summary); recoveries "
            + result.recoveries.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms")
        reportMetric("real UDP, hiccups, the hub's timeline: \(result.hubTimeline)")
        #expect(result.lost > 0)
        #expect(!result.unrecovered)
        #expect(result.recoveries.count >= 3)
        // From the frame given up to a decoded refresh: a few round trips, not a keyframe's wait. A refresh sent while
        // the hiccup still lasts is lost too, and that one may end in a keyframe after its grace: most aren't.
        #expect(result.percentile(result.recoveries, 0.5) < 400)
        #expect(result.refreshes > 0)
    }

    /// One way dies: the side that hears nothing reports it, and the app falls back to the WebSocket.
    @Test(.timeLimit(.minutes(1)))
    func aDeadPathIsNoticedOnBothSides() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let relay = LossyRelay(toHub: LossyRelay.Link(delay: 5_000), toPhone: LossyRelay.Link(delay: 5_000))
        let relayPort = try await relay.start(hubPort: port)
        defer { relay.stop() }
        let (sessionID, key) = TransportKeys.generate()
        let keys = try #require(TransportKeys(sessionID: sessionID, sessionKey: key))
        let session = server.makeSession(keys: keys, profile: .profile(for: .direct))
        let hubEvents = Inbox<SenderEvent>()
        session.setEventHandler { hubEvents.append($0) }
        let client = UDPMediaClient(host: "127.0.0.1", port: relayPort, keys: keys, network: .wifi)
        defer { client.close() }
        let failures = Inbox<TransportError>()
        client.setHandlers(onEvent: { _ in }, onFailure: { failures.append($0) })
        try await client.connect(timeout: 2)
        try await Task.sleep(for: .milliseconds(300))
        // The phone's packets stop reaching the hub.
        relay.block(.toHub)
        let blocked = ContinuousClock.now
        #expect(await eventually(within: 5) { hubEvents.all.contains(.silent) })
        let hubNoticed = ContinuousClock.now - blocked
        // And the hub's stop reaching the phone.
        relay.block(.toPhone)
        let cut = ContinuousClock.now
        #expect(await eventually(within: 5) { failures.all.contains(.silent) })
        let phoneNoticed = ContinuousClock.now - cut
        reportMetric("real UDP, dead path: the hub noticed after \(hubNoticed), the phone after \(phoneNoticed)")
        #expect(hubNoticed < .milliseconds(3_600))
        #expect(phoneNoticed < .milliseconds(3_600))
    }

    /// The Mac's sound as Opus through the relay at 5% loss: copies and in-band FEC rebuild most of it, the rest is
    /// concealed, and no 10 ms goes missing.
    @Test(.timeLimit(.minutes(1)))
    func soundAtFivePercentLossHasNoHoles() async throws {
        let server = UDPMediaServer(host: "127.0.0.1")
        let port = try await server.start()
        defer { server.stop() }
        let link = LossyRelay.Link(delay: 20_000, loss: 0.05)
        let relay = LossyRelay(toHub: LossyRelay.Link(delay: 20_000), toPhone: link)
        let relayPort = try await relay.start(hubPort: port)
        defer { relay.stop() }
        let (sessionID, key) = TransportKeys.generate()
        let keys = try #require(TransportKeys(sessionID: sessionID, sessionKey: key))
        // Peer relay: one copy of the previous frame in each packet.
        let session = server.makeSession(keys: keys, profile: .profile(for: .peerRelay))
        let client = UDPMediaClient(host: "127.0.0.1", port: relayPort, keys: keys, network: .wifi, video: false)
        defer { client.close() }
        let sound = SoundHarness()
        client.setHandlers(onEvent: { sound.handle($0) }, onFailure: { _ in })
        try await client.connect(timeout: 2)
        let encoder = try OpusAudioEncoder(channels: 2)
        try encoder.configure(profile: .profile(for: .peerRelay), plan: session.snapshot.plan)
        let frames = 500
        let start = ContinuousClock.now
        for index in 0..<frames {
            var pcm = [Float](repeating: 0, count: OpusFormat.frameSamples * 2)
            for sample in 0..<OpusFormat.frameSamples {
                let t = Double(index * OpusFormat.frameSamples + sample) / 48_000
                let value = Float(0.25 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 660 * t))
                pcm[sample * 2] = value
                pcm[sample * 2 + 1] = value
            }
            for packet in try pcm.withUnsafeBufferPointer({ try encoder.encode(interleaved: $0) }) {
                session.sendAudio(packet, timestamp: UInt64(index) * 10_000, duration: OpusFormat.frameDuration)
            }
            try await Task.sleep(until: start + .milliseconds(10 * (index + 1)), clock: .continuous)
        }
        try await Task.sleep(for: .milliseconds(300))
        let stats = sound.finish()
        let counts = relay.counts(.toPhone)
        reportMetric("real UDP, sound at 5% loss (\(counts.lost) of \(counts.forwarded + counts.lost) packets lost): "
            + "\(stats.decoded) frames decoded, of which \(sound.copies) came as copies; \(stats.recovered) rebuilt from "
            + "the next frame, \(stats.concealed) concealed, \(stats.skipped) skipped")
        #expect(counts.lost > 10)
        // Every frame up to the last one played, one way or another.
        #expect(stats.decoded + stats.recovered + stats.concealed + stats.skipped >= frames - 2)
        #expect(sound.copies > 0)
    }
}

// MARK: The hub's side

/// Encodes a moving picture and hands each frame to a phone's UDP session the way `ScreenService` does.
final class HubHarness: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.hub", qos: .userInteractive)
    private let session: UDPServerSession
    private let phone = UUID()
    private var pace: VideoPacing
    private var encoder: VideoEncoder?
    private var target: EncoderTarget?
    private var applied = 0
    private var timer: DispatchSourceTimer?
    private var source: MovingPicture
    private var index = 0
    private var encoded = 0
    private var refused = 0
    private var keyframes = 0
    private var refreshes = 0
    private var targets: [Double] = []
    private var requests = (refresh: 0, keyframe: 0)
    /// What happened when, ms from the start: requests ("r" refresh, "K" keyframe), keyframes and refreshes made
    /// ("k", "f"), feedback asking for a refresh ("?" with the phone's loss count).
    private var timeline: [String] = []
    private let born = ContinuousClock.now
    private var lastAsked: (Int, Int)?
    private var running = false
    /// As `ScreenStreamer.holding`: set by `steer`, false until the first answer.
    private var holding = false

    init(session: UDPServerSession, width: Int = 1280, height: Int = 720) throws {
        self.session = session
        let now = ContinuousClock.now
        pace = VideoPacing(target: 6_000_000, now: now)
        pace.join(phone, now: now)
        source = MovingPicture(width: width, height: height)
        let settings = VideoEncoder.Settings(codec: .hevc, width: width, height: height, fps: 60, bitrate: 6_000_000)
        encoder = try VideoEncoder(settings: settings) { [weak self] output in
            guard case .frame(let message) = output else { return }
            self?.queue.async { self?.deliver(message) }
        }
        applied = 6_000_000
        pace.start(at: applied, now: now)
    }

    func start() {
        queue.async {
            self.running = true
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .microseconds(16_667), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.capture() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            // Frames still in the encoder come out (and are ignored) before it goes.
            encoder?.flush()
            encoder?.invalidate()
            encoder = nil
        }
    }

    struct Counts {
        var encoded = 0
        var refused = 0
        var keyframes = 0
        var refreshes = 0
        var meanTarget = 0.0
        var requests = (refresh: 0, keyframe: 0)
        var timeline = ""
    }

    func counts() -> Counts {
        queue.sync {
            var counts = Counts()
            counts.encoded = encoded
            counts.refused = refused
            counts.keyframes = keyframes
            counts.refreshes = refreshes
            counts.meanTarget = targets.isEmpty ? Double(applied) : targets.reduce(0, +) / Double(targets.count)
            counts.requests = requests
            counts.timeline = timeline.joined(separator: " ")
            return counts
        }
    }

    /// From the session's queue.
    func handle(_ event: SenderEvent) {
        queue.async {
            switch event {
            case .encoderTarget(let target):
                self.target = target
                self.steer()
            case .appMessage(let message):
                guard let feedback = message.screenFeedback else { return }
                if feedback.refresh {
                    let asked = (Int(feedback.sequence ?? 0), feedback.lost ?? 0)
                    if self.lastAsked.map({ $0 != asked }) ?? true {
                        self.lastAsked = asked
                        self.note("?\(asked.0)/\(asked.1)")
                    }
                } else {
                    self.lastAsked = nil
                }
                let acknowledged = self.pace.feedback(feedback, from: self.phone, now: .now)
                self.encoder?.acknowledge(acknowledged)
                self.steer()
            case .hello, .silent:
                break
            }
        }
    }

    private func note(_ event: String) {
        let ms = (ContinuousClock.now - born).components
        timeline.append("\(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000):\(event)")
    }

    /// A captured frame, unless every phone waits for a refresh the encoder hasn't been asked for yet (as
    /// `ScreenStreamer` withholds it).
    private func capture() {
        guard running, let encoder else { return }
        guard !holding || encoder.wantsFrame else { return }
        index += 1
        guard let pixels = source.frame(index, pixelFormat: encoder.pixelFormat) else { return }
        let now = TransportClock.now()
        _ = encoder.encode(pixels, time: CMTime(value: CMTimeValue(now), timescale: 1_000_000),
                           captureTime: Double(now) / 1_000_000)
        targets.append(Double(applied))
    }

    private func deliver(_ message: VideoFrameMessage) {
        guard running else { return }
        encoded += 1
        let summary = VideoPacing.Frame(flags: message.flags, sequence: message.sequence, ltrToken: message.ltrToken)
        pace.produced(summary)
        if message.flags.contains(.keyframe) {
            keyframes += 1
            note("k\(message.sequence)")
        } else if message.flags.contains(.refresh) {
            refreshes += 1
            note("f\(message.sequence)")
        }
        let bytes = message.encoded()
        let refresh = message.flags.contains(.refresh)
        let session = self.session
        let delivery = refresh ? Duration.microseconds(session.deliveryTime(bytes: bytes.count)) : .zero
        _ = pace.admit(summary, to: phone, now: .now, delivery: delivery) {
            if case .sent = session.sendVideo(bytes, refresh: refresh) { return true }
            refused += 1
            return false
        }
        steer()
    }

    private func steer() {
        guard let encoder else { return }
        let session = self.session
        if let request = pace.nextRequest(now: .now, hasRoom: { _ in session.hasRoom }) {
            if request == .keyframe {
                requests.keyframe += 1
                note("K")
                encoder.requestKeyframe()
            } else {
                requests.refresh += 1
                note("r")
                encoder.requestRefresh()
            }
        }
        _ = pace.takeBitrateChange(now: .now)
        let settings = VideoPacing.encoderSettings(bitrate: pace.bitrate, targets: target.map { [$0] } ?? [])
        if settings.bitrate != applied {
            applied = settings.bitrate
            encoder.currentBitrate = applied
        }
        holding = pace.holding
    }
}

/// A screen-like picture: a gradient with text-like detail, and four squares that move every frame. The background is
/// drawn once and copied, so even a Debug build keeps up with 60 fps.
struct MovingPicture {
    let width: Int
    let height: Int
    private let background: [UInt8]
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var background = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // A gradient with text-like 2×2 blocks.
                let detail = ((x / 2) &* 7 &+ (y / 2) &* 13) % 9 == 0 ? 60 : 0
                background[y * width + x] = UInt8(clamping: 40 + x * 150 / width + detail)
            }
        }
        self.background = background
    }

    mutating func frame(_ index: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        if pool == nil || poolFormat != pixelFormat {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferWidthKey: width,
                                               kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolFormat = pixelFormat
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let pixels = made
        else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        background.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for y in 0..<height { (luma + y * lumaRow).update(from: base + y * width, count: width) }
        }
        for y in 0..<height / 2 { (chroma + y * chromaRow).update(repeating: 128, count: width) }
        for square in 0..<4 {
            let size = 96
            let left = (100 + square * 260 + index * (4 + square * 2)) % (width - size)
            let top = (80 + square * 140 + index * 3) % (height - size)
            for y in top..<top + size {
                let row = luma + y * lumaRow
                for x in left..<left + size { row[x] = 220 }
            }
            for y in top / 2..<(top + size) / 2 {
                let row = chroma + y * chromaRow
                for x in left / 2..<(left + size) / 2 {
                    row[x * 2] = UInt8(60 + square * 40)
                    row[x * 2 + 1] = UInt8(200 - square * 30)
                }
            }
        }
        return pixels
    }
}

// MARK: The phone's side

/// Decodes what the session delivers and sends feedback back over it, as `ScreenReceiver` and
/// `ScreenFeedbackSender` do on the iPhone.
final class PhoneHarness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.phone", qos: .userInteractive)
    private let client: UDPMediaClient
    private let decoder = VideoDecoder()
    private var tracker = VideoSequenceTracker()
    private var sequence: UInt32?
    private var tokens: [UInt32] = []
    private var recentTokens: [[UInt32]] = []
    private var refresh = false
    private var lostCount = 0
    private var timer: DispatchSourceTimer?
    private var decoded = 0
    private var lost = 0
    private var delays: [Double] = []
    private var estimateErrors: [Double] = []
    private var recoveries: [Double] = []
    private var lostSince: Int64?
    private var gaveUp = false
    private var trackerSkips = 0
    private var decodeFailures = 0
    /// A frame given up this long before the end and never followed by a decoded refresh counts as unrecovered.
    private static let recoveryLimit: Int64 = 1_500_000
    /// Each decoded frame's capture time and when it was decoded (µs, host clock), on the harness's queue: for the
    /// A/V rig's picture side. Set before the session starts.
    var onDecoded: (@Sendable (_ captured: Int64, _ decodedAt: Int64) -> Void)?

    init(client: UDPMediaClient) {
        self.client = client
    }

    func startFeedback() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(17), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.sendFeedback() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func failed() {
        queue.async { self.gaveUp = true }
    }

    func result() -> UDPEndToEndTests.Result {
        queue.sync {
            var result = UDPEndToEndTests.Result()
            result.decoded = decoded
            result.lost = lost
            result.delays = delays
            result.estimateErrors = estimateErrors
            result.recoveries = recoveries
            result.trackerSkips = trackerSkips
            result.decodeFailures = decodeFailures
            let now = TransportClock.now()
            result.unrecovered = gaveUp || lostSince.map { now - $0 > Self.recoveryLimit } ?? false
            return result
        }
    }

    /// From the session's queue: decoding hops off it, as the app's receiving loop does.
    func handle(_ event: ReceiverEvent) {
        switch event {
        case .frame(let frame):
            queue.async { self.show(frame.data, hubClockOffset: frame.hubClockOffset) }
        case .frameLost:
            queue.async {
                self.lost += 1
                self.lostSince = self.lostSince ?? TransportClock.now()
                // As `ScreenFeedbackSender.frameLost`: the count goes to the hub at once.
                self.lostCount += 1
                self.refresh = true
                self.sendFeedback()
            }
        default:
            break
        }
    }

    private func show(_ data: Data, hubClockOffset: UInt32?) {
        guard let frame = VideoFrameMessage.parse(data) else { return }
        guard tracker.shouldDecode(sequence: frame.sequence, flags: frame.flags) else {
            trackerSkips += 1
            needRefresh()
            return
        }
        do {
            _ = try decoder.decode(frame)
        } catch {
            decodeFailures += 1
            tracker.failed()
            needRefresh()
            return
        }
        tracker.decoded(sequence: frame.sequence, flags: frame.flags)
        let now = TransportClock.now()
        decoded += 1
        let captured = Int64(frame.captureTime * 1_000_000)
        let delay = Double(now - captured) / 1000
        delays.append(delay)
        onDecoded?(captured, now)
        if let hubClockOffset {
            estimateErrors.append(TransportClock.milliseconds(since: captured, hubClockOffset: hubClockOffset, now: now) - delay)
        }
        if let since = lostSince, !tracker.needsRefresh {
            recoveries.append(Double(now - since) / 1000)
            lostSince = nil
        }
        sequence = frame.sequence
        if frame.ltrToken != 0 { tokens.append(frame.ltrToken) }
        refresh = tracker.needsRefresh
        sendFeedback()
    }

    private func needRefresh() {
        guard !refresh else { return }
        refresh = true
        sendFeedback()
    }

    private func sendFeedback() {
        let repeated = recentTokens.joined().filter { !tokens.contains($0) }
        let feedback = ScreenFeedback(sequence: sequence, ltrTokens: repeated + tokens, refresh: refresh,
                                      lost: lostCount > 0 ? lostCount : nil)
        recentTokens.append(tokens)
        if recentTokens.count > 2 { recentTokens.removeFirst() }
        tokens = []
        if let message = AppMessage.feedback(feedback) { try? client.sendAppMessage(message) }
    }
}

/// Plays the session's sound through `AudioPlayout` and the Opus decoder, as `OpusPlayback` does.
final class SoundHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var playout = AudioPlayout()
    private var decoder = try? OpusAudioDecoder(channels: 2)
    private(set) var copies = 0

    func handle(_ event: ReceiverEvent) {
        guard case .audio(let frames) = event else { return }
        lock.withLock {
            copies += frames.filter(\.fromRedundancy).count
            play(playout.add(frames, now: TransportClock.now()) + playout.expire(now: TransportClock.now()))
        }
    }

    func finish() -> AudioPlayout.Stats {
        lock.withLock {
            play(playout.expire(now: TransportClock.now() + 1_000_000))
            return playout.stats
        }
    }

    private func play(_ steps: [AudioPlayout.Step]) {
        for step in steps {
            switch step {
            case .decode(let data, _): _ = try? decoder?.decode(data)
            case .recover(let next, _): _ = try? decoder?.recover(lostBefore: next)
            case .conceal: _ = try? decoder?.conceal()
            }
        }
    }
}

// MARK: The relay

/// A UDP relay on loopback between the phone and the hub: each way it delays packets, drops them at random or in
/// bursts (two-state Gilbert model), and limits the rate behind a tail-drop queue, like the emulator's links.
final class LossyRelay: @unchecked Sendable {
    struct Link: Sendable {
        /// One-way delay, µs.
        var delay: Int64 = 0
        var loss: Double = 0
        /// Gilbert bursts: the chance a packet starts a burst, and that the next is lost too.
        var burst: (enter: Double, stay: Double)?
        /// Bits per second, nil for no limit; the queue holds `queueLimit` µs of it.
        var rate: Int?
        var queueLimit: Int64 = 200_000
        /// Everything lost for `length` µs once every `every` µs (a Wi-Fi hiccup), from a second in.
        var blackout: (every: Int64, length: Int64)?
    }

    struct Counts: Sendable {
        var forwarded = 0
        var lost = 0
        var overflow = 0
        var blocked = 0
    }

    enum Direction { case toHub, toPhone }

    private let queue = DispatchQueue(label: "test.relay", qos: .userInteractive)
    private var links: [Direction: Link]
    private var tallies: [Direction: Counts] = [.toHub: Counts(), .toPhone: Counts()]
    private var busyUntil: [Direction: Int64] = [:]
    private var inBurst: [Direction: Bool] = [:]
    private var blocked: Set<Direction> = []
    private var random: [Direction: SeededGenerator] = [.toHub: SeededGenerator(seed: 11), .toPhone: SeededGenerator(seed: 12)]
    private var listener: NWListener?
    private var phone: NWConnection?
    private var hub: NWConnection?
    private let started = TransportClock.now()

    init(toHub: Link, toPhone: Link) {
        links = [.toHub: toHub, .toPhone: toPhone]
    }

    /// Starts relaying to the hub's port; answers the port the phone should use.
    func start(hubPort: UInt16) async throws -> UInt16 {
        let hub = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: hubPort) ?? .any, using: .udp)
        let listener = try NWListener(using: .udp, on: .any)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async {
                self.hub = hub
                hub.start(queue: self.queue)
                self.receive(from: hub, going: .toPhone)
                var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    self.phone?.cancel()
                    self.phone = connection
                    connection.start(queue: self.queue)
                    self.receive(from: connection, going: .toHub)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            phone?.cancel()
            hub?.cancel()
        }
    }

    /// Drops everything going this way from now on.
    func block(_ direction: Direction) {
        queue.sync { _ = blocked.insert(direction) }
    }

    func counts(_ direction: Direction) -> Counts {
        queue.sync { tallies[direction] ?? Counts() }
    }

    private func receive(from connection: NWConnection, going direction: Direction) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty { self.forward(content, going: direction) }
            if error == nil { self.receive(from: connection, going: direction) }
        }
    }

    private func forward(_ datagram: Data, going direction: Direction) {
        guard let link = links[direction] else { return }
        guard !blocked.contains(direction) else {
            tallies[direction]?.blocked += 1
            return
        }
        if let blackout = link.blackout {
            let elapsed = TransportClock.now() - started - 1_000_000
            if elapsed >= 0, elapsed % blackout.every < blackout.length {
                tallies[direction]?.lost += 1
                return
            }
        }
        guard var generator = random[direction] else { return }
        let draw = Double.random(in: 0..<1, using: &generator)
        random[direction] = generator
        let lost: Bool
        if let burst = link.burst {
            let bad = inBurst[direction] == true ? draw < burst.stay : draw < burst.enter
            inBurst[direction] = bad
            lost = bad
        } else {
            lost = draw < link.loss
        }
        if lost {
            tallies[direction]?.lost += 1
            return
        }
        let now = TransportClock.now()
        var departure = now
        if let rate = link.rate {
            let start = max(now, busyUntil[direction] ?? now)
            guard start - now <= link.queueLimit else {
                tallies[direction]?.overflow += 1
                return
            }
            departure = start + Int64(datagram.count) * 8 * 1_000_000 / Int64(rate)
            busyUntil[direction] = departure
        }
        tallies[direction]?.forwarded += 1
        let wait = departure + link.delay - now
        queue.asyncAfter(deadline: .now() + .microseconds(Int(wait))) { [weak self] in
            guard let self, let target = direction == .toHub ? self.hub : self.phone else { return }
            target.send(content: datagram, completion: .idempotent)
        }
    }
}
