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
    /// Takes over a session still waiting in a terminal tab for its turn to end, now (`SessionRef`).
    public static let sessionTakeOverNow = "session.takeOverNow"
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
    public static let screenPrivacy = "screen.privacy"
    /// On a sound connection: start sending the Mac's sound.
    public static let screenAudio = "screen.audio"
    /// On a screen connection, from the phone, no reply: what it decoded (`ScreenFeedback`). Sent with every decoded
    /// frame and at least every 20 ms, which also keeps the iPhone's Wi-Fi awake.
    public static let screenFeedback = "screen.feedback"
    /// On a screen connection, from the phone, no reply: the part of the display its view shows once a zoom or a pan
    /// settles (`ScreenViewportParams`), which the hub then captures at the display's own resolution.
    public static let screenViewport = "screen.viewport"
    public static let macStatus = "mac.status"
    /// The Mac's volume, mute and brightness: sets what's given, answers with the levels as they are.
    public static let macLevels = "mac.levels"
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
    /// To a phone watching video, on its screen connection: the frame rate the stream runs at now (`ScreenStreamInfo`).
    public static let screenStream = "screen.stream"
    /// The Mac's displays and Spaces (`[DisplayInfo]`), to the phones watching, when a display's current Space changes,
    /// whoever changed it.
    public static let screenSpaces = "screen.spaces"
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

/// Binary sound messages, on a sound connection: a 7-byte header, then the AAC packets.
/// byte 0: kind (2 = sound); bytes 1-4: message sequence number (big-endian UInt32); bytes 5-6: packet count
/// (big-endian UInt16); then each packet as its length (big-endian UInt16) and its bytes.
nonisolated public enum AudioPacketMessage {
    public static let kind: UInt8 = 2
    public static let headerSize = 7

    public static func make(sequence: UInt32, packets: [Data]) -> Data {
        let usable = packets.prefix(Int(UInt16.max)).filter { !$0.isEmpty && $0.count <= Int(UInt16.max) }
        var data = Data(capacity: headerSize + usable.reduce(0) { $0 + 2 + $1.count })
        data.append(kind)
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(usable.count).bigEndian, Array.init))
        for packet in usable {
            data.append(contentsOf: withUnsafeBytes(of: UInt16(packet.count).bigEndian, Array.init))
            data.append(packet)
        }
        return data
    }

    public struct Parsed: Sendable, Equatable {
        public var sequence: UInt32
        public var packets: [Data]
    }

    /// Nil for anything that isn't a whole sound message.
    public static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, bytes[0] == kind else { return nil }
        let sequence = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        let count = Int(bytes[5]) << 8 | Int(bytes[6])
        var packets: [Data] = []
        packets.reserveCapacity(count)
        var offset = headerSize
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            packets.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        guard offset == bytes.count else { return nil }
        return Parsed(sequence: sequence, packets: packets)
    }
}

// MARK: Live picture: video frames, keepalive ticks and the pointer (hub → phone, on the screen connection)

