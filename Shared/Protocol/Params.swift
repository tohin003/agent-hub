import Foundation

// Request parameters and results, one struct per method. Both sides compile this file.

nonisolated public struct HelloParams: Codable, Sendable {
    public var protocolVersion: Int
    /// "control" for the main connection, "screen" for the screen stream, "audio" for the Mac's sound.
    public var channel: String
    public var device: String

    public init(protocolVersion: Int = WireProtocol.version, channel: String, device: String) {
        self.protocolVersion = protocolVersion
        self.channel = channel
        self.device = device
    }
}

nonisolated public struct HelloResult: Codable, Sendable {
    public var hub: HubInfo
    public var accounts: [Account]
    public var sessions: [SessionInfo]

    public init(hub: HubInfo, accounts: [Account], sessions: [SessionInfo]) {
        self.hub = hub
        self.accounts = accounts
        self.sessions = sessions
    }
}

nonisolated public struct CreateSessionParams: Codable, Sendable {
    public var accountId: String
    public var cwd: String
    public var prompt: String?
    /// The agent's own conversation id to resume.
    public var resumeId: String?
    public var mode: String?
    public var model: String?
    public var effort: String?
    /// With `resumeId`: continue in a copy (a new conversation id), leaving the original as it was.
    public var fork: Bool?
    public var title: String?
    public var openWindow: Bool
    public var fullScreen: Bool
    /// With `resumeId`, for a conversation that's open elsewhere on the Mac (`HistoryEntry.running`): continue that
    /// very session instead of starting a copy.
    public var takeOver: TakeOver?

    public init(accountId: String, cwd: String, prompt: String? = nil, resumeId: String? = nil, mode: String? = nil,
                model: String? = nil, effort: String? = nil, fork: Bool? = nil, title: String? = nil,
                openWindow: Bool = true, fullScreen: Bool = true, takeOver: TakeOver? = nil) {
        self.accountId = accountId
        self.cwd = cwd
        self.prompt = prompt
        self.resumeId = resumeId
        self.mode = mode
        self.model = model
        self.effort = effort
        self.fork = fork
        self.title = title
        self.openWindow = openWindow
        self.fullScreen = fullScreen
        self.takeOver = takeOver
    }
}

/// When to take over a conversation that's open elsewhere on the Mac. A session in Claude's background service is
/// opened as it runs either way; one in a terminal tab moves into Agent Hub (its tab keeps showing it).
nonisolated public enum TakeOver: String, Codable, Sendable {
    /// Once the agent has finished the turn it's working on.
    case whenIdle
    /// Right away, stopping the turn it's working on.
    case now
}

nonisolated public struct SessionRef: Codable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

nonisolated public struct KillParams: Codable, Sendable {
    public var sessionId: String
    public var closeWindow: Bool

    public init(sessionId: String, closeWindow: Bool = true) {
        self.sessionId = sessionId
        self.closeWindow = closeWindow
    }
}

