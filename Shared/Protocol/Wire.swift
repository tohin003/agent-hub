import Foundation

/// Version of the phone-to-Mac protocol. The hub refuses clients with a different major version.
nonisolated public enum WireProtocol {
    public static let version = 1
    public static let defaultPort = 7860
    /// Header the phone sends on the WebSocket upgrade: `Authorization: Bearer <token>`.
    public static let authorizationHeader = "Authorization"
}

/// One frame from the phone to the hub: a request with an id, or a fire-and-forget command without one.
nonisolated public struct ClientFrame: Codable, Sendable {
    public var id: Int?
    public var method: String
    public var params: JSONValue?

    public init(id: Int?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// One frame from the hub to the phone: a response (`id` with `result` or `error`) or an event (`event` with `data`).
nonisolated public struct ServerFrame: Codable, Sendable {
    public var id: Int?
    public var result: JSONValue?
    public var error: WireError?
    public var event: String?
    public var data: JSONValue?

    public init(id: Int? = nil, result: JSONValue? = nil, error: WireError? = nil, event: String? = nil, data: JSONValue? = nil) {
        self.id = id
        self.result = result
        self.error = error
        self.event = event
        self.data = data
    }
}

nonisolated public struct WireError: Codable, Sendable, Error, Hashable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func badRequest(_ message: String) -> WireError { WireError(code: "bad_request", message: message) }
    public static func notFound(_ message: String) -> WireError { WireError(code: "not_found", message: message) }
    public static func failed(_ message: String) -> WireError { WireError(code: "failed", message: message) }
    public static let unauthorized = WireError(code: "unauthorized", message: "The pairing token doesn't match this Mac.")
}

/// Method names, so both sides spell them the same way.
nonisolated public enum Method {
    public static let hello = "hello"
    public static let sessionsList = "sessions.list"
    public static let sessionCreate = "session.create"
    public static let sessionKill = "session.kill"
    public static let sessionRemove = "session.remove"
    public static let sessionRename = "session.rename"
    public static let sessionSend = "session.send"
    public static let sessionKeys = "session.keys"
    public static let sessionAnswer = "session.answer"
    public static let sessionSubscribe = "session.subscribe"
    public static let sessionUnsubscribe = "session.unsubscribe"
    public static let sessionPage = "session.page"
    public static let sessionTool = "session.tool"
    public static let sessionSubagent = "session.subagent"
    public static let sessionTaskOutput = "session.taskOutput"
    public static let sessionWindow = "session.window"
    public static let sessionScrollback = "session.scrollback"
    public static let sessionUpload = "session.upload"
    public static let sessionModel = "session.model"
    public static let sessionAnswerText = "session.answerText"
    public static let accountUsage = "account.usage"
    public static let accountModels = "account.models"
    public static let accountCommands = "account.commands"
    public static let historyList = "history.list"
    public static let historyTimeline = "history.timeline"
    public static let fsList = "fs.list"
    public static let fsMkdir = "fs.mkdir"
    public static let fsRoots = "fs.roots"
    public static let screenDisplays = "screen.displays"
    public static let screenInput = "screen.input"
    public static let screenSpace = "screen.space"
    public static let screenStart = "screen.start"
    public static let screenStop = "screen.stop"
    public static let screenSharing = "screen.sharing"
    public static let macStatus = "mac.status"
    public static let macRenew = "mac.renew"
    public static let macRenewAuto = "mac.renewAuto"
    public static let macPermission = "mac.permission"
    public static let ping = "ping"
}

/// Event names pushed by the hub.
nonisolated public enum Event {
    public static let sessions = "sessions"
    public static let sessionUpdated = "session.updated"
    public static let sessionRemoved = "session.removed"
    public static let timeline = "timeline"
    public static let tasks = "tasks"
    public static let terminal = "terminal"
    public static let hub = "hub"
    public static let accounts = "accounts"
    public static let toast = "toast"
}

/// Binary screen frames: a 13-byte header, then JPEG bytes.
/// byte 0: kind (1 = JPEG frame); bytes 1-4: display id (big-endian UInt32); 5-6 width; 7-8 height;
/// bytes 9-12: frame sequence number (big-endian UInt32).
nonisolated public enum ScreenFrameHeader {
    public static let size = 13
    public static let jpegKind: UInt8 = 1

    public static func make(displayID: UInt32, width: Int, height: Int, sequence: UInt32) -> Data {
        var data = Data(capacity: size)
        data.append(jpegKind)
        data.append(contentsOf: withUnsafeBytes(of: displayID.bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(clamping: width).bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(clamping: height).bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init))
        return data
    }

    public struct Parsed: Sendable {
        public var displayID: UInt32
        public var width: Int
        public var height: Int
        public var sequence: UInt32
        public var jpeg: Data
    }

    public static func parse(_ data: Data) -> Parsed? {
        guard data.count > size, data[data.startIndex] == jpegKind else { return nil }
        let bytes = [UInt8](data.prefix(size))
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        return Parsed(displayID: u32(1), width: u16(5), height: u16(7), sequence: u32(9), jpeg: data.dropFirst(size))
    }
}
