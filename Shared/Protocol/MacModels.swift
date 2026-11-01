import Foundation

/// The visible terminal of a session: each line keeps its ANSI colour codes (the phone renders them).
nonisolated public struct TerminalFrame: Codable, Sendable, Hashable {
    public var sessionId: String
    public var columns: Int
    public var rows: Int
    public var lines: [String]
    public var cursorX: Int
    public var cursorY: Int
    public var sequence: Int

    public init(sessionId: String, columns: Int, rows: Int, lines: [String], cursorX: Int, cursorY: Int, sequence: Int) {
        self.sessionId = sessionId
        self.columns = columns
        self.rows = rows
        self.lines = lines
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.sequence = sequence
    }
}

/// A file or folder on the Mac.
nonisolated public struct FSEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isHidden: Bool
    public var isGitRepo: Bool
    public var modified: Date?
    public var size: Int64?

    public init(name: String, path: String, isDirectory: Bool, isHidden: Bool, isGitRepo: Bool, modified: Date?,
                size: Int64?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isGitRepo = isGitRepo
        self.modified = modified
        self.size = size
    }
}

nonisolated public struct FSListing: Codable, Sendable, Hashable {
    public var path: String
    public var parent: String?
    public var entries: [FSEntry]
    public var isGitRepo: Bool
    public var gitBranch: String?

    public init(path: String, parent: String?, entries: [FSEntry], isGitRepo: Bool, gitBranch: String?) {
        self.path = path
        self.parent = parent
        self.entries = entries
        self.isGitRepo = isGitRepo
        self.gitBranch = gitBranch
    }
}

nonisolated public struct FSRoots: Codable, Sendable, Hashable {
    public var home: String
    public var places: [FSEntry]
    public var recents: [FSEntry]

    public init(home: String, places: [FSEntry], recents: [FSEntry]) {
        self.home = home
        self.places = places
        self.recents = recents
    }
}

/// A display attached to the Mac, with its Spaces.
nonisolated public struct DisplayInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: UInt32
    public var name: String
    /// Size in points.
    public var width: Double
    public var height: Double
    public var isMain: Bool
    public var spaces: [SpaceInfo]

    public init(id: UInt32, name: String, width: Double, height: Double, isMain: Bool, spaces: [SpaceInfo]) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
        self.spaces = spaces
    }

    public var currentSpaceIndex: Int? { spaces.firstIndex { $0.isCurrent } }
}

/// One Space (desktop or full-screen app) on a display.
nonisolated public struct SpaceInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: UInt64
    public var index: Int
    public var isFullscreen: Bool
    public var isCurrent: Bool
    /// For a full-screen Space: the app and window shown in it.
    public var title: String?

    public init(id: UInt64, index: Int, isFullscreen: Bool, isCurrent: Bool, title: String?) {
        self.id = id
        self.index = index
        self.isFullscreen = isFullscreen
        self.isCurrent = isCurrent
        self.title = title
    }
}

/// What the Mac side can and can't do right now.
nonisolated public struct HubInfo: Codable, Sendable, Hashable {
    public var macName: String
    public var user: String
    public var version: String
    public var tailscaleName: String?
    public var tailscaleIP: String?
    public var port: Int
    public var screenRecording: Bool
    public var accessibility: Bool
    public var tmuxPath: String?
    public var terminalApp: String
    public var renewal: RenewalInfo?
    public var clients: Int
    /// Whether the live screen is switched on in Agent Hub (nil from an older hub: on).
    public var screenSharing: Bool?

    public init(macName: String, user: String, version: String, tailscaleName: String?, tailscaleIP: String?, port: Int,
                screenRecording: Bool, accessibility: Bool, tmuxPath: String?, terminalApp: String,
                renewal: RenewalInfo?, clients: Int, screenSharing: Bool? = nil) {
        self.macName = macName
        self.user = user
        self.version = version
        self.tailscaleName = tailscaleName
        self.tailscaleIP = tailscaleIP
        self.port = port
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.tmuxPath = tmuxPath
        self.terminalApp = terminalApp
        self.renewal = renewal
        self.clients = clients
        self.screenSharing = screenSharing
    }
}

/// The iPhone app's signing, as the renewal script last recorded it.
nonisolated public struct RenewalInfo: Codable, Sendable, Hashable {
    public var installedAt: Date?
    public var expiresAt: Date?
    public var lastAttempt: Date?
    public var lastResult: String?
    public var lastSucceeded: Bool?
    public var running: Bool
    /// Renews by itself before the 7 days run out (nil from an older hub: on).
    public var autoRenew: Bool?
    /// Who started the last try: "auto", "menu", "phone", "manual".
    public var lastReason: String?

    public init(installedAt: Date?, expiresAt: Date?, lastAttempt: Date?, lastResult: String?, lastSucceeded: Bool?,
                running: Bool, autoRenew: Bool? = nil, lastReason: String? = nil) {
        self.installedAt = installedAt
        self.expiresAt = expiresAt
        self.lastAttempt = lastAttempt
        self.lastResult = lastResult
        self.lastSucceeded = lastSucceeded
        self.running = running
        self.autoRenew = autoRenew
        self.lastReason = lastReason
    }
}