nonisolated public struct RenameParams: Codable, Sendable {
    public var sessionId: String
    public var title: String

    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

nonisolated public struct SendParams: Codable, Sendable {
    public var sessionId: String
    public var text: String
    /// Press Return after the text.
    public var submit: Bool
    /// The Mac's own draft as the phone last saw it (`SessionInfo.draft`). The text replaces that draft rather than
    /// joining it, and sending it unchanged only presses Return, so it goes exactly as the agent holds it.
    public var replacingDraft: String?

    public init(sessionId: String, text: String, submit: Bool = true, replacingDraft: String? = nil) {
        self.sessionId = sessionId
        self.text = text
        self.submit = submit
        self.replacingDraft = replacingDraft
    }
}

/// Keys in tmux's names: "Escape", "Enter", "Tab", "BTab" (Shift-Tab), "Up", "Down", "Left", "Right", "C-c", "1"...
nonisolated public struct KeysParams: Codable, Sendable {
    public var sessionId: String
    public var keys: [String]

    public init(sessionId: String, keys: [String]) {
        self.sessionId = sessionId
        self.keys = keys
    }
}

nonisolated public struct AnswerParams: Codable, Sendable {
    public var sessionId: String
    public var signature: String
    public var optionIndex: Int
    /// The key pressed once the cursor is on the option: "Enter" (choose; the default) or "Space" (tick or untick).
    public var key: String?

    public init(sessionId: String, signature: String, optionIndex: Int, key: String? = nil) {
        self.sessionId = sessionId
        self.signature = signature
        self.optionIndex = optionIndex
        self.key = key
    }
}

nonisolated public struct SubscribeParams: Codable, Sendable {
    public var sessionId: String
    public var timeline: Bool
    public var terminal: Bool
    /// How many of the newest timeline items to return now.
    public var tail: Int

    public init(sessionId: String, timeline: Bool = true, terminal: Bool = false, tail: Int = 150) {
        self.sessionId = sessionId
        self.timeline = timeline
        self.terminal = terminal
        self.tail = tail
    }
}

nonisolated public struct SubscribeResult: Codable, Sendable {
    public var session: SessionInfo
    public var items: [TimelineItem]
    public var hasEarlier: Bool
    public var tasks: [BackgroundTask]
    public var terminal: TerminalFrame?

    public init(session: SessionInfo, items: [TimelineItem], hasEarlier: Bool, tasks: [BackgroundTask],
                terminal: TerminalFrame?) {
        self.session = session
        self.items = items
        self.hasEarlier = hasEarlier
        self.tasks = tasks
        self.terminal = terminal
    }
}

nonisolated public struct PageParams: Codable, Sendable {
    public var sessionId: String
    public var beforeId: String
    public var limit: Int

    public init(sessionId: String, beforeId: String, limit: Int = 150) {
        self.sessionId = sessionId
        self.beforeId = beforeId
        self.limit = limit
    }
}

nonisolated public struct PageResult: Codable, Sendable {
    public var items: [TimelineItem]
    public var hasEarlier: Bool

    public init(items: [TimelineItem], hasEarlier: Bool) {
        self.items = items
        self.hasEarlier = hasEarlier
    }
}

nonisolated public struct ToolParams: Codable, Sendable {
    public var sessionId: String
    public var toolId: String
    /// Set when the tool belongs to a subagent's conversation.
    public var agentId: String?

    public init(sessionId: String, toolId: String, agentId: String? = nil) {
        self.sessionId = sessionId
        self.toolId = toolId
        self.agentId = agentId
    }
}

nonisolated public struct SubagentParams: Codable, Sendable {
    public var sessionId: String
    public var agentId: String
    /// Return only items changed after this version (0 for all).
    public var since: Int

    public init(sessionId: String, agentId: String, since: Int = 0) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.since = since
    }
}

nonisolated public struct SubagentResult: Codable, Sendable {
    public var items: [TimelineItem]
    public var version: Int
    public var finished: Bool
    public var title: String?

    public init(items: [TimelineItem], version: Int, finished: Bool, title: String?) {
        self.items = items
        self.version = version
        self.finished = finished
        self.title = title
    }
}

nonisolated public struct TaskOutputParams: Codable, Sendable {
    public var sessionId: String
    public var path: String
    /// Byte offset to read from; -1 means "the last chunk".
    public var offset: Int64

    public init(sessionId: String, path: String, offset: Int64 = -1) {
        self.sessionId = sessionId
        self.path = path
        self.offset = offset
    }
}

nonisolated public struct TaskOutputResult: Codable, Sendable {
    public var text: String
    public var offset: Int64
    public var size: Int64
    public var truncatedStart: Bool

    public init(text: String, offset: Int64, size: Int64, truncatedStart: Bool) {
        self.text = text
        self.offset = offset
        self.size = size
        self.truncatedStart = truncatedStart
    }
}

nonisolated public struct WindowParams: Codable, Sendable {
    /// "focus" brings the session's window forward (opening one if needed), "open" opens another, "close" closes it.
    public var sessionId: String
    public var action: String
    public var fullScreen: Bool

    public init(sessionId: String, action: String, fullScreen: Bool = true) {
        self.sessionId = sessionId
        self.action = action
        self.fullScreen = fullScreen
    }
}

nonisolated public struct ScrollbackParams: Codable, Sendable {
    public var sessionId: String
    public var lines: Int

    public init(sessionId: String, lines: Int = 2000) {
        self.sessionId = sessionId
        self.lines = lines
    }
}

