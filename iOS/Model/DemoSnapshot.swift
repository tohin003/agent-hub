import Foundation

/// A made-up Mac for screenshots and previews: accounts, sessions, conversations, usage and models, loaded from a
/// JSON file instead of a live hub (`-demo <path>`, relative to the app's Documents folder). Nothing connects.
nonisolated struct DemoSnapshot: Codable, Sendable {
    var hub: HubInfo
    var accounts: [Account]
    var sessions: [SessionInfo]
    var timelines: [String: [TimelineItem]]
    var tasks: [String: [BackgroundTask]]
    var catalogs: [String: ModelCatalog]
    var usage: [String: AccountUsage]

    static func load(_ path: String) -> DemoSnapshot? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : URL.documentsDirectory.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WireCoding.decoder.decode(DemoSnapshot.self, from: data)
    }
}
