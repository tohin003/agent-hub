import SwiftUI

/// Agent Hub's shared look: one tint, Starlight (the MacBook Air finish: a warm champagne silver; the asset
/// catalog's accent, deeper in light mode so text stays readable), system backgrounds and text styles, and a colour
/// and symbol per agent so sessions are recognisable at a glance. Colour never carries meaning alone: every state also
/// has a word and a symbol.
enum Theme {
    static let bubbleRadius = 20.0
    static let cardRadius = 18.0
    static let rowSpacing = 10.0

    /// Starlight itself (#E9E0CF), for art and highlights on dark backgrounds.
    static let starlight = Color(red: 0.914, green: 0.878, blue: 0.812)
    /// Starlight's highlight (#FAF6EF) and shadow (#C8BBA6).
    static let starlightHighlight = Color(red: 0.980, green: 0.965, blue: 0.937)
    static let starlightShadow = Color(red: 0.784, green: 0.733, blue: 0.651)
    /// A deeper Starlight (#85704F) for filled controls with white labels, in both modes (4.7:1 against white).
    static let starlightDeep = Color(red: 0.522, green: 0.439, blue: 0.310)
    /// Text and symbols on the accent: graphite on Starlight (dark mode), white on the deeper tone (light mode).
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.11, blue: 0.094, alpha: 1) : .white
    })
    /// A soft Starlight sheen for highlighted surfaces (selected rows, the active card).
    static let sheen = LinearGradient(colors: [starlight.opacity(0.22), starlight.opacity(0.06)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension ProviderKind {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.62, green: 0.64, blue: 0.68)
        case .antigravity: Color(red: 0.36, green: 0.58, blue: 0.95)
        case .opencode: Color(red: 0.55, green: 0.55, blue: 0.58)
        case .gemini: Color(red: 0.55, green: 0.42, blue: 0.95)
        case .shell, .other: Color(white: 0.45)
        }
    }

    /// Generic symbols (no brand marks).
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "arrow.up.circle"
        case .opencode: "curlybraces"
        case .gemini: "diamond"
        case .shell: "apple.terminal"
        case .other: "terminal"
        }
    }
}

extension SessionState {
    var title: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .waiting: "Needs you"
        case .idle: "Ready"
        case .exited: "Agent exited"
        case .ended: "Ended"
        }
    }

    var symbol: String {
        switch self {
        case .starting: "hourglass"
        case .working: "ellipsis"
        case .waiting: "hand.raised.fill"
        case .idle: "checkmark.circle"
        case .exited: "stop.circle"
        case .ended: "moon.zzz"
        }
    }

    var tint: Color {
        switch self {
        case .starting: .secondary
        case .working: .accentColor
        case .waiting: .orange
        case .idle: .green
        case .exited, .ended: .secondary
        }
    }

    var mood: BlobMood {
        switch self {
        case .working, .starting: .working
        case .waiting: .attention
        case .idle: .idle
        case .exited, .ended: .sleeping
        }
    }
}

extension ToolCall.Category {
    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .write: "doc.badge.plus"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .todo: "checklist"
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .monitor: "waveform.path.ecg"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .message: "paperplane"
        case .task: "gearshape.2"
        case .mcp: "puzzlepiece.extension"
        case .skill: "wand.and.stars"
        case .notebook: "book.closed"
        case .other: "wrench.and.screwdriver"
        }
    }
}

extension BackgroundTask.Kind {
    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .agent: "person.2"
        case .fork: "arrow.triangle.branch"
        case .monitor: "waveform.path.ecg"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .other: "gearshape"
        }
    }

    var title: String {
        switch self {
        case .shell: "Background shell"
        case .agent: "Subagent"
        case .fork: "Fork"
        case .monitor: "Monitor"
        case .workflow: "Workflow"
        case .other: "Task"
        }
    }
}

extension BackgroundTask.Status {
    var title: String {
        switch self {
        case .running: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

extension String {
    /// "/Users/me/Projects/App" → "~/Projects/App".
    var abbreviatingHome: String {
        let parts = split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" {
            return "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        return self
    }

    var lastPathComponent: String { (self as NSString).lastPathComponent }
}

/// Tappable cards and rows: they give a little under your finger and spring back, like Apple's own.
struct PressStyle: ButtonStyle {
    var scale = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
}
