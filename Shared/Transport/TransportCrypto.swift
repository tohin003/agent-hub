import CryptoKit
import Foundation

// Every transport packet is sealed with ChaCha20-Poly1305 under a key the hub makes for the session and hands to the
// phone over the paired, authenticated WebSocket (itself inside WireGuard). A packet sealed under any other key, cut,
// changed, or sent a second time is refused.

/// A session's keys: one per direction, derived from the 32-byte session key, so the two sides' packet numbers (which
/// both start at 1) never share a nonce under one key.
nonisolated public struct TransportKeys: Sendable {
    public let sessionID: UInt32
    let hubToPhone: SymmetricKey
    let phoneToHub: SymmetricKey

    /// Nil for a zero session id or a key that isn't 32 bytes.
    public init?(sessionID: UInt32, sessionKey: Data) {
        guard sessionID != 0, sessionKey.count == 32 else { return nil }
        let master = SymmetricKey(data: sessionKey)
        let salt = Data("agenthub.transport.v1".utf8)
        self.sessionID = sessionID
        hubToPhone = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("hub to phone".utf8),
                                            outputByteCount: 32)
        phoneToHub = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("phone to hub".utf8),
                                            outputByteCount: 32)
    }

    /// A new session's id and key, from the system's cryptographic random number generator.
    public static func generate() -> (sessionID: UInt32, sessionKey: Data) {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return (UInt32.random(in: 1...UInt32.max), key)
    }

    func key(for direction: TransportDirection) -> SymmetricKey {
        direction == .hubToPhone ? hubToPhone : phoneToHub
    }
}

nonisolated public enum TransportDirection: UInt8, Sendable {
    case hubToPhone = 1
    case phoneToHub = 2
}

nonisolated public enum TransportError: Error, Sendable, Equatable, LocalizedError {
    /// The message doesn't fit one datagram.
    case tooLarge
    /// CryptoKit refused to seal (it doesn't for valid keys and nonces).
    case sealFailed
    /// The hub didn't answer the hello in time: use the WebSocket instead.
    case noAnswer
    /// Nothing arrived for a while on a stream that should be sending every 20 ms.
    case silent
    /// The UDP socket failed or couldn't be set up.
    case socket(String)
    /// Closed on purpose.
    case closed

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The message is too large for one packet."
        case .sealFailed: "The packet couldn't be sealed."
        case .noAnswer: "The Mac didn't answer over UDP."
        case .silent: "Nothing arrived from the Mac over UDP for a while."
        case .socket(let reason): "The UDP connection failed: \(reason)"
        case .closed: "The UDP connection was closed."
        }
    }
}

/// Why an incoming datagram was refused.
nonisolated public enum PacketRejection: Error, Sendable, Equatable, CaseIterable {
    /// Too short or too long to be a packet.
    case malformed
    case wrongVersion
    /// For a different session.
    case foreignSession
    /// The tag doesn't verify: changed on the way, or sealed under another key.
    case unauthenticated
    /// Its number was already accepted.
    case replayed
    /// Its number is too far behind the newest to tell whether it was.
    case tooOld
    /// Authentic, but the body isn't a message this version understands.
    case unreadable
}

/// A sealed datagram and the number it went out with.
nonisolated public struct SealedPacket: Sendable {
    public var number: UInt64
    public var datagram: Data
}

