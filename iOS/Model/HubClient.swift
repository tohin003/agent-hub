import Foundation
import Observation

/// The control connection to the Mac hub: requests with replies, and events the hub pushes. It tries each of the
/// Mac's addresses (MagicDNS name, then the tailnet IP) and remembers which one answered.
@Observable
final class HubClient {
    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var latency: Duration?
    @ObservationIgnored var onEvent: ((String, JSONValue) -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?

    @ObservationIgnored private var session = URLSession(configuration: .default)
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var generation = 0

    var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    /// Connects and says hello. Returns the hub's greeting.
    func connect(_ settings: HubSettings, device: String) async throws -> HelloResult {
        disconnect()
        generation += 1
        let attempt = generation
        state = .connecting
        var lastError: Error = WireError.failed("No address for the Mac is set.")
        for host in settings.hosts {
            guard attempt == generation else { throw CancellationError() }
            do {
                let hello = try await open(host: host, settings: settings, device: device, attempt: attempt)
                state = .connected(host: host)
                Task { await measureLatency(attempt: attempt) }
                return hello
            } catch {
                lastError = error
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
            }
        }
        state = .failed(Self.describe(lastError))
        throw lastError
    }

    private func open(host: String, settings: HubSettings, device: String, attempt: Int) async throws -> HelloResult {
        guard let url = URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(settings.port)/") else {
            throw WireError.badRequest("Bad address \(host)")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 6)
        urlRequest.setValue("Bearer \(settings.token)", forHTTPHeaderField: WireProtocol.authorizationHeader)
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 48 * 1024 * 1024
        self.task = task
        task.resume()
        Task { await receiveLoop(task, attempt: attempt) }
        let hello: HelloResult = try await request(Method.hello, HelloParams(channel: "control", device: device),
                                                   timeout: .seconds(6))
        return hello
    }

    func disconnect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAll(WireError.failed("Disconnected."))
        if state != .idle { state = .idle }
    }

    // MARK: Requests

    func request<P: Encodable, R: Decodable>(_ method: String, _ params: P, timeout: Duration = .seconds(25)) async throws -> R {
        let value = try await raw(method, params: try JSONValue(encoding: params), timeout: timeout)
        do {
            return try value.decode(R.self)
        } catch {
            throw WireError.failed("The Mac's reply to \(method) wasn't understood: \(error.localizedDescription)")
        }
    }

    func send<P: Encodable>(_ method: String, _ params: P) async throws {
        let _: OKResult = try await request(method, params)
    }

    func raw(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        guard let task, isConnected || method == Method.hello else { throw WireError.failed("Not connected to your Mac.") }
        let id = nextId
        nextId += 1
        let frame = ClientFrame(id: id, method: method, params: params)
        let data = try WireCoding.encoder.encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.resolve(id, .failure(error)) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve(id, .failure(WireError.failed("Your Mac didn't answer in time.")))
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask, attempt: Int) async {
        while attempt == generation {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let frame = try? WireCoding.decoder.decode(ServerFrame.self, from: data) else { continue }
                if let id = frame.id {
                    if let error = frame.error {
                        resolve(id, .failure(error))
                    } else {
                        resolve(id, .success(frame.result ?? .null))
                    }
                } else if let event = frame.event {
                    onEvent?(event, frame.data ?? .null)
                }
            } catch {
                guard attempt == generation else { return }
                failAll(error)
                if case .connected = state {
                    state = .failed(Self.describe(error))
                    onDisconnect?()
                }
                return
            }
        }
    }

    private func measureLatency(attempt: Int) async {
        while attempt == generation, isConnected, let task {
            let start = ContinuousClock.now
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                task.sendPing { _ in continuation.resume() }
            }
            if attempt == generation { latency = ContinuousClock.now - start }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    static func describe(_ error: Error) -> String {
        if let wire = error as? WireError { return wire.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorBadServerResponse: return "Your Mac refused the pairing token."
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return "Can't reach your Mac. Check that Tailscale is on here and on the Mac, and that the Mac is awake."
            case NSURLErrorNotConnectedToInternet: return "This iPhone is offline."
            default: break
            }
        }
        return error.localizedDescription
    }
}
