import Foundation
import Synchronization
import UIKit

/// What the screen's receiving loop reads, in arrival order: the WebSocket's messages and, while it's up, the UDP
/// session's events. Both carry the same video frames, so one decoder and one sequence tracker see the stream whichever
/// way each frame came.
nonisolated enum ScreenInput: Sendable {
    case message(URLSessionWebSocketTask.Message)
    /// The WebSocket ended, with this error.
    case ended(any Error)
    /// The UDP session is up (or a newer one is).
    case transportStarted(UDPMediaClient)
    case transport(ReceiverEvent)
    /// The UDP session ended: the picture comes over the WebSocket again.
    case transportEnded
}

/// The screen connection's receiving side, off the main thread: it reads every message as it arrives, decodes video
/// and JPEG frames, answers with feedback, and leaves the main thread (`ScreenClient`) only what changed. A busy main
/// thread then skips to the newest picture instead of holding up the connection.
nonisolated enum ScreenReceiver {
    /// Reads the WebSocket into the loop's inputs until it ends.
    @concurrent
    static func read(_ task: URLSessionWebSocketTask, into inputs: AsyncStream<ScreenInput>.Continuation) async {
        while true {
            do {
                inputs.yield(.message(try await task.receive()))
            } catch {
                inputs.yield(.ended(error))
                inputs.finish()
                return
            }
        }
    }

    /// Receives until the connection ends. `wake` is called when the inbox has something new for the main thread.
    @concurrent
    static func run(_ inputs: AsyncStream<ScreenInput>, inbox: ScreenInbox, feedback: ScreenFeedbackSender,
                    meter: StreamMeter, wake: @escaping @Sendable () -> Void) async {
        var video = VideoReceiver(feedback: feedback)
        func post(_ add: (inout ScreenInbox.Batch) -> Void) {
            if inbox.post(add) { wake() }
        }
        /// A video frame, from either way. Over UDP, `hubClockOffset` maps the hub's clock onto this one, so the frame's
        /// delay from capture to decoded can be measured.
        func show(_ data: Data, overUDP: Bool, hubClockOffset: UInt32? = nil) {
            guard let frame = VideoFrameMessage.parse(data) else { return }
            feedback.received(bytes: data.count)
            meter.received(bytes: data.count, overUDP: overUDP)
            let keyframe444 = frame.flags.contains(.keyframe) && frame.flags.contains(.chroma444)
            switch video.receive(frame) {
            case .shown(let picture):
                meter.shown(codec: label(frame))
                if let hubClockOffset {
                    meter.delay(TransportClock.milliseconds(since: Int64(frame.captureTime * 1_000_000),
                                                            hubClockOffset: hubClockOffset))
                }
                post { $0.pictures[frame.displayID] = picture }
                // Only a software decoder took this 4:4:4 stream (too big for the hardware's): 4:2:0 is faster.
                if keyframe444, !video.usingHardware { post { $0.failed444 = true } }
            case .failed where keyframe444:
                // A keyframe decodes on its own: this iPhone can't do this 4:4:4 stream.
                post { $0.failed444 = true }
            case .failed, .skipped:
                break
            }
        }
        for await input in inputs {
            let message: URLSessionWebSocketTask.Message
            switch input {
            case .message(let received):
                message = received
            case .ended(let error):
                post { $0.ended = error }
                return
            case .transportStarted:
                continue
            case .transport(let event):
                switch event {
                case .frame(let frame):
                    show(frame.data, overUDP: true, hubClockOffset: frame.hubClockOffset)
                case .frameLost:
                    // Given up at its deadline: ask for a refresh now, before the next frame shows the gap.
                    feedback.frameLost()
                case .appMessage(let app):
                    if let position = app.pointerPosition { post { $0.positions[position.displayID] = position } }
                case .connected(let roundTrip, let path):
                    meter.transport(path: path, roundTrip: roundTrip > 0 ? roundTrip : nil)
                case .report(let report):
                    meter.transport(path: report.path,
                                    roundTrip: report.roundTripMicros > 0 ? Int64(report.roundTripMicros) : nil)
                case .clock(let offset):
                    MacClock.shared.transport(offset: offset)
                case .frameSkipped, .audio:
                    break
                }
                continue
            case .transportEnded:
                meter.transport(path: nil, roundTrip: nil)
                continue
            }
            switch message {
            case .data(let data):
                switch data.first {
                case VideoFrameMessage.kind:
                    show(data, overUDP: false)
                case ScreenFrameHeader.jpegKind:
                    guard let jpeg = ScreenFrameHeader.parse(data) else { break }
                    feedback.received(bytes: data.count)
                    meter.received(bytes: data.count, overUDP: false)
                    guard let image = UIImage(data: jpeg.jpeg)?.preparingForDisplay() else { break }
                    meter.shown(codec: "JPEG")
                    let picture = JPEGPicture(image: image, size: CGSize(width: jpeg.width, height: jpeg.height))
                    post { $0.jpegs[jpeg.displayID] = picture }
                case CursorPositionMessage.kind:
                    guard let position = CursorPositionMessage.parse(data) else { break }
                    post { $0.positions[position.displayID] = position }
                case CursorShapeMessage.kind:
                    guard let message = CursorShapeMessage.parse(data), let image = UIImage(data: message.png) else { break }
                    let shape = PointerShape(id: message.shapeID, image: image, size: CGSize(width: message.width, height: message.height),
                                             hotSpot: CGPoint(x: message.hotSpotX, y: message.hotSpotY))
                    post { $0.shapes.append(shape) }
                default:
                    // `StreamKeepalive`, and kinds this version doesn't know.
                    break
                }
            case .string(let text):
                guard let frame = try? WireCoding.decoder.decode(ServerFrame.self, from: Data(text.utf8)) else { break }
                if frame.id != nil {
                    post { $0.replies.append(frame) }
                } else if frame.event == Event.screenStream, let info = try? frame.data?.decode(ScreenStreamInfo.self) {
                    post { $0.streamInfo = info }
                } else if frame.event == Event.screenSpaces, let displays = try? frame.data?.decode([DisplayInfo].self) {
                    post { $0.spaces = displays }
                }
            @unknown default:
                break
            }
        }
    }

    /// Feedback at least every 20 ms while the picture streams, frames or not: the hub hears how the stream is going,
    /// and the iPhone's Wi-Fi never dozes between frames. The readout's numbers go to the main thread from here twice a
    /// second, so they fall to 0 fps on a still screen whichever way the picture comes.
    @concurrent
    static func keepAwake(_ feedback: ScreenFeedbackSender, meter: StreamMeter, inbox: ScreenInbox,
                          wake: @escaping @Sendable () -> Void) async {
        while !Task.isCancelled {
            let next = feedback.sendIfDue()
            if let reading = meter.reading(), inbox.post({ $0.reading = reading }) { wake() }
            try? await Task.sleep(until: next, tolerance: .milliseconds(1), clock: .continuous)
        }
    }

    /// The readout's name for a frame's codec.
    static func label(_ frame: VideoFrameMessage) -> String {
        switch frame.codec {
        case .hevc: frame.flags.contains(.chroma444) ? "HEVC 4:4:4" : "HEVC"
        case .h264: "H.264"
        }
    }
}

