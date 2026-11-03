import AppKit
import SwiftUI

/// Agent Hub for Mac: a menu bar item that runs the hub your iPhone connects to.
@main
struct AgentHubMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(hub: appDelegate.hub)
        } label: {
            Image(nsImage: MenuBarIcon.image(attention: appDelegate.hub.sessionList.contains { $0.attention != nil && $0.attention?.optional != true },
                                             logos: Account.orbitLogos(appDelegate.hub.accounts)))
            // The iPhone app's days left, only when it needs you (a day or less, expired, renewing, or a failed try).
            if let badge = RenewalWords.badge(appDelegate.hub.renewal) {
                Text(badge)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let hub = Hub()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            hub.start()
        }
    }
}
