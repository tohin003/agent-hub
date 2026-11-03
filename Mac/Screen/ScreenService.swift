import AppKit
import CoreGraphics

/// Shares each display's stream between the phones watching it, and stops a stream when nobody watches. A display can
/// have two: JPEG for phones from before the video codecs, and one HEVC or H.264 stream for the rest, of which each
/// phone gets the frames its link has room for (`VideoPacing`). Phones that draw the pointer themselves get it from a
/// `CursorTracker`, and every phone watching gets a keepalive tick whenever nothing else went to it for 20 ms.
///
/// A phone that set up UDP (`MediaTransport`) gets its video frames, pointer positions and keepalives over its UDP
/// session, and sends its feedback back that way. The session paces and protects the frames. Its delay-based
/// congestion control sets the encoder's bitrate, and the path's profile caps the frame rate. While no session
/// carries a phone's media, everything goes over the WebSocket as before.
///
/// The frame rate follows the bitrate and how much of the screen moves (`FrameRatePolicy`), so on a slow link it
/// drops before the picture's sharpness does. A phone zoomed in on a display it watches alone gets that part captured
/// at the display's own resolution (`screen.viewport`, `CaptureRegionPlanner`); while several phones watch one display,
/// they all get the whole of it.
@MainActor
final class ScreenService {
    /// A display's stream: JPEG or video.
    private struct StreamKey: Hashable {
        let display: CGDirectDisplayID
        let video: Bool
    }

    private var streamers: [StreamKey: ScreenStreamer] = [:]
    private var viewers: [StreamKey: Set<UUID>] = [:]
    private var clients: [UUID: ClientConnection] = [:]
    /// The stream each phone watches.
    private var watching: [UUID: StreamKey] = [:]
    /// Each video stream's phones, refreshes and bitrate.
    private var pacing: [StreamKey: VideoPacing] = [:]
    /// The phones that draw the pointer themselves, each with the shapes it has been sent.
    private var pointerShapes: [UUID: Set<UInt32>] = [:]
    private let pointer = CursorTracker()
    private var lastReport: [StreamKey: ContinuousClock.Instant] = [:]
    /// What each video encoder was last set to: its bitrate, and its frame-rate cap (0: none).
    private var appliedBitrate: [StreamKey: Int] = [:]
    private var appliedFrameRateCap: [StreamKey: Int] = [:]
    /// Frame-rate changes, one after another (each waits for ScreenCaptureKit), so the last asked for is the one left.
    private var frameRateChanges: [StreamKey: Task<Void, Never>] = [:]
    /// Each video stream's frame rate, and the bytes its encoder made over the last second (how busy the picture is).
    private var frameRates: [StreamKey: FrameRatePolicy] = [:]
    private var produced: [StreamKey: [(at: ContinuousClock.Instant, bytes: Int)]] = [:]
    /// The frame rate each phone was last told (`screen.stream`).
    private var announced: [UUID: ScreenStreamInfo] = [:]
    /// The part of the display each phone shows (`screen.viewport`); the phones that sent one understand frames with a
    /// region; the part each video stream captures (absent: all of it); its changes, one after another.
    private var viewports: [UUID: ScreenViewportParams] = [:]
    private var regionCapable: Set<UUID> = []
    private var appliedRegion: [StreamKey: ScreenRegion] = [:]
    private var regionChanges: [StreamKey: Task<Void, Never>] = [:]
    /// The Spaces last told to the phones, and a check after macOS says they changed.
    private var spacesSent: [DisplayInfo] = []
    private var spaceCheck: Task<Void, Never>?
    /// A Space switch's slide and new picture, until then: not motion the frame rate follows (`FrameRatePolicy`).
    private var burstUntil: [StreamKey: ContinuousClock.Instant] = [:]
    /// A pointer position sent over UDP goes again shortly after the pointer stops, in case the last one was lost.
    private var pointerSettles: [UUID: Task<Void, Never>] = [:]
    private static let pointerSettle: Duration = .milliseconds(60)
    /// How often a video stream's numbers go to the log.
    private static let reportEvery: Duration = .seconds(30)

