import AppKit
import CoreGraphics

/// The Mac's displays and their Spaces. Listing Spaces uses SkyLight's read-only space list (looked up at run time,
/// so a macOS change only hides the Spaces strip); switching uses the standard ⌃← / ⌃→ shortcuts.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let mainConnection: MainConnection? = {
        guard let handle = skyLight, let symbol = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: MainConnection.self)
    }()

    private static let copySpaces: CopySpaces? = {
        guard let handle = skyLight,
              let symbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") ?? dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(symbol, to: CopySpaces.self)
    }()

    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let spaceMap = managedSpaces()
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        })
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            let uuid = displayUUID(id)
            let spaces = spaceMap[uuid ?? ""] ?? spaceMap["Main"].flatMap { CGDisplayIsMain(id) != 0 ? $0 : nil } ?? []
            return DisplayInfo(id: id, name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"),
                               width: bounds.width, height: bounds.height, isMain: CGDisplayIsMain(id) != 0, spaces: spaces)
        }.sorted { a, b in a.isMain && !b.isMain }
    }

    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Spaces per display UUID ("Main" when all displays share Spaces).
    static func managedSpaces() -> [String: [SpaceInfo]] {
        guard let mainConnection, let copySpaces, let array = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [SpaceInfo]] = [:]
        let windowNames = fullScreenWindowNames()
        for display in array {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            result[identifier] = spaces.enumerated().map { index, space in
                let id = space["ManagedSpaceID"] as? Int ?? space["id64"] as? Int ?? index
                let type = space["type"] as? Int ?? 0
                var title: String?
                if type == 4 {
                    if let pid = space["pid"] as? Int,
                       let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                        title = app.localizedName
                    }
                    if let tile = space["TileLayoutManager"] as? [String: Any],
                       let tiles = tile["TileSpaces"] as? [[String: Any]] {
                        let names = tiles.compactMap { $0["name"] as? String ?? $0["appName"] as? String }
                        if !names.isEmpty { title = names.joined(separator: " · ") }
                    }
                    if let wid = space["fs_wid"] as? Int, let name = windowNames[wid] { title = name }
                }
                return SpaceInfo(id: UInt64(id), index: index, isFullscreen: type == 4, isCurrent: id == current,
                                 title: title)
            }
        }
        return result
    }

    /// Titles of on-screen and off-screen windows by window number, for naming full-screen Spaces.
    private static func fullScreenWindowNames() -> [Int: String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var names: [Int: String] = [:]
        for window in list {
            guard let number = window[kCGWindowNumber as String] as? Int else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let name = window[kCGWindowName as String] as? String ?? ""
            names[number] = name.isEmpty ? owner : "\(owner) — \(name)"
        }
        return names
    }

    /// Moves `steps` Spaces left (negative) or right on the display holding `display` (the pointer is moved there
    /// first, because the shortcut acts on the display under it).
    static func move(display: CGDirectDisplayID, steps: Int) async {
        guard steps != 0 else { return }
        let bounds = CGDisplayBounds(display)
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouseGlobal = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        if !bounds.contains(mouseGlobal) {
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let code: CGKeyCode = steps > 0 ? 124 : 123
        for _ in 0..<abs(steps) {
            InputInjector.press(code, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
            try? await Task.sleep(for: .milliseconds(420))
        }
    }

    static func missionControl() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            InputInjector.press(160, flags: [])
        }
    }
}
