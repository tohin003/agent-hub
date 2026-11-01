import Foundation
import Observation
import UIKit

/// The live screen: a second connection that carries only JPEG frames, so taps and typing on the control
/// connection never wait behind a frame.
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

        var params: (maxPixels: Int, fps: Int, quality: Double) {
            switch self {
            case .low: (1100, 5, 0.45)
            case .balanced: (1700, 8, 0.6)
            case .sharp: (2600, 12, 0.72)
            }
        }
    }

    private(set) var frames: [UInt32: UIImage] = [:]
    private(set) var frameSizes: [UInt32: CGSize] = [:]
    private(set) var streaming = false
    private(set) var error: String?
    private(set) var framesPerSecond = 0.0
    var quality: Quality = .balanced

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var frameTimes: [Date] = []
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    func start(settings: HubSettings, host: String, display: UInt32?) async {
        stop()
        generation += 1
        let attempt = generation
        error = nil
        guard let url = URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(settings.port)/") else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: WireProtocol.authorizationHeader)
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        Task { await receive(task, attempt: attempt) }
        do {
            try await call(Method.hello, HelloParams(channel: "screen", device: UIDevice.current.name))
            try await switchDisplay(display)
            streaming = true
        } catch {
            if attempt == generation { self.error = HubClient.describe(error) }
        }
    }

    func switchDisplay(_ display: UInt32?) async throws {
        let p = quality.params
        try await call(Method.screenStart, ScreenStartParams(displayId: display, maxPixels: p.maxPixels, fps: p.fps, quality: p.quality))
    }

    func stop() {
        generation += 1
        if let task { task.cancel(with: .goingAway, reason: nil) }
        task = nil
        streaming = false
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }

    private func call<P: Encodable>(_ method: String, _ params: P) async throws {
        guard let task else { throw WireError.failed("Not connected.") }
        let id = nextId
        nextId += 1
        let data = try WireCoding.encoder.encode(ClientFrame(id: id, method: method, params: try JSONValue(encoding: params)))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[id] = continuation
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                if let waiting = self?.pending.removeValue(forKey: id) {
                    waiting.resume(throwing: WireError.failed("The Mac didn't start the screen in time."))
                }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, attempt: Int) async {
        while attempt == generation {
            do {
                switch try await task.receive() {
                case .data(let data):
                    guard let frame = ScreenFrameHeader.parse(data) else { continue }
                    let image = await Self.decode(frame.jpeg)
                    guard attempt == generation, let image else { continue }
                    frames[frame.displayID] = image
                    frameSizes[frame.displayID] = CGSize(width: frame.width, height: frame.height)
                    countFrame()
                case .string(let text):
                    guard let reply = try? WireCoding.decoder.decode(ServerFrame.self, from: Data(text.utf8)),
                          let id = reply.id, let continuation = pending.removeValue(forKey: id) else { continue }
                    if let error = reply.error {
                        continuation.resume(throwing: error)
                        self.error = error.message
                    } else {
                        continuation.resume()
                    }
                @unknown default:
                    continue
                }
            } catch {
                if attempt == generation {
                    streaming = false
                    self.error = HubClient.describe(error)
                }
                return
            }
        }
    }

    private func countFrame() {
        let now = Date.now
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        framesPerSecond = Double(frameTimes.count) / 2
    }

    /// Decodes a JPEG away from the main thread.
    @concurrent
    nonisolated static func decode(_ data: Data) async -> UIImage? {
        UIImage(data: data)?.preparingForDisplay()
    }
}