    init() {
        pointer.onChange = { [weak self] display, position in self?.pointerMoved(position, on: display) }
        // Whoever switches Spaces (the phone, or someone at the Mac), the phones watching hear of it.
        spacesSent = Spaces.displays()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spacesMayHaveChanged() }
        }
    }

    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("Privacy_Accessibility")
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Agent Hub's own switch for the live screen. Off: nothing is captured and watching is refused.
    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }

    /// Ends every stream (the screen switch was turned off).
    func stopAll() {
        for client in clients.values {
            client.screenDisplay = nil
            client.stopScreenKeepalive()
            client.onScreenSent = nil
        }
        clients.removeAll()
        viewers.removeAll()
        watching.removeAll()
        pacing.removeAll()
        appliedBitrate.removeAll()
        appliedFrameRateCap.removeAll()
        frameRateChanges.removeAll()
        frameRates.removeAll()
        produced.removeAll()
        announced.removeAll()
        viewports.removeAll()
        regionCapable.removeAll()
        appliedRegion.removeAll()
        regionChanges.removeAll()
        for settle in pointerSettles.values { settle.cancel() }
        pointerSettles.removeAll()
        pointerShapes.removeAll()
        updatePointerTracking()
        let running = streamers.values
        streamers.removeAll()
        for streamer in running { Task { await streamer.stop() } }
    }

    /// Starts (or switches) the stream a screen connection receives: video when the phone asks for HEVC or H.264 and
    /// the hardware starts one, else JPEG. The frames' kind and codec byte tell the phone which it got.
    func watch(client: ClientConnection, params: ScreenStartParams) async throws {
        guard enabled else {
            throw WireError(code: "screen_off", message: "The live screen is turned off in Agent Hub.")
        }
        guard Self.screenRecordingAllowed else {
            Self.requestScreenRecording()
            throw WireError(code: "screen_recording",
                            message: "Allow Agent Hub in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
        let display = params.displayId.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        stopWatching(client: client)
        clients[client.id] = client
        client.screenDisplay = display
        client.screenSettings = params
        client.onScreenSent = { [weak self] client in self?.screenSent(client) }
        // Over UDP, the session keeps the Wi-Fi awake itself.
        if client.udp == nil { client.startScreenKeepalive() }
        if params.cursor == true { pointerShapes[client.id] = [] }
        do {
            if params.codec == "hevc" || params.codec == "h264" {
                do {
                    try await watchVideo(client, display: display, params: params)
                    return
                } catch is ScreenStreamer.NoVideoEncoder {
                    Log.warn("screen: no hardware video encoder started for display \(display): \(client.device) gets JPEG")
                    guard clients[client.id] === client else { return }
                }
            }
            try await watchJPEG(client, display: display, params: params)
        } catch {
            // Not watching anything, then: no ticks, and no frames from a stream another phone starts later.
            if clients[client.id] === client { stopWatching(client: client) }
            throw error
        }
    }

    private func add(_ client: ClientConnection, to key: StreamKey) {
        viewers[key, default: []].insert(client.id)
        watching[client.id] = key
        guard pointerShapes[client.id] != nil else { return }
        updatePointerTracking()
        if let position = pointer.position(on: key.display) { sendPointer(position, to: client.id) }
    }

    private func remove(_ id: UUID, from key: StreamKey) {
        viewers[key]?.remove(id)
        if watching[id] == key { watching[id] = nil }
        if let acknowledged = pacing[key]?.leave(id), !acknowledged.isEmpty { streamers[key]?.acknowledge(acknowledged) }
    }

    private func watchJPEG(_ client: ClientConnection, display: CGDirectDisplayID, params: ScreenStartParams) async throws {
        let key = StreamKey(display: display, video: false)
        add(client, to: key)
        if let streamer = streamers[key] {
            if let frame = streamer.latestFrame { client.sendScreenFrame(frame) }
            // The newest watcher's quality wins.
            let hiding = hiddenWindows
            await streamer.update(maxPixels: params.maxPixels, fps: params.fps, quality: params.quality,
                                  showsCursor: params.cursor != true, hiding: hiding)
            // The privacy screen went up or down while it restarted.
            if hiddenWindows != hiding { await streamer.refreshFilter(hiding: hiddenWindows) }
            return
        }
        let streamer = ScreenStreamer(displayID: display)
        streamer.onFrame = { [weak self] frame in
            Task { @MainActor in self?.deliver(frame, to: key) }
        }
        streamer.onStop = { [weak self, weak streamer] _ in
            Task { @MainActor in self?.stopped(streamer, key) }
        }
        streamers[key] = streamer
        let hiding = hiddenWindows
        do {
            try await streamer.start(params, hiding: hiding)
        } catch {
            if streamers[key] === streamer { streamers[key] = nil }
            throw WireError.failed("The screen couldn't be captured: \(error.localizedDescription)")
        }
        // Everyone left (or sharing was turned off) while it was starting: stop it now.
        if streamers[key] !== streamer || viewers[key]?.isEmpty ?? true || !enabled {
            if streamers[key] === streamer { streamers[key] = nil }
            await streamer.stop()
        } else if hiddenWindows != hiding {
            // The privacy screen went up or down while it was starting.
            await streamer.refreshFilter(hiding: hiddenWindows)
        }
    }

    /// Joins the display's video stream, or starts it. Throws `NoVideoEncoder` (and leaves it) if no encoder starts.
    private func watchVideo(_ client: ClientConnection, display: CGDirectDisplayID, params: ScreenStartParams) async throws {
        let key = StreamKey(display: display, video: true)
        add(client, to: key)
        let now = ContinuousClock.now
        if let streamer = streamers[key], pacing[key] != nil {
            pacing[key]?.join(client.id, now: now)
            if let bitrate = params.bitrate { pacing[key]?.setTarget(bitrate) }
            // The newest phone's settings win; a stream already running them just makes it a keyframe.
            if let running = streamer.videoShape, running != ScreenStreamer.VideoShape(params) {
                await restart(streamer, key, params, previous: running)
            }
            // A second phone: the whole display for both.
            applyRegion(key)
            steer(key)
            return
        }
        let streamer = ScreenStreamer(displayID: display, video: true)
        streamer.onVideoFrame = { [weak self] frame in
            // The main queue keeps the frames in order: a delta frame out of order wouldn't decode.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(frame, to: key) }
            }
        }
        streamer.onStop = { [weak self, weak streamer] _ in
            Task { @MainActor in self?.stopped(streamer, key) }
        }
        streamers[key] = streamer
        var pace = VideoPacing(target: params.bitrate ?? VideoPacing.lowestBitrate, now: now)
        for id in viewers[key] ?? [] { pace.join(id, now: now) }
        pacing[key] = pace
        let hiding = hiddenWindows
        do {
            try await streamer.start(params, hiding: hiding)
        } catch {
            if streamers[key] === streamer {
                streamers[key] = nil
                pacing[key] = nil
            }
            remove(client.id, from: key)
            if error is ScreenStreamer.NoVideoEncoder { throw error }
            throw WireError.failed("The screen couldn't be captured: \(error.localizedDescription)")
        }
        // Everyone left (or sharing was turned off) while it was starting: stop it now.
        guard streamers[key] === streamer, !(viewers[key]?.isEmpty ?? true), enabled else {
            if streamers[key] === streamer {
                streamers[key] = nil
                pacing[key] = nil
            }
            await streamer.stop()
            return
        }
        if let bitrate = streamer.videoBitrate { pacing[key]?.start(at: bitrate, now: .now) }
        startedEncoder(key, streamer)
        // The privacy screen went up or down while it was starting.
        if hiddenWindows != hiding { await streamer.refreshFilter(hiding: hiddenWindows) }
        steer(key)
    }

    /// A new encoder runs at the bitrate it started with, at its full frame rate and on the whole display: the UDP
    /// sessions' limits, the frame-rate policy and a lone phone's zoom apply again from here.
    private func startedEncoder(_ key: StreamKey, _ streamer: ScreenStreamer) {
        appliedBitrate[key] = streamer.videoBitrate
        appliedFrameRateCap[key] = 0
        frameRates[key] = FrameRatePolicy(maximum: streamer.fullFrameRate)
        produced[key] = nil
        appliedRegion[key] = nil
        // A change still queued for the stream before this encoder would leave it on a part nobody asked for.
        applyRegion(key, force: regionChanges[key] != nil)
    }

    /// Starts a video stream again with a newer phone's settings; if they don't start, with the ones it had.
    private func restart(_ streamer: ScreenStreamer, _ key: StreamKey, _ params: ScreenStartParams,
                         previous: ScreenStreamer.VideoShape) async {
        let hiding = hiddenWindows
        pacing[key]?.restarting(now: .now)
        var started = await streamer.restart(params, hiding: hiding)
        if !started {
            let old = ScreenStartParams(displayId: params.displayId, maxPixels: previous.maxPixels, fps: previous.fps,
                                        quality: params.quality, codec: previous.codec,
                                        bitrate: pacing[key].map { $0.target }, chroma444: previous.chroma444,
                                        cursor: !previous.showsCursor)
            started = await streamer.restart(old, hiding: hiding)
        }
        // Everyone left while it restarted.
        guard streamers[key] === streamer else {
            await streamer.stop()
            return
        }
        if started, let bitrate = streamer.videoBitrate { pacing[key]?.start(at: bitrate, now: .now) }
        if started { startedEncoder(key, streamer) }
        if hiddenWindows != hiding { await streamer.refreshFilter(hiding: hiddenWindows) }
        steer(key)
    }

    /// The privacy screen's windows, which every stream leaves out while it's up: the phone sees everything they
    /// cover, and nothing else is left out.
    private(set) var hiddenWindows: Set<CGWindowID> = []

    func hide(windows: Set<CGWindowID>) async {
        hiddenWindows = windows
        for streamer in Array(streamers.values) { await streamer.refreshFilter(hiding: hiddenWindows) }
    }

    func stopWatching(client: ClientConnection) {
        client.stopScreenKeepalive()
        client.onScreenSent = nil
        client.screenDisplay = nil
        clients[client.id] = nil
        pointerSettles.removeValue(forKey: client.id)?.cancel()
        // A phone sends its viewport again after every `screen.start`.
        viewports[client.id] = nil
        regionCapable.remove(client.id)
        announced[client.id] = nil
        let drewPointer = pointerShapes.removeValue(forKey: client.id) != nil
        if let key = watching[client.id] {
            remove(client.id, from: key)
            if viewers[key]?.isEmpty ?? true {
                viewers[key] = nil
                pacing[key] = nil
                lastReport[key] = nil
                appliedBitrate[key] = nil
                appliedFrameRateCap[key] = nil
                frameRateChanges[key] = nil
                frameRates[key] = nil
                produced[key] = nil
                appliedRegion[key] = nil
                regionChanges[key] = nil
                if let streamer = streamers.removeValue(forKey: key) {
                    Task { await streamer.stop() }
                }
            } else if key.video {
                // The phone left on its own may have zoomed in.
                applyRegion(key)
                steer(key)
            }
        }
        if drewPointer { updatePointerTracking() }
    }

    /// The capture stopped on its own (a display went away).
    private func stopped(_ streamer: ScreenStreamer?, _ key: StreamKey) {
        guard let streamer, streamers[key] === streamer else { return }
        streamers[key] = nil
    }

    private func deliver(_ frame: Data, to key: StreamKey) {
        for id in viewers[key] ?? [] {
            clients[id]?.sendScreenFrame(frame)
        }
    }

    // MARK: Video

    private func deliver(_ frame: ScreenStreamer.VideoFrame, to key: StreamKey) {
        guard var pace = pacing[key] else { return }
        let now = ContinuousClock.now
        let summary = VideoPacing.Frame(flags: frame.flags, sequence: frame.sequence, ltrToken: frame.ltrToken)
        pace.produced(summary)
        var made = (produced[key] ?? []).filter { now - $0.at < .seconds(1) }
        if burstUntil[key].map({ now >= $0 }) ?? true { made.append((now, frame.bytes.count)) }
        produced[key] = made
        let refresh = frame.flags.contains(.refresh)
        for id in viewers[key] ?? [] {
            guard let client = clients[id] else { continue }
            if frame.region != nil, !regionCapable.contains(id) {
                // A frame of part of the display, still on its way as this phone joined: an older phone would read the
                // region as picture. It waits for a frame of the whole display, as after a skip.
                _ = pace.admit(summary, to: id, now: now, delivery: .zero) { false }
                continue
            }
            if let session = client.udp {
                // The session takes the frame or refuses it whole, before any of it goes out. A refresh or keyframe
                // may take a while to arrive on a slow path; the phone isn't hurried for it.
                let delivery = refresh ? Duration.microseconds(session.deliveryTime(bytes: frame.bytes.count)) : .zero
                _ = pace.admit(summary, to: id, now: now, delivery: delivery) {
                    if case .sent = session.sendVideo(frame.bytes, refresh: refresh) { return true }
                    return false
                }
                continue
            }
            guard pace.admit(summary, to: id, backlog: client.screenBacklog, keyframeBacklog: client.keyframeBacklog,
                             now: now) else { continue }
            client.sendScreen(frame.bytes, keyframe: frame.flags.contains(.keyframe))
        }
        pacing[key] = pace
        steer(key)
    }

    /// `screen.feedback` from a phone: frames to acknowledge to the encoder, a refresh it needs, what it receives.
    func feedback(_ feedback: ScreenFeedback, from client: ClientConnection) {
        guard let key = watching[client.id], key.video, var pace = pacing[key] else { return }
        let acknowledged = pace.feedback(feedback, from: client.id, now: .now)
        pacing[key] = pace
        streamers[key]?.acknowledge(acknowledged)
        steer(key)
    }

    /// A phone's backlog went down: one waiting for a refresh may now take it.
    private func screenSent(_ client: ClientConnection) {
        guard let key = watching[client.id], key.video, pacing[key]?.waiting(client.id) == .refresh else { return }
        steer(key)
    }

    /// Asks the encoder for what the phones need, sets its bitrate and frame rate, and holds it while every phone
    /// waits. The bitrate is the lowest of `VideoPacing`'s (the one asked for, cut when a WebSocket backs up) and each
    /// UDP session's target; the frame rate follows that bitrate and the motion (`FrameRatePolicy`), within the slowest
    /// UDP path's profile.
    private func steer(_ key: StreamKey) {
        guard var pace = pacing[key], let streamer = streamers[key] else { return }
        let now = ContinuousClock.now
        let clients = self.clients
        let cap = pace.cap
        let request = pace.nextRequest(now: now, hasRoom: { id in
            guard let client = clients[id] else { return false }
            if let session = client.udp { return session.hasRoom }
            return client.screenBacklog <= cap
        })
        if let request { streamer.refresh(keyframe: request == .keyframe) }
        _ = pace.takeBitrateChange(now: now)
        let targets = (viewers[key] ?? []).compactMap { clients[$0]?.udp != nil ? clients[$0]?.mediaTarget : nil }
        let settings = VideoPacing.encoderSettings(bitrate: pace.bitrate, targets: targets)
        let bitrate = settings.bitrate
        if appliedBitrate[key] != bitrate {
            appliedBitrate[key] = bitrate
            streamer.setBitrate(bitrate)
        }
        let full = streamer.fullFrameRate
        let made = (produced[key] ?? []).filter { now - $0.at < .seconds(1) }.reduce(0) { $0 + $1.bytes }
        let used = bitrate > 0 ? Double(made * 8) / Double(bitrate) : 0
        var rate = frameRates[key]?.update(bitrate: bitrate, used: used, now: now) ?? full
        if let profileCap = settings.frameRateCap, profileCap > 0 { rate = min(rate, profileCap) }
        let frameRateCap = rate >= full ? 0 : rate
        announce(ScreenStreamInfo(framesPerSecond: min(rate, full), maxFramesPerSecond: full), to: key)
        if appliedFrameRateCap[key] != frameRateCap {
            appliedFrameRateCap[key] = frameRateCap
            let previous = frameRateChanges[key]
            frameRateChanges[key] = Task {
                await previous?.value
                await streamer.limitFrameRate(frameRateCap > 0 ? frameRateCap : nil)
            }
        }
        streamer.holding = pace.holding
        if now - (lastReport[key] ?? now) >= Self.reportEvery {
            let counts = pace.takeCounts()
            if counts.sent + counts.skipped > 0 {
                let received = counts.received.map { String(format: ", the phones receive %.1f", $0 / 1_000_000) } ?? ""
                let udp = targets.isEmpty ? "" : "; over UDP: " + targets.map {
                    "\($0.path.rawValue) \(String(format: "%.1f", Double($0.videoBitrate) / 1_000_000))"
                }.joined(separator: ", ")
                Log.info("screen: display \(key.display) video: \(counts.sent) frames sent, \(counts.skipped) skipped in "
                    + "\(Self.reportEvery); \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbit/s of "
                    + "\(String(format: "%.1f", Double(pace.target) / 1_000_000))\(received)\(udp)")
            }
            lastReport[key] = now
        } else if lastReport[key] == nil {
            lastReport[key] = now
        }
        pacing[key] = pace
    }

    /// Tells each phone watching the stream its frame rate, when that changed (`screen.stream`).
    private func announce(_ info: ScreenStreamInfo, to key: StreamKey) {
        for id in viewers[key] ?? [] where announced[id] != info {
            guard let client = clients[id] else { continue }
            announced[id] = info
            client.emit(Event.screenStream, info)
        }
    }

    // MARK: Spaces

    /// macOS says a Space changed: read the Spaces a moment later (and again, as SkyLight can be late) and tell the phones.
    private func spacesMayHaveChanged() {
        spaceCheck?.cancel()
        spaceCheck = Task { [weak self] in
            for wait in [50, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled, let self else { return }
                spacesChanged(Spaces.displays())
            }
        }
    }

    /// The Spaces as they are now (after a switch, or a change macOS told of). For a display whose current Space changed:
    /// a refresh, so the new Space comes whole and sharp at once (an ordinary frame, not a keyframe); its slide and new
    /// picture don't count as motion for a second; and every phone watching hears the new Spaces.
    func spacesChanged(_ displays: [DisplayInfo]) {
        let changed = SpaceChanges.changed(spacesSent, displays)
        guard !changed.isEmpty else { return }
        spacesSent = displays
        let now = ContinuousClock.now
        for (key, streamer) in streamers where key.video && changed.contains(key.display) {
            burstUntil[key] = now + .seconds(1)
            produced[key] = []
            streamer.refresh(keyframe: false)
        }
        for client in clients.values { client.emit(Event.screenSpaces, displays) }
    }

    // MARK: Zoom

    /// `screen.viewport` from a phone: the part of the display it shows. A phone that watches a display alone gets what's
    /// around that part captured at the display's own resolution.
    func viewport(_ viewport: ScreenViewportParams, from client: ClientConnection) {
        guard clients[client.id] === client else { return }
        regionCapable.insert(client.id)
        viewports[client.id] = viewport
        guard let key = watching[client.id], key.video else { return }
        applyRegion(key)
    }

    /// Captures the part of the display its phone shows when one phone watches the stream, else all of it. Changes go
    /// to ScreenCaptureKit one after another, so the last asked for is the one left; a change too small to matter
    /// isn't made (`force` makes it anyway).
    private func applyRegion(_ key: StreamKey, force: Bool = false) {
        guard key.video, let streamer = streamers[key], let geometry = streamer.captureGeometry else { return }
        let ids = viewers[key] ?? []
        var wanted: ScreenRegion?
        if ids.count == 1, let id = ids.first, let viewport = viewports[id], viewport.displayId == key.display {
            wanted = CaptureRegionPlanner.region(showing: viewport.visible, output: geometry.output, display: geometry.display)
        }
        guard force || !CaptureRegionPlanner.isClose(wanted, appliedRegion[key]) else { return }
        appliedRegion[key] = wanted
        let previous = regionChanges[key]
        regionChanges[key] = Task {
            await previous?.value
            await streamer.setRegion(wanted)
        }
    }

    // MARK: Pointer

    private func updatePointerTracking() {
        pointer.track(Set(pointerShapes.keys.compactMap { watching[$0]?.display }))
    }

    private func pointerMoved(_ position: CursorPositionMessage, on display: CGDirectDisplayID) {
        for id in pointerShapes.keys where watching[id]?.display == display {
            sendPointer(position, to: id)
        }
    }

    /// A position, after its shape if this phone doesn't have that yet. Shapes always take the WebSocket (they mustn't
    /// be lost); positions take UDP when the phone is on it, and the newest goes again once the pointer rests, so a lost
    /// last position doesn't leave the phone's pointer short of where it stopped.
    private func sendPointer(_ position: CursorPositionMessage, to id: UUID) {
        guard let client = clients[id], var shapes = pointerShapes[id] else { return }
        if !shapes.contains(position.shapeID) {
            guard let shape = pointer.shapeMessage(position.shapeID) else { return }
            client.sendScreen(shape)
            shapes.insert(position.shapeID)
            pointerShapes[id] = shapes
        }
        guard let session = client.udp else {
            client.sendPointer(position.encoded())
            return
        }
        try? session.sendAppMessage(.pointer(position))
        pointerSettles[id]?.cancel()
        pointerSettles[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.pointerSettle)
            guard !Task.isCancelled, let self, self.clients[id]?.udp === session else { return }
            self.pointerSettles[id] = nil
            try? session.sendAppMessage(.pointer(position))
        }
    }

    // MARK: UDP

    /// A phone's media now goes over UDP: its keepalives come from the session, and its next frame is a refresh, as
    /// frames still on their way over the WebSocket may arrive after the session's first.
    func mediaStarted(_ client: ClientConnection) {
        guard clients[client.id] === client, let key = watching[client.id] else { return }
        client.stopScreenKeepalive()
        guard key.video else { return }
        pacing[key]?.resume(client.id, now: .now)
        steer(key)
    }

    /// From a phone's UDP session: a new target for the encoder, or the phone's feedback.
    func mediaEvent(_ event: SenderEvent, from client: ClientConnection) {
        guard clients[client.id] === client, let key = watching[client.id], key.video else { return }
        switch event {
        case .encoderTarget:
            steer(key)
        case .appMessage(let message):
            if let feedback = message.screenFeedback { self.feedback(feedback, from: client) }
        case .hello, .silent:
            break
        }
    }

    /// The phone's UDP session ended: back to the WebSocket, from a refresh frame.
    func mediaEnded(_ client: ClientConnection) {
        pointerSettles.removeValue(forKey: client.id)?.cancel()
        guard clients[client.id] === client, let key = watching[client.id] else { return }
        client.startScreenKeepalive()
        guard key.video else { return }
        pacing[key]?.resume(client.id, now: .now)
        steer(key)
    }
}