nonisolated public struct ScrollbackResult: Codable, Sendable {
    public var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

/// A photo from the phone, saved on the Mac so the agent can read it by path.
nonisolated public struct UploadParams: Codable, Sendable {
    public var sessionId: String
    public var fileName: String
    public var base64: String

    public init(sessionId: String, fileName: String, base64: String) {
        self.sessionId = sessionId
        self.fileName = fileName
        self.base64 = base64
    }
}

nonisolated public struct UploadResult: Codable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

nonisolated public struct HistoryParams: Codable, Sendable {
    public var accountId: String
    public var limit: Int

    public init(accountId: String, limit: Int = 60) {
        self.accountId = accountId
        self.limit = limit
    }
}

nonisolated public struct HistoryTimelineParams: Codable, Sendable {
    public var accountId: String
    public var id: String

    public init(accountId: String, id: String) {
        self.accountId = accountId
        self.id = id
    }
}

nonisolated public struct FSListParams: Codable, Sendable {
    public var path: String
    public var showHidden: Bool
    public var directoriesOnly: Bool

    public init(path: String, showHidden: Bool = false, directoriesOnly: Bool = false) {
        self.path = path
        self.showHidden = showHidden
        self.directoriesOnly = directoriesOnly
    }
}

nonisolated public struct FSMkdirParams: Codable, Sendable {
    public var parent: String
    public var name: String

    public init(parent: String, name: String) {
        self.parent = parent
        self.name = name
    }
}

nonisolated public struct ScreenInputParams: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case click, doubleClick, rightClick, move, drag, scroll, type, key
        /// A live drag (double-tap and drag on the phone): the button down at `x`, `y`; the pointer to each move's;
        /// the button up at the end's. An older hub rejects them, and the phone then sends one `drag` at the end.
        case dragStart, dragMove, dragEnd
    }

    public var displayId: UInt32
    public var action: Action
    /// Position in the display, 0...1 from the top-left corner.
    public var x: Double?
    public var y: Double?
    /// Drag end point (0...1).
    public var toX: Double?
    public var toY: Double?
    /// Scroll amounts in points.
    public var dx: Double?
    public var dy: Double?
    public var text: String?
    /// A key name: "return", "escape", "tab", "delete", "space", "up", "down", "left", "right", letters and digits.
    public var key: String?
    /// "cmd", "shift", "option", "control".
    public var modifiers: [String]?
    /// For a click: which click of a run this is. 2 is the second click of a double click, sent as a mouse sends it.
    public var clickCount: Int?
    /// A live drag's start: whether a still hold picked it up (false: the finger moved first). Only for the hub's log;
    /// nil from an older phone.
    public var pickedUp: Bool?

    public init(displayId: UInt32, action: Action, x: Double? = nil, y: Double? = nil, toX: Double? = nil,
                toY: Double? = nil, dx: Double? = nil, dy: Double? = nil, text: String? = nil, key: String? = nil,
                modifiers: [String]? = nil, clickCount: Int? = nil, pickedUp: Bool? = nil) {
        self.clickCount = clickCount
        self.pickedUp = pickedUp
        self.displayId = displayId
        self.action = action
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.dx = dx
        self.dy = dy
        self.text = text
        self.key = key
        self.modifiers = modifiers
    }
}

nonisolated public struct ScreenSpaceParams: Codable, Sendable {
    public var displayId: UInt32
    /// Move to this Space index on the display, or by `step` (-1 left, +1 right), or "missionControl".
    public var targetIndex: Int?
    public var step: Int?
    public var missionControl: Bool?

    public init(displayId: UInt32, targetIndex: Int? = nil, step: Int? = nil, missionControl: Bool? = nil) {
        self.displayId = displayId
        self.targetIndex = targetIndex
        self.step = step
        self.missionControl = missionControl
    }
}

nonisolated public struct ScreenStartParams: Codable, Sendable {
    public var displayId: UInt32?
    /// Longest side in pixels of the frames sent.
    public var maxPixels: Int
    public var fps: Int
    /// JPEG quality 0...1.
    public var quality: Double
    /// "hevc", "h264" or "jpeg". Nil means JPEG (phones from before the video codecs). The hub falls back from HEVC
    /// to H.264 to JPEG if an encoder can't start, and the frames' kind and codec byte say what was chosen.
    public var codec: String?
    /// Target bits per second for HEVC and H.264; the hub may go lower when the link backs up.
    public var bitrate: Int?
    /// The phone passed its 4:4:4 decode test: HEVC may use 4:4:4 chroma.
    public var chroma444: Bool?
    /// The phone draws the pointer itself: the hub leaves it out of the picture and sends `CursorPositionMessage`s
    /// and `CursorShapeMessage`s.
    public var cursor: Bool?

    public init(displayId: UInt32?, maxPixels: Int = 1600, fps: Int = 8, quality: Double = 0.6, codec: String? = nil,
                bitrate: Int? = nil, chroma444: Bool? = nil, cursor: Bool? = nil) {
        self.displayId = displayId
        self.maxPixels = maxPixels
        self.fps = fps
        self.quality = quality
        self.codec = codec
        self.bitrate = bitrate
        self.chroma444 = chroma444
        self.cursor = cursor
    }
}

