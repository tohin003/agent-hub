import AVFoundation
import Foundation

/// The Mac's sound over UDP, decoded for `SoundOutput`. Each Opus frame from the session (10 ms, on the transport's
/// queue) is put back in order (`AudioPlayout`), then decoded on this class's own queue. A frame lost on the way is
/// rebuilt from the next frame's in-band FEC, or concealed, and keeps its place in time. Each frame goes to the output
/// with its capture time; the output's buffer starts from the path's floor (20, 40 or 90 ms for direct, peer relay or
/// DERP, from its profile) and follows the measured jitter. Sound always goes ahead of pictures on the hub, and
/// nothing here waits for the main thread.
nonisolated final class OpusPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agenthub.sound.opus", qos: .userInteractive)
    private let output: SoundOutput
    // Used on `queue` only:
    private let decoder: OpusAudioDecoder
    private var playout = AudioPlayout()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    /// `output` plays 48 kHz stereo float, as Opus decodes.
    init(output: SoundOutput) throws {
        self.output = output
        decoder = try OpusAudioDecoder(channels: Int(output.format.channelCount))
    }

    /// The output's least buffer for a path: the profile's sound buffer less 10 ms.
    static func floorMs(for path: PathKind) -> Double {
        PlayoutController.Settings.forPath(bufferMs: PathProfile.profile(for: path).audioBufferMs).floorMs
    }

    /// From the session (any thread): sound frames, the Mac's clock, and the path's profile when it changes.
    func handle(_ event: ReceiverEvent) {
        switch event {
        case .audio(let frames):
            queue.async { self.add(frames) }
        case .clock(let offset):
            MacClock.shared.transport(offset: offset)
        case .report(let report):
            output.setFloor(ms: Self.floorMs(for: report.path))
        case .connected(_, let path):
            output.setFloor(ms: Self.floorMs(for: path))
        default:
            break
        }
    }

    /// The engine restarted (headphones, a call): frames start again from the next to arrive.
    func rebuffer() {
        queue.async { self.playout.reset() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func add(_ frames: [ReceivedAudioFrame]) {
        guard !stopped else { return }
        play(playout.add(frames, now: TransportClock.now()))
        armTimer()
    }

    /// A missing frame has been waited for long enough.
    private func expire() {
        guard !stopped else { return }
        play(playout.expire(now: TransportClock.now()))
        armTimer()
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard let deadline = playout.nextDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(0, deadline - TransportClock.now())
        timer.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.resume()
        self.timer = timer
    }

    private func play(_ steps: [AudioPlayout.Step]) {
        for step in steps {
            var samples: [Float]
            var timestamp: UInt64?
            do {
                switch step {
                case .decode(let packet, let time):
                    samples = try decoder.decode(packet)
                    timestamp = time
                case .recover(let next, let time):
                    samples = try decoder.recover(lostBefore: next)
                    timestamp = time
                case .conceal(let time):
                    samples = try decoder.conceal()
                    timestamp = time
                }
            } catch {
                guard let concealed = try? decoder.conceal() else { continue }
                samples = concealed
                timestamp = nil
            }
            if let pcm = pcm(samples) {
                output.enqueue(pcm, captureTime: timestamp.flatMap { Int64(exactly: $0) })
            }
        }
    }

    /// Interleaved samples as the player's (non-interleaved) buffer.
    private func pcm(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let format = output.format
        let channels = Int(format.channelCount)
        let frames = samples.count / max(channels, 1)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = pcm.floatChannelData else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            let out = data[channel]
            for frame in 0..<frames { out[frame] = samples[frame * channels + channel] }
        }
        return pcm
    }
}