/// What the receiving loop leaves for the main thread until it runs: the newest picture and pointer position for each
/// display (older ones are dropped, so a busy main thread skips pictures instead of falling behind), and the rest in
/// order.
nonisolated final class ScreenInbox: Sendable {
    struct Batch: Sendable {
        var pictures: [UInt32: VideoDecoder.Picture] = [:]
        var jpegs: [UInt32: JPEGPicture] = [:]
        var positions: [UInt32: CursorPositionMessage] = [:]
        var shapes: [PointerShape] = []
        var replies: [ServerFrame] = []
        var reading: StreamMeter.Reading?
        /// The frame rate the hub runs the picture at now (`screen.stream`).
        var streamInfo: ScreenStreamInfo?
        /// The Mac's displays and Spaces, when a current Space changed (`screen.spaces`).
        var spaces: [DisplayInfo]?
        /// A 4:4:4 keyframe didn't decode.
        var failed444 = false
        /// The connection ended, with this error.
        var ended: (any Error)?
    }

    private struct State: Sendable {
        var batch = Batch()
        var waking = false
    }

    private let state = Mutex(State())

    /// Adds to what's waiting; true when the main thread needs waking for it (it isn't already on its way).
    func post(_ add: (inout Batch) -> Void) -> Bool {
        state.withLock { state in
            add(&state.batch)
            guard !state.waking else { return false }
            state.waking = true
            return true
        }
    }

    /// Everything waiting, for the main thread.
    func take() -> Batch {
        state.withLock { state in
            let batch = state.batch
            state.batch = Batch()
            state.waking = false
            return batch
        }
    }
}

/// A decoded JPEG frame and the size the hub gave it.
nonisolated struct JPEGPicture: Sendable {
    var image: UIImage
    var size: CGSize
}