/// Big-endian reading and writing for the binary messages.
nonisolated enum WireBytes {
    static func append(_ value: UInt16, to data: inout Data) { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
    static func append(_ value: UInt32, to data: inout Data) { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
    static func append(_ value: UInt64, to data: inout Data) { data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
    static func append(_ value: Float, to data: inout Data) { append(value.bitPattern, to: &data) }
    static func append(_ value: Double, to data: inout Data) { append(value.bitPattern, to: &data) }

    static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
    static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 { UInt64(u32(bytes, at)) << 32 | UInt64(u32(bytes, at + 4)) }
    static func f32(_ bytes: [UInt8], _ at: Int) -> Float { Float(bitPattern: u32(bytes, at)) }
    static func f64(_ bytes: [UInt8], _ at: Int) -> Double { Double(bitPattern: u64(bytes, at)) }
}

/// Kind 0, one byte: "still here". The hub sends it to a screen connection when nothing else went out for 20 ms, so
/// the iPhone's Wi-Fi never dozes between frames (an idle iPhone answered in 4 to 117 ms). JPEG streams get it too.
nonisolated public enum StreamKeepalive {
    public static let kind: UInt8 = 0
    public static let message = Data([kind])
}

/// Kind 3: one HEVC or H.264 frame from the hardware encoder.
///
/// byte 0: kind (3); 1-4: display id; 5-6: width; 7-8: height; 9-12: sequence number (counts every encoded frame,
/// so a gap means frames were skipped); 13-20: capture time (Float64 seconds on the Mac's host clock, from
/// ScreenCaptureKit); 21: codec (1 HEVC, 2 H.264); 22: flags; 23-26: long-term reference token to acknowledge (0 when
/// none). If the region flag is set, 16 bytes follow: the part of the display the frame shows (`ScreenRegion`: x, y,
/// width, height as Float32 fractions of the display from its top-left). If the parameter-sets flag is set, the next
/// byte is their count, then each as a UInt16 length and its bytes (HEVC: VPS, SPS, PPS; H.264: SPS, PPS). Then the
/// frame: NAL units with 4-byte big-endian lengths, as VideoToolbox writes them. All numbers are big-endian.
///
/// Only phones that asked for a region (`screen.viewport`) ever get a frame with one: older phones read the region's
/// bytes as part of the frame.
///
/// The bitstream's own colour description (its VUI) says how to make RGB of it: BT.709 for 4:2:0, BT.601 for 4:4:4
/// (ScreenCaptureKit makes its 4:4:4 that way, whatever matrix is asked for), so decode with the stream's matrix. A
/// keyframe is always a place to start; numbers keep counting when the hub restarts its encoder for a newer phone.
nonisolated public struct VideoFrameMessage: Sendable, Equatable {
    public static let kind: UInt8 = 3
    public static let headerSize = 27

    public enum Codec: UInt8, Sendable {
        case hevc = 1
        case h264 = 2
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// An IDR frame: decodes on its own.
        public static let keyframe = Flags(rawValue: 1 << 0)
        /// Safe to start from after a gap: a keyframe, or a frame that refers only to an acknowledged long-term
        /// reference.
        public static let refresh = Flags(rawValue: 1 << 1)
        /// 4:4:4 chroma.
        public static let chroma444 = Flags(rawValue: 1 << 2)
        /// Set by `encoded()` when `parameterSets` isn't empty.
        public static let parameterSets = Flags(rawValue: 1 << 3)
        /// Set by `encoded()` when the frame shows part of the display (`region`).
        public static let region = Flags(rawValue: 1 << 4)
    }

    public var displayID: UInt32
    public var width: Int
    public var height: Int
    public var sequence: UInt32
    /// Seconds on the Mac's host clock when the frame was captured. A frame encoded again from an unchanged screen (a
    /// refresh, a new phone's keyframe) has the time it was encoded.
    public var captureTime: Double
    public var codec: Codec
    public var flags: Flags
    /// The encoder's RequireLTRAcknowledgementToken for this frame (0: none); the phone returns it once decoded.
    /// H.264 marks every frame; HEVC marks one only once the last one marked was acknowledged, and lets an
    /// unacknowledged one go about 12 frames later, so return tokens with the very next feedback.
    public var ltrToken: UInt32
    /// HEVC: VPS, SPS, PPS; H.264: SPS, PPS. Sent with keyframes and refresh frames, else empty.
    public var parameterSets: [Data]
    /// The part of the display the frame shows, when it isn't the whole display (a zoomed-in phone's, captured at the
    /// display's own resolution and stretched to the frame's size).
    public var region: ScreenRegion?
    /// NAL units with 4-byte big-endian lengths.
    public var data: Data

    public init(displayID: UInt32, width: Int, height: Int, sequence: UInt32, captureTime: Double, codec: Codec,
                flags: Flags, ltrToken: UInt32 = 0, parameterSets: [Data] = [], region: ScreenRegion? = nil, data: Data) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.sequence = sequence
        self.captureTime = captureTime
        self.codec = codec
        self.flags = flags.subtracting([.parameterSets, .region])
        self.ltrToken = ltrToken
        self.parameterSets = parameterSets
        self.region = region?.isWhole == true ? nil : region
        self.data = data
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + 17 + parameterSets.reduce(0) { $0 + 2 + $1.count } + data.count)
        out.append(Self.kind)
        WireBytes.append(displayID, to: &out)
        WireBytes.append(UInt16(clamping: width), to: &out)
        WireBytes.append(UInt16(clamping: height), to: &out)
        WireBytes.append(sequence, to: &out)
        WireBytes.append(captureTime, to: &out)
        out.append(codec.rawValue)
        var wireFlags = flags
        if !parameterSets.isEmpty { wireFlags.insert(.parameterSets) }
        if region != nil { wireFlags.insert(.region) }
        out.append(wireFlags.rawValue)
        WireBytes.append(ltrToken, to: &out)
        if let region {
            for value in [region.x, region.y, region.width, region.height] { WireBytes.append(Float(value), to: &out) }
        }
        if !parameterSets.isEmpty {
            out.append(UInt8(clamping: parameterSets.count))
            for set in parameterSets.prefix(255) {
                WireBytes.append(UInt16(clamping: set.count), to: &out)
                out.append(set.prefix(Int(UInt16.max)))
            }
        }
        out.append(data)
        return out
    }

    /// Nil for anything that isn't a whole video frame message.
    public static func parse(_ message: Data) -> VideoFrameMessage? {
        let bytes = [UInt8](message)
        guard bytes.count > headerSize, bytes[0] == kind, let codec = Codec(rawValue: bytes[21]) else { return nil }
        let flags = Flags(rawValue: bytes[22])
        var offset = headerSize
        var region: ScreenRegion?
        if flags.contains(.region) {
            guard offset + 16 <= bytes.count else { return nil }
            let values = (0..<4).map { Double(WireBytes.f32(bytes, offset + 4 * $0)) }
            region = ScreenRegion(x: values[0], y: values[1], width: values[2], height: values[3])
            offset += 16
        }
        var sets: [Data] = []
        if flags.contains(.parameterSets) {
            guard offset < bytes.count else { return nil }
            let count = Int(bytes[offset])
            offset += 1
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return nil }
                let length = Int(WireBytes.u16(bytes, offset))
                offset += 2
                guard offset + length <= bytes.count else { return nil }
                sets.append(Data(bytes[offset..<offset + length]))
                offset += length
            }
        }
        guard offset < bytes.count else { return nil }
        return VideoFrameMessage(displayID: WireBytes.u32(bytes, 1), width: Int(WireBytes.u16(bytes, 5)),
                                 height: Int(WireBytes.u16(bytes, 7)), sequence: WireBytes.u32(bytes, 9),
                                 captureTime: WireBytes.f64(bytes, 13), codec: codec, flags: flags,
                                 ltrToken: WireBytes.u32(bytes, 23), parameterSets: sets, region: region,
                                 data: Data(bytes[offset...]))
    }
}

