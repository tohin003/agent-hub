import Foundation
import Network
import Synchronization

/// The kind of network this iPhone is on, for the UDP sessions' hellos: on cellular the hub adds error correction even
/// over a direct path. Tailscale's own tunnel is an interface of its own, so the first physical interface the system
/// would use decides. The sessions' sockets notice a changed path themselves; this only says what kind it is.
nonisolated final class PhoneNetworkMonitor: Sendable {
    static let shared = PhoneNetworkMonitor()

    private struct State: Sendable {
        var network: PhoneNetwork = .other
        var observers: [UUID: @Sendable (PhoneNetwork) -> Void] = [:]
    }

    private let monitor = NWPathMonitor()
    private let state = Mutex(State())

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(Self.kind(of: path)) }
        monitor.start(queue: DispatchQueue(label: "agenthub.network", qos: .utility))
    }

    var current: PhoneNetwork { state.withLock { $0.network } }

    /// Calls `handler` (on the monitor's queue) whenever the kind of network changes.
    func observe(_ handler: @escaping @Sendable (PhoneNetwork) -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.observers[id] = handler }
        return id
    }

    func stopObserving(_ id: UUID) {
        _ = state.withLock { $0.observers.removeValue(forKey: id) }
    }

    private func update(_ network: PhoneNetwork) {
        let observers = state.withLock { state -> [@Sendable (PhoneNetwork) -> Void] in
            guard state.network != network else { return [] }
            state.network = network
            return Array(state.observers.values)
        }
        for observer in observers { observer(network) }
    }

    static func kind(of path: NWPath) -> PhoneNetwork {
        let physical = path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }
        switch physical?.type {
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .wiredEthernet: return .wired
        default: return .other
        }
    }
}
