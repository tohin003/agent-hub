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

/// The menu bar glyph: the blob as a one-colour template image (so macOS tints it), with its agents as small tiles
/// on the orbit; an orange badge joins it (in colour) when a session needs you.
enum MenuBarIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(attention: Bool, logos: [TerminalLogo] = []) -> NSImage {
        let key = "\(attention)-\(logos.count)"
        if let image = cache[key] { return image }
        let arts = logos.prefix(4).map { TerminalArt(ansi: $0.mark) }
        let size = CGSize(width: 26, height: 18)
        let renderer = ImageRenderer(content: Canvas { context, canvasSize in
            // The scene is wider than tall: draw it into a square as wide as the icon, centred.
            let side = canvasSize.width
            var scene = context
            scene.translateBy(x: 0, y: (canvasSize.height - side) / 2)
            BlobRenderer.draw(scene, size: CGSize(width: side, height: side), mood: .working, time: 0,
                              palette: attention ? .flat(.black, badge: .orange) : .flat(.black), logos: Array(arts),
                              shadow: false)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: nil)!
        image.isTemplate = !attention
        image.size = size
        cache[key] = image
        return image
    }
}
