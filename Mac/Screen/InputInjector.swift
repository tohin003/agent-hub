import AppKit
import CoreGraphics

/// Turns the phone's taps, drags, scrolls and typing into mouse and keyboard events on the Mac.
/// Needs Accessibility permission for Agent Hub (System Settings › Privacy & Security › Accessibility).
enum InputInjector {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var trusted: Bool { AXIsProcessTrusted() }

    /// A point on a display, from the phone's 0...1 coordinates, in global screen coordinates (points).
    static func point(display: CGDirectDisplayID, x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(display)
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + cx * (bounds.width - 1), y: bounds.minY + cy * (bounds.height - 1))
    }

    static func perform(_ input: ScreenInputParams) throws {
        guard trusted else {
            throw WireError(code: "accessibility", message: "Allow Agent Hub in System Settings › Privacy & Security › Accessibility to control the Mac.")
        }
        let display = CGDirectDisplayID(input.displayId)
        let flags = modifierFlags(input.modifiers ?? [])
        switch input.action {
        case .move:
            move(to: point(display: display, x: input.x ?? 0.5, y: input.y ?? 0.5))
        case .click:
            click(at: point(display: display, x: input.x ?? 0.5, y: input.y ?? 0.5), button: .left, count: 1, flags: flags)
        case .doubleClick:
            let at = point(display: display, x: input.x ?? 0.5, y: input.y ?? 0.5)
            click(at: at, button: .left, count: 1, flags: flags)
            click(at: at, button: .left, count: 2, flags: flags)
        case .rightClick:
            click(at: point(display: display, x: input.x ?? 0.5, y: input.y ?? 0.5), button: .right, count: 1, flags: flags)
        case .drag:
            let from = point(display: display, x: input.x ?? 0.5, y: input.y ?? 0.5)
            let to = point(display: display, x: input.toX ?? input.x ?? 0.5, y: input.toY ?? input.y ?? 0.5)
            drag(from: from, to: to)
        case .scroll:
            if let x = input.x, let y = input.y { move(to: point(display: display, x: x, y: y)) }
            scroll(dx: input.dx ?? 0, dy: input.dy ?? 0)
        case .type:
            type(input.text ?? "")
        case .key:
            guard let name = input.key, let code = keyCode(name) else {
                throw WireError.badRequest("Unknown key \(input.key ?? "")")
            }
            press(code, flags: flags)
        }
    }

    static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        move(to: point)
        for type in [down, up] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            if !flags.isEmpty { event.flags = flags }
            event.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(10_000)
        }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func scroll(dx: Double, dy: Double) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()),
                wheel2: Int32(dx.rounded()), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    static func type(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                press(36, flags: [])
                continue
            }
            var units = Array(String(scalar).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cghidEventTap)
            }
            usleep(4_000)
        }
    }

    static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    static func modifierFlags(_ names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    static func keyCode(_ name: String) -> CGKeyCode? {
        let named: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124,
            "down": 125, "up": 126, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f11": 103, "f12": 111,
            "missioncontrol": 160,
        ]
        if let code = named[name.lowercased()] { return code }
        let letters: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        return letters[character]
    }
}
