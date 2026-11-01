import ActivityKit
import Foundation

/// The Live Activity for your sessions (Lock Screen and Dynamic Island): the session that matters most right now, and
/// how many are working or waiting. Shared by the app (which starts and updates it) and the widget extension (which
/// draws it).
nonisolated struct SessionsActivity: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated enum Phase: String, Codable, Hashable, Sendable {
            /// A session needs you (a question, an approval).
            case waiting
            /// Agents are at work.
            case working
            /// Everything's done.
            case done
        }

        /// The session the activity is about (opens it when tapped).
        var sessionId: String?
        var title: String
        var account: String
        var phase: Phase
        /// The question, or what the agent is doing ("Thinking… (34s)").
        var detail: String
        var waiting: Int
        var working: Int
        /// When the shown session started working (a live timer).
        var since: Date?
    }

    var macName: String
    /// The agents' logos for the mascot's orbit, each a tiny RGB picture (`logoPixels` square, 3 bytes a pixel): a
    /// Live Activity carries at most 4 KB, too little for the logos' terminal art.
    var logos: [Data] = []
    var logoPixels: Int = 12
}