/// `screen.feedback`, from the phone on its screen connection, no reply: sent with every decoded video frame and at
/// least every 20 ms while streaming (which keeps the Wi-Fi awake in that direction too).
nonisolated public struct ScreenFeedback: Codable, Sendable, Equatable {
    /// The sequence number of the newest frame decoded and shown, if any yet.
    public var sequence: UInt32?
    /// Long-term reference tokens of the frames decoded since the last feedback.
    public var ltrTokens: [UInt32]
    /// The phone lost its place (a sequence gap or a decode error): it needs a frame marked `refresh`. With no
    /// `sequence` (nothing decoded yet, say a new decoder), or when a refresh sent half a second ago hasn't moved
    /// `sequence` past it, the hub sends a keyframe instead.
    public var refresh: Bool
    /// Picture bytes received since the last feedback, and over how many milliseconds, for the hub's bitrate.
    public var receivedBytes: Int?
    public var intervalMs: Double?
    /// How long the newest frame took to decode, in milliseconds.
    public var decodeMs: Double?
    /// Over UDP: how many frames the phone's transport has given up so far (a running count). A loss reported after a
    /// refresh went out may be that refresh: the hub asks for another refresh at once rather than a keyframe later.
    public var lost: Int?

    public init(sequence: UInt32?, ltrTokens: [UInt32] = [], refresh: Bool = false, receivedBytes: Int? = nil,
                intervalMs: Double? = nil, decodeMs: Double? = nil, lost: Int? = nil) {
        self.sequence = sequence
        self.ltrTokens = ltrTokens
        self.refresh = refresh
        self.receivedBytes = receivedBytes
        self.intervalMs = intervalMs
        self.decodeMs = decodeMs
        self.lost = lost
    }
}

/// How the Mac's sound arrives: the answer to `screen.audio`.
nonisolated public struct MacAudioFormat: Codable, Sendable, Equatable {
    /// "aac" (AAC-LC), "aac-eld" (AAC-ELD, for phones that ask for it) or "opus" (over UDP).
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var framesPerPacket: Int
    /// The encoder's magic cookie, which the decoder needs.
    public var magicCookie: Data
    /// The sound comes as `TimedAudioMessage`s, each with its capture time (hubs from step 2 on, to phones that ask).
    public var timed: Bool?

    public init(codec: String, sampleRate: Double, channels: Int, framesPerPacket: Int, magicCookie: Data,
                timed: Bool? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.magicCookie = magicCookie
        self.timed = timed
    }
}

/// The Mac's output volume and a display's brightness, 0...1; nil where the Mac can't change one.
nonisolated public struct MacLevels: Codable, Sendable, Equatable {
    public var volume: Double?
    public var muted: Bool?
    public var brightness: Double?

    public init(volume: Double?, muted: Bool?, brightness: Double?) {
        self.volume = volume
        self.muted = muted
        self.brightness = brightness
    }
}

/// `mac.levels`: what to change (nothing, to read them); brightness is the given display's, else the main one's.
nonisolated public struct MacLevelsParams: Codable, Sendable {
    public var displayId: UInt32?
    public var volume: Double?
    public var muted: Bool?
    public var brightness: Double?

    public init(displayId: UInt32?, volume: Double? = nil, muted: Bool? = nil, brightness: Double? = nil) {
        self.displayId = displayId
        self.volume = volume
        self.muted = muted
        self.brightness = brightness
    }
}

nonisolated public struct PermissionParams: Codable, Sendable {
    /// "screen" or "accessibility": shows macOS's own request, or opens the right Settings pane.
    public var kind: String

    public init(kind: String) {
        self.kind = kind
    }
}

nonisolated public struct TimelineEvent: Codable, Sendable {
    public var sessionId: String
    public var items: [TimelineItem]
    /// The phone should drop what it has and use `items` (the conversation file changed, e.g. after /clear).
    public var reset: Bool

    public init(sessionId: String, items: [TimelineItem], reset: Bool) {
        self.sessionId = sessionId
        self.items = items
        self.reset = reset
    }
}

nonisolated public struct TasksEvent: Codable, Sendable {
    public var sessionId: String
    public var tasks: [BackgroundTask]

    public init(sessionId: String, tasks: [BackgroundTask]) {
        self.sessionId = sessionId
        self.tasks = tasks
    }
}

nonisolated public struct ToastEvent: Codable, Sendable {
    public var message: String
    public var level: String

    public init(message: String, level: String) {
        self.message = message
        self.level = level
    }
}

nonisolated public struct Empty: Codable, Sendable {
    public init() {}
}

nonisolated public struct OKResult: Codable, Sendable {
    public var ok: Bool
    public var message: String?

    public init(ok: Bool = true, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}
