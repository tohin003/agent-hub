import AVFoundation
import Foundation

/// Plays the Mac's sound on the phone with the step-2 buffer: decoded sound goes in with its capture time (Opus over
/// UDP, AAC-ELD or AAC-LC over the WebSocket). `PlayoutController` decides how much to hold and how fast to play.
/// The engine is a player through a varispeed unit, which plays 1–2% faster or slower to keep the buffer where it
/// should be instead of dropping sound or adding silence.
///
/// It also keeps the sync rule's sound side (`MediaSync`):
/// - it reports how long after capture the sound reaches the ear, the output's latency included (`outputLatency` plus
///   the IO buffer: a few ms on the speaker, 125–220 ms on AirPods);
/// - it holds enough that the sound is never ahead of the picture.
///
/// Everything runs on its own queue; decoded sound may come from any thread.
nonisolated final class SoundOutput: @unchecked Sendable {
    let format: AVAudioFormat
    /// For route-change notifications.
    var audioEngine: AVAudioEngine { engine }

    private let queue = DispatchQueue(label: "agenthub.sound.output", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    /// Frames handed to the player and not yet played; the player's own thread counts them down.
    private let queued = FrameCount()
    // Used on `queue` only:
    private var controller: PlayoutController
    /// The path's least buffer; the IO buffer can raise it (`effectiveFloor`).
    private var pathFloorMs: Double
    private var filling: [AVAudioPCMBuffer] = []
    private var timer: DispatchSourceTimer?
    private var appliedRate: Float = 1
    /// The level the rate steers by: the sound waiting as each frame arrives, smoothed.
    private var level: Double?
    /// Capture → arrival, ms, over the jitter window: its mean, for the sync floor.
    private var arrivals: [(at: Int64, ms: Double)] = []
    private var syncChecked: Int64?
    private var delay: Double?
    private var latency = 0.0
    private var ioBuffer = 0.0
    private var latencyRead: Int64?
    /// When the player was first seen with nothing left to play, while it stays so.
    private var dryAt: Int64?
    private var running = false

    /// `format`: the decoders' PCM (48 kHz stereo float); `floorMs`: the least sound to hold (the path's).
    init(format: AVAudioFormat, floorMs: Double) {
        self.format = format
        pathFloorMs = floorMs
        controller = PlayoutController(settings: .init(floorMs: floorMs))
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
    }

    /// Starts the engine (the audio session must be active).
    func start() throws {
        engine.prepare()
        try engine.start()
        player.play()
        queue.sync {
            running = true
            startTimer()
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            filling = []
        }
        player.stop()
        engine.stop()
        queued.reset()
        MediaSync.shared.soundStopped()
    }

    /// The route changed or a call ended: the engine starts again and the buffer fills again.
    func restart() {
        player.stop()
        queue.sync {
            queued.reset()
            filling = []
            level = nil
            delay = nil
            dryAt = nil
            controller.refill()
            // The new route's latency, and a buffer sized by it rather than by the old one's delay.
            latencyRead = nil
            syncChecked = nil
            MediaSync.shared.soundStopped()
            steer(waiting: nil, now: TransportClock.now())
        }
        if !engine.isRunning {
            engine.connect(player, to: varispeed, format: format)
            engine.connect(varispeed, to: engine.mainMixerNode, format: format)
            try? engine.start()
        }
        player.play()
    }

    /// The path changed (UDP's profile): a new least buffer.
    func setFloor(ms: Double) {
        queue.async {
            self.pathFloorMs = ms
            self.controller.settings.floorMs = self.effectiveFloor
        }
    }

    /// Decoded sound whose first sample was captured at `captureTime` (µs on the Mac's host clock); nil when that isn't
    /// known (an older hub, a concealed frame with nothing before it).
    func enqueue(_ pcm: AVAudioPCMBuffer, captureTime: Int64?) {
        // Handed over: the caller never touches it again.
        nonisolated(unsafe) let buffer = pcm
        queue.async { self.add(buffer, captureTime: captureTime) }
    }

    // MARK: Inside (on `queue`)

    private var queuedMs: Double { Double(queued.value) / format.sampleRate * 1000 }

    private func milliseconds(_ buffers: [AVAudioPCMBuffer]) -> Double {
        Double(buffers.reduce(0) { $0 + Int($1.frameLength) }) / format.sampleRate * 1000
    }

    /// The least buffer: the path's, and never less than one and a half IO buffers, which the output takes whole.
    private var effectiveFloor: Double { max(pathFloorMs, ioBuffer * 1.5) }

    private func add(_ pcm: AVAudioPCMBuffer, captureTime: Int64?) {
        guard running, pcm.frameLength > 0 else { return }
        let now = TransportClock.now()
        readLatency(now: now)
        let frameMs = Double(pcm.frameLength) / format.sampleRate * 1000
        let arrival = captureTime.flatMap { MacClock.shared.milliseconds(since: $0, now: now) }
        updateSyncFloor(arrival: arrival, now: now)
        let waiting = queuedMs + milliseconds(filling)
        guard controller.admit(transit: captureTime.map { now &- $0 }, queuedMs: waiting, frameMs: frameMs, now: now) else {
            return
        }
        if let arrival { arrivals.append((now, arrival)) }
        if controller.playing {
            if let arrival { measureDelay(arrival: arrival, waiting: waiting, now: now) }
            steer(waiting: waiting, now: now)
            schedule(pcm)
        } else {
            filling.append(pcm)
            // The level is what waits as a frame arrives: playing starts once that, before this frame, is the target.
            if controller.shouldStart(queuedMs: queuedMs + milliseconds(filling) - frameMs) {
                // Starting with more than the target in hand (a buffer of several packets overshoots it): the
                // oldest goes.
                var excess = controller.startExcess(queuedMs: queuedMs + milliseconds(filling) - frameMs)
                while excess > 0, filling.count > 1, let first = filling.first {
                    let firstMs = Double(first.frameLength) / format.sampleRate * 1000
                    guard firstMs <= excess else { break }
                    excess -= firstMs
                    filling.removeFirst()
                }
                if let arrival {
                    measureDelay(arrival: arrival, waiting: queuedMs + milliseconds(filling) - frameMs, now: now)
                }
                filling.forEach(schedule)
                filling = []
            }
            steer(waiting: nil, now: now)
        }
    }

    /// This frame reaches the ear after everything queued before it, and the output's latency.
    private func measureDelay(arrival: Double, waiting: Double, now: Int64) {
        let measured = arrival + max(waiting, 0) + latency
        let smoothed = delay.map { $0 + (measured - $0) * 0.1 } ?? measured
        delay = smoothed
        MediaSync.shared.soundPlaying(delayMs: smoothed, now: now)
    }

    /// Enough held that the sound isn't ahead of the picture (`SyncRule.bufferFloor`). Checked every 100 ms, and at
    /// once for the first frame (`arrival`, before any other has), so the first fill already holds enough.
    private func updateSyncFloor(arrival: Double?, now: Int64) {
        guard syncChecked.map({ now - $0 >= 100_000 }) ?? true else { return }
        syncChecked = now
        arrivals.removeAll { now - $0.at > controller.settings.jitterWindow }
        let meanArrival = arrivals.isEmpty ? arrival : arrivals.reduce(0) { $0 + $1.ms } / Double(arrivals.count)
        guard let floor = MediaSync.shared.soundFloor(now: now), let meanArrival else {
            controller.syncFloorMs = 0
            return
        }
        controller.syncFloorMs = SyncRule.bufferFloor(soundFloor: floor, meanArrivalMs: meanArrival, outputLatencyMs: latency)
    }

    private func schedule(_ pcm: AVAudioPCMBuffer) {
        let frames = Int(pcm.frameLength)
        let queued = queued
        let epoch = queued.add(frames)
        player.scheduleBuffer(pcm, completionCallbackType: .dataConsumed) { _ in queued.remove(frames, epoch: epoch) }
    }

    /// The rate from the level: `waiting` is the sound waiting as a frame arrives (nil from the timer, which only
    /// lets the rate keep moving toward what the level asks).
    private func steer(waiting: Double?, now: Int64) {
        if let waiting { level = level.map { $0 + (waiting - $0) * 0.15 } ?? waiting }
        let rate = Float(controller.update(queuedMs: level ?? controller.targetMs, now: now))
        guard abs(rate - appliedRate) >= 0.0005 else { return }
        appliedRate = rate
        varispeed.rate = rate
    }

    /// Every 20 ms: a buffer that stays dry while playing is a stall; otherwise the rate follows the level.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = TransportClock.now()
            self.checkDry(now: now)
            self.steer(waiting: nil, now: now)
        }
        timer.resume()
        self.timer = timer
    }

    /// Nothing left to play is a stall only if it lasts: a frame arriving just after the last one was taken is still
    /// in time. Dry at two ticks running, the buffer fills to its level again before playing on.
    private func checkDry(now: Int64) {
        guard controller.playing, queued.value == 0 else {
            dryAt = nil
            return
        }
        guard let dryAt else {
            self.dryAt = now
            return
        }
        guard now - dryAt >= 15_000 else { return }
        controller.ranDry()
        level = nil
        self.dryAt = nil
    }

    /// The output's latency (the route's plus the IO buffer), ms, read again once a second: AirPods add 125–220 ms.
    private func readLatency(now: Int64) {
        guard latencyRead.map({ now - $0 > 1_000_000 }) ?? true else { return }
        latencyRead = now
        let session = AVAudioSession.sharedInstance()
        ioBuffer = session.ioBufferDuration * 1000
        latency = session.outputLatency * 1000 + ioBuffer
        controller.settings.floorMs = effectiveFloor
    }
}
