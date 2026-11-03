import CoreMedia
import Foundation
import Observation
import UIKit
import VideoToolbox

/// The live screen: a second connection that carries only the picture, so taps and typing on the control connection
/// never wait behind a frame. Current hubs send hardware HEVC or H.264 video, decoded and shown as each frame arrives;
/// older hubs (or one whose encoders couldn't start) send JPEG. Everything is received and decoded off the main thread
/// (`ScreenReceiver`), which only hands this class the newest picture of each display.
///
/// Once the picture streams, the phone asks for UDP inside Tailscale (`screen.transport`). If the hub answers and its
/// socket replies within a second, the video, the pointer's position and the feedback move to that session, which
/// paces, protects and resends them, and whose rate control sets the encoder's bitrate. Otherwise (an older hub, UDP
/// blocked, or a session that goes quiet for 3 s) everything stays on, or returns to, the WebSocket, and UDP is tried
/// again later.
@Observable
final class ScreenClient {
    enum Quality: String, CaseIterable, Identifiable {
        case low, balanced, sharp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .low: "Data saver"
            case .balanced: "Balanced"
            case .sharp: "Sharp"
            }
        }

        /// HEVC or H.264: the longest side in pixels, frames per second and bits per second. Balanced asks for 120: the
        /// hub runs as fast as the Mac's display refreshes (60 on most, 120 on ProMotion), and older hubs at 60.
        var video: (maxPixels: Int, fps: Int, bitrate: Int) {
            switch self {
            case .low: (1280, 30, 2_000_000)
            case .balanced: (1920, 120, 6_000_000)
            case .sharp: (2560, 45, 10_000_000)
            }
        }

        /// JPEG, from hubs without the video codecs: the longest side in pixels, frames per second and quality.
        var jpeg: (maxPixels: Int, fps: Int, quality: Double) {
            switch self {
            case .low: (1100, 5, 0.45)
            case .balanced: (1700, 8, 0.6)
            case .sharp: (2600, 12, 0.72)
            }
        }
    }

    /// The newest JPEG frame of each display (video frames never become images, see `snapshot(display:)`).
    private(set) var frames: [UInt32: UIImage] = [:]
    private(set) var frameSizes: [UInt32: CGSize] = [:]
    /// Each display's video and pointer, for `RemoteScreenView`.
    private(set) var feeds: [UInt32: VideoFeed] = [:]
    private(set) var streaming = false
    private(set) var error: String?
    private(set) var framesPerSecond = 0.0
    /// For the Screen tab's readout.
    private(set) var stats = StreamStats()
    /// The Mac's displays and Spaces as the hub last told of a change (whoever switched), numbered so the same list
    /// twice still counts.
    private(set) var spacesUpdate: SpacesUpdate?

    struct SpacesUpdate: Equatable {
        var serial: Int
        var displays: [DisplayInfo]
    }
    var quality: Quality = .balanced

    /// Whether any display has a picture yet, video or JPEG.
    var hasPicture: Bool { !frames.isEmpty || feeds.values.contains { $0.size != nil } }

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    /// Requests whose errors aren't the person's business (asking an older hub for UDP).
    @ObservationIgnored private var quiet: Set<Int> = []
    /// The receiving loop's inputs, and the feedback it sends.
    @ObservationIgnored private var inputs: AsyncStream<ScreenInput>.Continuation?
    @ObservationIgnored private var feedback: ScreenFeedbackSender?
    /// The UDP session carrying the picture, while it's up.
    @ObservationIgnored private var udp: UDPMediaClient?
    @ObservationIgnored private var networkObserver: UUID?
    @ObservationIgnored private var udpRetry: Task<Void, Never>?
    /// How long to wait before asking for UDP again after it failed; doubles up to 5 minutes.
    @ObservationIgnored private var udpBackoff = Duration.seconds(15)
    @ObservationIgnored private var keepingAwake: Task<Void, Never>?
    /// `mac.clock` exchanges, for the picture's delay when it comes over the WebSocket.
    @ObservationIgnored private var clockSync: Task<Void, Never>?
    @ObservationIgnored private var pointerShapes: [UInt32: PointerShape] = [:]
    /// The display last asked for, to ask again with other settings.
    @ObservationIgnored private var requestedDisplay: UInt32?
    /// This connection's hub sends JPEG (it's older, or its video encoders couldn't start): ask for JPEG's settings.
    @ObservationIgnored private var jpegOnly = false
    /// A 4:4:4 keyframe didn't decode here: ask for 4:2:0.
    @ObservationIgnored private var avoid444 = false
    /// The part of the display the Screen tab shows (`setViewport`), and its send, held back until zooming settles.
    @ObservationIgnored private var viewport: ScreenViewportParams?
    @ObservationIgnored private var viewportSend: Task<Void, Never>?
    private static let viewportDelay = Duration.milliseconds(250)

    /// "hevc", or "h264" on an iPhone without an HEVC decoder.
    private static let videoCodec = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? "hevc" : "h264"
    /// The 4:4:4 decode check, started once, at launch, off the main thread, so the first stream needn't wait for it.
    private static let checkDecoder = Task.detached(priority: .utility) { _ = VideoDecoder.supports444 }

    init() {
        _ = Self.checkDecoder
    }

    func start(settings: HubSettings, host: String, display: UInt32?) async {
        stop()
        generation += 1
        let attempt = generation
        error = nil
        jpegOnly = false
        avoid444 = false
        pointerShapes = [:]
        stats.frameRateLimit = nil
        MacClock.shared.use(hub: host)
        guard let url = URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(settings.port)/") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: WireProtocol.authorizationHeader)
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        let inbox = ScreenInbox()
        let feedback = ScreenFeedbackSender(task: task)
        let meter = StreamMeter()
        self.feedback = feedback
        task.resume()
        let wake: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.deliver(inbox.take(), attempt: attempt) }
        }
        let (stream, inputs) = AsyncStream<ScreenInput>.makeStream()
        self.inputs = inputs
        Task { await ScreenReceiver.read(task, into: inputs) }
        Task { await ScreenReceiver.run(stream, inbox: inbox, feedback: feedback, meter: meter, wake: wake) }
        do {
            try await call(Method.hello, HelloParams(channel: "screen", device: UIDevice.current.name))
            try await switchDisplay(display)
            guard attempt == generation else { return }
            streaming = true
            keepingAwake = Task { await ScreenReceiver.keepAwake(feedback, meter: meter, inbox: inbox, wake: wake) }
            clockSync = Task { await syncClock(attempt: attempt) }
            udpBackoff = .seconds(15)
            Task { await startTransport(attempt: attempt) }
        } catch {
            if attempt == generation { self.error = HubClient.describe(error) }
        }
    }

    /// Asks for a display (or the main one) with the current quality: video unless this hub sends only JPEG, in 4:4:4
    /// when this iPhone decodes it, with the pointer sent apart from the picture.
    func switchDisplay(_ display: UInt32?) async throws {
        requestedDisplay = display
        if let display { feed(for: display) }
        let codec = jpegOnly ? "jpeg" : Self.videoCodec
        var chroma444 = false
        if codec == "hevc", !avoid444 { chroma444 = await Self.decodes444() }
        let params: ScreenStartParams
        if codec == "jpeg" {
            let jpeg = quality.jpeg
            params = ScreenStartParams(displayId: display, maxPixels: jpeg.maxPixels, fps: jpeg.fps, quality: jpeg.quality,
                                       codec: codec, cursor: true)
        } else {
            let video = quality.video
            params = ScreenStartParams(displayId: display, maxPixels: video.maxPixels, fps: video.fps, quality: quality.jpeg.quality,
                                       codec: codec, bitrate: video.bitrate, chroma444: chroma444, cursor: true)
        }
        try await call(Method.screenStart, params)
        // The hub forgets a phone's viewport with each start: the zoom carries on as it was.
        sendViewport()
    }

    /// The part of the display the Screen tab shows, once a zoom or a pan settles (nil: all of it). The hub hears of it
    /// a moment later (only the last of a quick run), and then captures that part at the display's own resolution.
    /// `immediately`: no waiting for a zoom to settle (a Space switch from a zoomed-in page: the new Space comes whole).
    func setViewport(_ visible: ScreenRegion?, display: UInt32, immediately: Bool = false) {
        let viewport = ScreenViewportParams(displayId: display, visible: visible)
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        viewportSend?.cancel()
        if immediately {
            sendViewport()
            return
        }
        viewportSend = Task { [weak self] in
            try? await Task.sleep(for: Self.viewportDelay)
            guard !Task.isCancelled else { return }
            self?.sendViewport()
        }
    }

    /// Sends the viewport without waiting for an answer: older hubs don't know it, and say nothing.
    private func sendViewport() {
        guard let task, let viewport, let value = try? JSONValue(encoding: viewport),
              let data = try? WireCoding.encoder.encode(ClientFrame(id: nil, method: Method.screenViewport, params: value))
        else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func stop() {
        generation += 1
        endTransport(tellHub: false)
        udpRetry?.cancel()
        udpRetry = nil
        inputs?.finish()
        inputs = nil
        feedback = nil
        if let task { task.cancel(with: .goingAway, reason: nil) }
        task = nil
        keepingAwake?.cancel()
        keepingAwake = nil
        clockSync?.cancel()
        clockSync = nil
        MediaSync.shared.resetPicture()
        streaming = false
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        quiet.removeAll()
    }

    /// A still of a display's newest picture, for the Spaces the Mac isn't showing. A video frame becomes an image only
    /// here, when asked (a few milliseconds); JPEG frames already are images. While zoomed in, the whole display as it
    /// last was.
    func snapshot(display: UInt32) -> UIImage? {
        if let feed = feeds[display], feed.latest != nil { return feed.wholeStill.map { UIImage(cgImage: $0) } }
        return frames[display]
    }

    private func call<P: Encodable>(_ method: String, _ params: P) async throws {
        _ = try await send(method, params, quiet: false)
    }

    /// A request and its answer. A `quiet` one's error isn't shown to the person.
    private func request<P: Encodable, R: Decodable>(_ method: String, _ params: P, quiet: Bool = false) async throws -> R {
        guard let result = try await send(method, params, quiet: quiet) else {
            throw WireError.failed("The Mac sent an empty reply.")
        }
        return try result.decode(R.self)
    }

    private func send<P: Encodable>(_ method: String, _ params: P, quiet: Bool) async throws -> JSONValue? {
        guard let task else { throw WireError.failed("Not connected.") }
        let id = nextId
        nextId += 1
        let data = try WireCoding.encoder.encode(ClientFrame(id: id, method: method, params: try JSONValue(encoding: params)))
        if quiet { self.quiet.insert(id) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue?, Error>) in
            pending[id] = continuation
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                if let waiting = self?.pending.removeValue(forKey: id) {
                    self?.quiet.remove(id)
                    waiting.resume(throwing: WireError.failed("The Mac didn't start the screen in time."))
                }
            }
        }
    }

    /// A message the hub doesn't answer.
    private func notify<P: Encodable>(_ method: String, _ params: P) {
        guard let task, let encoded = try? JSONValue(encoding: params),
              let data = try? WireCoding.encoder.encode(ClientFrame(id: nil, method: method, params: encoded)) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: The Mac's clock

    /// Asks the Mac for its host clock now and then: a few times at first, then every 5 s. Each answer bounds the Mac's
    /// time between the request and the reply; `MacClock` keeps the tightest. A hub that doesn't know the request
    /// (older than step 2) is left alone; the UDP session's estimate needs none of this.
    private func syncClock(attempt: Int) async {
        var exchanges = 0
        while attempt == generation, !Task.isCancelled {
            let sent = TransportClock.now()
            do {
                let result: MacClockResult = try await request(Method.macClock, Empty(), quiet: true)
                MacClock.shared.exchange(sent: sent, hostTime: result.hostTime, received: TransportClock.now())
            } catch {
                if let wire = error as? WireError, wire.code == "bad_request" { return }
            }
            exchanges += 1
            try? await Task.sleep(for: exchanges < 5 ? .milliseconds(300) : .seconds(5))
        }
    }

    // MARK: UDP

    /// Asks the hub for a UDP session and says hello on it; stays on the WebSocket if the hub doesn't know the request
    /// (it's older), has no UDP, or its socket doesn't answer within a second.
    private func startTransport(attempt: Int) async {
        guard attempt == generation, udp == nil, let inputs, let feedback else { return }
        let network = PhoneNetworkMonitor.shared.current
        let result: ScreenTransportResult
        do {
            result = try await request(Method.screenTransport, ScreenTransportParams(network: network, audio: false),
                                       quiet: true)
        } catch {
            return
        }
        guard attempt == generation, let keys = result.keys, let port = UInt16(exactly: result.port) else { return }
        let client = UDPMediaClient(host: result.host, port: port, keys: keys, network: network)
        client.setHandlers(onEvent: { event in inputs.yield(.transport(event)) },
                           onFailure: { [weak self] _ in
                               Task { @MainActor [weak self] in self?.transportFailed(attempt: attempt) }
                           })
        do {
            try await client.connect(timeout: 1)
        } catch {
            guard attempt == generation else { return }
            notify(Method.screenTransport, ScreenTransportParams(versions: [], network: network))
            retryTransport(attempt: attempt)
            return
        }
        guard attempt == generation else {
            client.close()
            return
        }
        udp = client
        feedback.use(client)
        inputs.yield(.transportStarted(client))
        networkObserver = PhoneNetworkMonitor.shared.observe { network in client.networkChanged(to: network) }
        udpBackoff = .seconds(15)
    }

    /// The session went quiet or its socket failed: back to the WebSocket (the hub hears it), and try again later.
    private func transportFailed(attempt: Int) {
        guard attempt == generation, udp != nil else { return }
        endTransport(tellHub: true)
        retryTransport(attempt: attempt)
    }

    private func endTransport(tellHub: Bool) {
        guard let client = udp else { return }
        udp = nil
        feedback?.use(nil)
        if let networkObserver { PhoneNetworkMonitor.shared.stopObserving(networkObserver) }
        networkObserver = nil
        client.close()
        inputs?.yield(.transportEnded)
        if tellHub { notify(Method.screenTransport, ScreenTransportParams(versions: [], network: .other)) }
    }

    private func retryTransport(attempt: Int) {
        let wait = udpBackoff
        udpBackoff = min(udpBackoff * 2, .seconds(300))
        udpRetry?.cancel()
        udpRetry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.startTransport(attempt: attempt)
        }
    }

    // MARK: From the receiving loop

    /// Takes what the receiving loop left: replies, then pictures and pointers, newest only.
    private func deliver(_ batch: ScreenInbox.Batch, attempt: Int) {
        guard attempt == generation else { return }
        for reply in batch.replies { resolve(reply) }
        for shape in batch.shapes { pointerShapes[shape.id] = shape }
        if !batch.shapes.isEmpty {
            for feed in feeds.values { feed.movePointer(to: nil, shapes: pointerShapes) }
        }
        for (display, jpeg) in batch.jpegs { showJPEG(jpeg, on: display) }
        for (display, picture) in batch.pictures {
            if frames[display] != nil {
                frames[display] = nil
                frameSizes[display] = nil
            }
            feed(for: display).show(picture)
        }
        for (display, position) in batch.positions { feed(for: display).movePointer(to: position, shapes: pointerShapes) }
        if let reading = batch.reading { show(reading) }
        if let displays = batch.spaces {
            spacesUpdate = SpacesUpdate(serial: (spacesUpdate?.serial ?? 0) + 1, displays: displays)
        }
        if let info = batch.streamInfo {
            let limit = info.framesPerSecond < info.maxFramesPerSecond ? info.framesPerSecond : nil
            if stats.frameRateLimit != limit { stats.frameRateLimit = limit }
        }
        if batch.failed444, !avoid444 {
            avoid444 = true
            restream()
        }
        if let ended = batch.ended {
            streaming = false
            error = HubClient.describe(ended)
            endTransport(tellHub: false)
            keepingAwake?.cancel()
            clockSync?.cancel()
            MediaSync.shared.resetPicture()
            for continuation in pending.values { continuation.resume(throwing: ended) }
            pending.removeAll()
        }
    }

    private func resolve(_ reply: ServerFrame) {
        guard let id = reply.id, let continuation = pending.removeValue(forKey: id) else { return }
        let quiet = self.quiet.remove(id) != nil
        if let error = reply.error {
            continuation.resume(throwing: error)
            if !quiet { self.error = error.message }
        } else {
            continuation.resume(returning: reply.result)
        }
    }

    private func showJPEG(_ jpeg: JPEGPicture, on display: UInt32) {
        frames[display] = jpeg.image
        if frameSizes[display] != jpeg.size { frameSizes[display] = jpeg.size }
        feeds[display]?.endVideo()
        // JPEG though video was asked for: an older hub, or its encoders couldn't start. JPEG's own settings, then.
        if !jpegOnly {
            jpegOnly = true
            restream()
        }
    }

    private func show(_ reading: StreamMeter.Reading) {
        if framesPerSecond != reading.framesPerSecond { framesPerSecond = reading.framesPerSecond }
        var stats = self.stats
        stats.framesPerSecond = reading.framesPerSecond
        stats.megabitsPerSecond = reading.megabitsPerSecond
        stats.codec = reading.codec
        stats.path = reading.path
        stats.roundTripMs = reading.roundTripMs
        // From the Mac's screen to this one's, the display and any lip-sync hold included; capture to decoded (over UDP)
        // until the Mac's clock is known.
        stats.delayMs = MediaSync.shared.shownPictureDelay() ?? reading.delayMs
        if self.stats != stats { self.stats = stats }
    }

    /// Asks for the same display again, with what's been learnt about this hub and iPhone.
    private func restream() {
        let display = requestedDisplay
        Task { try? await switchDisplay(display) }
    }

    @discardableResult
    private func feed(for display: UInt32) -> VideoFeed {
        if let feed = feeds[display] { return feed }
        let feed = VideoFeed(displayID: display)
        feeds[display] = feed
        return feed
    }

    @concurrent
    private nonisolated static func decodes444() async -> Bool {
        VideoDecoder.supports444
    }
}
