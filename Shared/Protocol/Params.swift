import Foundation

// Request parameters and results, one struct per method. Both sides compile this file.

nonisolated public struct HelloParams: Codable, Sendable {
    public var protocolVersion: Int
    /// "control" for the main connection, "screen" for the screen stream.
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

    public init(accountId: String, cwd: String, prompt: String? = nil, resumeId: String? = nil, mode: String? = nil,
                model: String? = nil, effort: String? = nil, fork: Bool? = nil, title: String? = nil,
                openWindow: Bool = true, fullScreen: Bool = true) {
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
    }
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

    public init(sessionId: String, text: String, submit: Bool = true) {
        self.sessionId = sessionId
        self.text = text
        self.submit = submit
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

    public init(displayId: UInt32, action: Action, x: Double? = nil, y: Double? = nil, toX: Double? = nil,
                toY: Double? = nil, dx: Double? = nil, dy: Double? = nil, text: String? = nil, key: String? = nil,
                modifiers: [String]? = nil) {
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

    public init(displayId: UInt32?, maxPixels: Int = 1600, fps: Int = 8, quality: Double = 0.6) {
        self.displayId = displayId
        self.maxPixels = maxPixels
        self.fps = fps
        self.quality = quality
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