/// Numbers and seals one direction's packets.
nonisolated public struct PacketSealer: Sendable {
    public let sessionID: UInt32
    public let direction: TransportDirection
    private let key: SymmetricKey
    /// Packet numbers start at 1 and never repeat under one key.
    public private(set) var nextNumber: UInt64 = 1

    public init(keys: TransportKeys, direction: TransportDirection) {
        sessionID = keys.sessionID
        self.direction = direction
        key = keys.key(for: direction)
    }

    public mutating func seal(_ message: TransportMessage, sendTime: UInt32) throws -> SealedPacket {
        let payloadSize = message.payloadSize
        guard payloadSize <= TransportWire.maxPayloadSize else { throw TransportError.tooLarge }
        let number = nextNumber
        nextNumber += 1
        var header = Data(capacity: TransportWire.clearHeaderSize)
        header.append(TransportWire.version)
        WireBytes.append(sessionID, to: &header)
        WireBytes.append(number, to: &header)
        var body = Data(capacity: TransportWire.bodyHeaderSize + payloadSize)
        body.append(message.kind.rawValue)
        WireBytes.append(sendTime, to: &body)
        message.encodePayload(into: &body)
        do {
            let box = try ChaChaPoly.seal(body, using: key, nonce: try Self.nonce(direction, number),
                                          authenticating: header)
            var datagram = header
            datagram.append(box.ciphertext)
            datagram.append(box.tag)
            return SealedPacket(number: number, datagram: datagram)
        } catch {
            throw TransportError.sealFailed
        }
    }

    /// The direction, then the packet number: unique per key for the session's life.
    static func nonce(_ direction: TransportDirection, _ number: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data([direction.rawValue, 0, 0, 0])
        WireBytes.append(number, to: &bytes)
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// Opens one direction's packets: checks the session, the tag and the replay window, then reads the message.
nonisolated public struct PacketOpener: Sendable {
    public let sessionID: UInt32
    public let direction: TransportDirection
    private let key: SymmetricKey
    private var window = ReplayWindow()

    public init(keys: TransportKeys, direction: TransportDirection) {
        sessionID = keys.sessionID
        self.direction = direction
        key = keys.key(for: direction)
    }

    /// The newest packet number accepted so far.
    public var highestNumber: UInt64 { window.highest }

    public mutating func open(_ datagram: Data) -> Result<TransportPacket, PacketRejection> {
        let bytes = [UInt8](datagram)
        guard bytes.count >= TransportWire.overhead, bytes.count <= TransportWire.maxDatagramSize else {
            return .failure(.malformed)
        }
        guard bytes[0] == TransportWire.version else { return .failure(.wrongVersion) }
        guard WireBytes.u32(bytes, 1) == sessionID else { return .failure(.foreignSession) }
        let number = WireBytes.u64(bytes, 5)
        guard number != 0 else { return .failure(.malformed) }
        // A cheap first check; the window only moves once the tag has verified, so forged numbers can't move it.
        switch window.check(number) {
        case .duplicate: return .failure(.replayed)
        case .tooOld: return .failure(.tooOld)
        case .fresh: break
        }
        let tagStart = bytes.count - TransportWire.tagSize
        let header = bytes[0..<TransportWire.clearHeaderSize]
        guard let nonce = try? PacketSealer.nonce(direction, number),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: bytes[TransportWire.clearHeaderSize..<tagStart],
                                                  tag: bytes[tagStart...]),
              let body = try? ChaChaPoly.open(box, using: key, authenticating: header) else {
            return .failure(.unauthenticated)
        }
        window.accept(number)
        var reader = ByteReader([UInt8](body))
        guard let kindValue = reader.u8(), let sendTime = reader.u32(), let kind = TransportKind(rawValue: kindValue),
              let message = TransportMessage.decode(kind, &reader), reader.remaining == 0 else {
            return .failure(.unreadable)
        }
        return .success(TransportPacket(number: number, sendTime: sendTime, message: message))
    }
}

/// Which packet numbers were already accepted, for the last 4,096 (several seconds of packets at the highest rates):
/// a bitmap that slides with the newest number, as IPsec and WireGuard keep theirs.
nonisolated public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 4096

    public enum Verdict: Sendable, Equatable {
        case fresh, duplicate, tooOld
    }

    public private(set) var highest: UInt64 = 0
    private var words = [UInt64](repeating: 0, count: Int(size / 64))

    public init() {}

    public func check(_ number: UInt64) -> Verdict {
        if number > highest { return .fresh }
        if highest - number >= Self.size { return .tooOld }
        return isMarked(number) ? .duplicate : .fresh
    }

    /// Marks a number that `check` called fresh and whose packet verified.
    public mutating func accept(_ number: UInt64) {
        if number > highest {
            if number - highest >= Self.size {
                for index in words.indices { words[index] = 0 }
            } else {
                var next = highest + 1
                while next < number {
                    clear(next)
                    next += 1
                }
            }
            highest = number
        }
        mark(number)
    }

    private func isMarked(_ number: UInt64) -> Bool {
        let bit = number % Self.size
        return words[Int(bit / 64)] & (1 << (bit % 64)) != 0
    }

    private mutating func mark(_ number: UInt64) {
        let bit = number % Self.size
        words[Int(bit / 64)] |= 1 << (bit % 64)
    }

    private mutating func clear(_ number: UInt64) {
        let bit = number % Self.size
        words[Int(bit / 64)] &= ~(1 << (bit % 64))
    }
}