/// Kind 4, 18 bytes: where the Mac's pointer is, for a phone that draws it itself.
/// byte 0: kind (4); 1-4: display id; 5-8: x and 9-12: y, as Float32 fractions of the display (top-left origin,
/// 0...1); 13: visible (0 or 1); 14-17: shape id (a `CursorShapeMessage` already sent).
nonisolated public struct CursorPositionMessage: Sendable, Equatable {
    public static let kind: UInt8 = 4
    public static let size = 18

    public var displayID: UInt32
    public var x: Double
    public var y: Double
    public var visible: Bool
    public var shapeID: UInt32

    public init(displayID: UInt32, x: Double, y: Double, visible: Bool, shapeID: UInt32) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.visible = visible
        self.shapeID = shapeID
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.size)
        out.append(Self.kind)
        WireBytes.append(displayID, to: &out)
        WireBytes.append(Float(x), to: &out)
        WireBytes.append(Float(y), to: &out)
        out.append(visible ? 1 : 0)
        WireBytes.append(shapeID, to: &out)
        return out
    }

    public static func parse(_ message: Data) -> CursorPositionMessage? {
        let bytes = [UInt8](message)
        guard bytes.count == size, bytes[0] == kind else { return nil }
        return CursorPositionMessage(displayID: WireBytes.u32(bytes, 1), x: Double(WireBytes.f32(bytes, 5)),
                                     y: Double(WireBytes.f32(bytes, 9)), visible: bytes[13] != 0,
                                     shapeID: WireBytes.u32(bytes, 14))
    }
}

/// Kind 5: a pointer shape, sent once per shape before positions refer to it.
/// byte 0: kind (5); 1-4: shape id; 5-8: width and 9-12: height in the Mac's points; 13-16: hot spot x and 17-20: y,
/// in points from the image's top-left (all Float32); then the image as PNG.
nonisolated public struct CursorShapeMessage: Sendable, Equatable {
    public static let kind: UInt8 = 5
    public static let headerSize = 21

    public var shapeID: UInt32
    public var width: Double
    public var height: Double
    public var hotSpotX: Double
    public var hotSpotY: Double
    public var png: Data

    public init(shapeID: UInt32, width: Double, height: Double, hotSpotX: Double, hotSpotY: Double, png: Data) {
        self.shapeID = shapeID
        self.width = width
        self.height = height
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.png = png
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + png.count)
        out.append(Self.kind)
        WireBytes.append(shapeID, to: &out)
        WireBytes.append(Float(width), to: &out)
        WireBytes.append(Float(height), to: &out)
        WireBytes.append(Float(hotSpotX), to: &out)
        WireBytes.append(Float(hotSpotY), to: &out)
        out.append(png)
        return out
    }

    public static func parse(_ message: Data) -> CursorShapeMessage? {
        let bytes = [UInt8](message)
        guard bytes.count > headerSize, bytes[0] == kind else { return nil }
        return CursorShapeMessage(shapeID: WireBytes.u32(bytes, 1), width: Double(WireBytes.f32(bytes, 5)),
                                  height: Double(WireBytes.f32(bytes, 9)), hotSpotX: Double(WireBytes.f32(bytes, 13)),
                                  hotSpotY: Double(WireBytes.f32(bytes, 17)), png: Data(bytes[headerSize...]))
    }
}