/// `screen.feedback` for the hub: the newest frame decoded, the long-term reference tokens to acknowledge, whether the
/// phone needs a refresh frame, and how fast the picture arrives. Sent with every decoded frame and, through
/// `ScreenReceiver.keepAwake`, at least every 20 ms. Sending under the lock keeps feedback in order on the wire.
///
/// While the UDP session is up, feedback rides it (`MediaChannel.feedback`): a refresh request then never waits
/// behind a lost TCP segment. A UDP message can be lost, so each one also repeats the tokens of the two before it (the
/// hub ignores tokens it already has), and a needed refresh is asked for in every message until one decodes.
nonisolated final class ScreenFeedbackSender: Sendable {
    /// The longest gap between two feedback messages, less a little for the timer's slack.
    static let interval = Duration.milliseconds(17)
    /// How many earlier messages' tokens each UDP message repeats.
    static let repeatedBatches = 2

    private struct State: Sendable {
        var sequence: UInt32?
        var ltrTokens: [UInt32] = []
        var refresh = false
        var receivedBytes = 0
        var decodeMs: Double?
        var lastSent = ContinuousClock.now
        var udp: UDPMediaClient?
        /// Tokens of the last few messages, newest last, repeated over UDP.
        var recentTokens: [[UInt32]] = []
        /// Frames the UDP transport gave up so far, for the hub (`ScreenFeedback.lost`).
        var lost = 0
    }

    private let task: URLSessionWebSocketTask
    private let state = Mutex(State())

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    /// Sends feedback over this UDP session from now on; nil goes back to the WebSocket.
    func use(_ udp: UDPMediaClient?) {
        state.withLock { state in
            state.udp = udp
            state.recentTokens = []
        }
    }

    /// Picture bytes arrived.
    func received(bytes: Int) {
        state.withLock { $0.receivedBytes += bytes }
    }

    /// A frame decoded and went to the screen: the hub hears at once.
    func decoded(sequence: UInt32, ltrToken: UInt32, decodeMs: Double, needsRefresh: Bool) {
        state.withLock { state in
            state.sequence = sequence
            if ltrToken != 0 { state.ltrTokens.append(ltrToken) }
            state.decodeMs = decodeMs
            state.refresh = needsRefresh
            send(&state)
        }
    }

    /// The phone lost its place: it asks for a refresh frame at once, then in every feedback until one decodes.
    func needRefresh() {
        state.withLock { state in
            guard !state.refresh else { return }
            state.refresh = true
            send(&state)
        }
    }

    /// The UDP transport gave up a frame: the hub hears at once (with the running count, so it knows a refresh it sent
    /// meanwhile may be lost too), and a refresh is asked for until one decodes.
    func frameLost() {
        state.withLock { state in
            state.lost += 1
            state.refresh = true
            send(&state)
        }
    }

    /// Another stream (another display): nothing of it decoded yet.
    func startOver() {
        state.withLock { state in
            state.sequence = nil
            state.ltrTokens = []
            state.refresh = false
            state.decodeMs = nil
        }
    }

    /// Sends feedback if none went out for an interval; returns when the next one is due.
    func sendIfDue() -> ContinuousClock.Instant {
        state.withLock { state in
            if ContinuousClock.now - state.lastSent >= Self.interval { send(&state) }
            return state.lastSent + Self.interval
        }
    }

    private func send(_ state: inout State) {
        let now = ContinuousClock.now
        let interval = (now - state.lastSent).components
        var feedback = ScreenFeedback(sequence: state.sequence, ltrTokens: state.ltrTokens, refresh: state.refresh,
                                      receivedBytes: state.receivedBytes,
                                      intervalMs: Double(interval.seconds) * 1000 + Double(interval.attoseconds) / 1e15,
                                      decodeMs: state.decodeMs, lost: state.lost > 0 ? state.lost : nil)
        let tokens = state.ltrTokens
        state.ltrTokens = []
        state.receivedBytes = 0
        state.decodeMs = nil
        state.lastSent = now
        if let udp = state.udp {
            let repeated = state.recentTokens.joined().filter { !tokens.contains($0) }
            feedback.ltrTokens = repeated + tokens
            state.recentTokens.append(tokens)
            if state.recentTokens.count > Self.repeatedBatches { state.recentTokens.removeFirst() }
            if let message = AppMessage.feedback(feedback) {
                try? udp.sendAppMessage(message)
                return
            }
        }
        guard let params = try? JSONValue(encoding: feedback),
              let data = try? WireCoding.encoder.encode(ClientFrame(id: nil, method: Method.screenFeedback, params: params))
        else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}

/// The video side of the receiving loop: the decoder and the sequence tracker for the display streaming, and what the
/// hub hears about them.
nonisolated struct VideoReceiver {
    enum Outcome {
        case shown(VideoDecoder.Picture)
        /// Not decoded: it follows a gap or a failed frame (a refresh frame has been asked for).
        case skipped
        case failed(VideoDecoder.Failure)
    }

    private let feedback: ScreenFeedbackSender
    private let decoder = VideoDecoder()
    private var tracker = VideoSequenceTracker()
    private var display: UInt32?

    /// Whether the stream decodes on the hardware decoder.
    var usingHardware: Bool { decoder.usingHardware }

    init(feedback: ScreenFeedbackSender) {
        self.feedback = feedback
    }

    mutating func receive(_ frame: VideoFrameMessage) -> Outcome {
        if frame.displayID != display {
            // Another display is another stream.
            display = frame.displayID
            decoder.reset()
            tracker.reset()
            feedback.startOver()
        }
        guard tracker.shouldDecode(sequence: frame.sequence, flags: frame.flags) else {
            feedback.needRefresh()
            return .skipped
        }
        do {
            let picture = try decoder.decode(frame)
            tracker.decoded(sequence: frame.sequence, flags: frame.flags)
            feedback.decoded(sequence: frame.sequence, ltrToken: frame.ltrToken, decodeMs: picture.decodeMs,
                             needsRefresh: tracker.needsRefresh)
            return .shown(picture)
        } catch {
            tracker.failed()
            feedback.needRefresh()
            return .failed(error as? VideoDecoder.Failure ?? .noPicture)
        }
    }
}

/// Frames shown and bytes received over the last two seconds, and how the newest picture came (over UDP, with the
/// session's path and round trip, or over the WebSocket), read twice a second for the readout. The receiving loop
/// writes it and the keepalive loop reads it.
nonisolated final class StreamMeter: Sendable {
    struct Reading: Sendable, Equatable {
        var framesPerSecond: Double
        var megabitsPerSecond: Double
        var codec: String
        /// "Direct", "Relay" or "DERP" over UDP; "TCP" over the WebSocket.
        var path: String
        /// The UDP session's round trip, when it has one.
        var roundTripMs: Double?
        /// From the Mac's capture to decoded here, the median over the last two seconds (UDP only: it needs the
        /// session's clock offset).
        var delayMs: Double?
    }

    private struct State: Sendable {
        var shownAt: [ContinuousClock.Instant] = []
        var bytes: [(at: ContinuousClock.Instant, count: Int)] = []
        var codec = ""
        /// The UDP session's path and round trip, while it's up.
        var path: PathKind?
        var roundTrip: Int64?
        var overUDP = false
        var delays: [(at: ContinuousClock.Instant, ms: Double)] = []
        var lastReading: ContinuousClock.Instant?
    }

    private static let window = Duration.seconds(2)
    private let state = Mutex(State())

    func received(bytes count: Int, overUDP: Bool) {
        state.withLock { state in
            state.bytes.append((ContinuousClock.now, count))
            state.overUDP = overUDP
        }
    }

    func shown(codec: String) {
        state.withLock { state in
            state.shownAt.append(ContinuousClock.now)
            state.codec = codec
        }
    }

    /// A frame's delay from the Mac's capture to decoded here.
    func delay(_ milliseconds: Double) {
        // Below zero or over 10 s is a clock estimate still settling, not a delay.
        guard milliseconds >= 0, milliseconds < 10_000 else { return }
        state.withLock { $0.delays.append((ContinuousClock.now, milliseconds)) }
    }

    /// The UDP session's path and round trip (nil: it ended).
    func transport(path: PathKind?, roundTrip: Int64?) {
        state.withLock { state in
            state.path = path
            state.roundTrip = path == nil ? nil : roundTrip ?? state.roundTrip
            if path == nil { state.overUDP = false }
        }
    }

    /// A reading, if half a second has passed since the last one.
    func reading() -> Reading? {
        state.withLock { state in
            let now = ContinuousClock.now
            if let last = state.lastReading, now - last < .milliseconds(500) { return nil }
            state.lastReading = now
            state.shownAt.removeAll { now - $0 > Self.window }
            state.bytes.removeAll { now - $0.at > Self.window }
            state.delays.removeAll { now - $0.at > Self.window }
            let delays = state.delays.map(\.ms).sorted()
            return Reading(framesPerSecond: Double(state.shownAt.count) / 2,
                           megabitsPerSecond: Double(state.bytes.reduce(0) { $0 + $1.count }) * 8 / 2 / 1_000_000,
                           codec: state.codec,
                           path: state.codec.isEmpty ? "" : state.overUDP ? Self.name(state.path ?? .unknown) : "TCP",
                           roundTripMs: state.overUDP ? state.roundTrip.map { Double($0) / 1000 } : nil,
                           delayMs: state.overUDP && !delays.isEmpty ? delays[delays.count / 2] : nil)
        }
    }

    /// The readout's name for a path; "UDP" until Tailscale says which.
    static func name(_ path: PathKind) -> String {
        switch path {
        case .direct: "Direct"
        case .peerRelay: "Relay"
        case .derp: "DERP"
        case .unknown: "UDP"
        }
    }
}
