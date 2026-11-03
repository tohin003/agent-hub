import CoreGraphics
import Foundation

/// What the privacy screen does with each mouse, trackpad and keyboard event while it's up.
enum CurtainInput {
    enum Decision: Equatable {
        /// The phone's own click or key (the hub posted it): it goes through to the Mac.
        case pass
        /// Someone at the Mac: nothing happens.
        case swallow
        /// Someone at the Mac pressed a key or clicked: show how to unlock.
        case wake
        /// A key typed while unlocking: it goes to the password, never to an app.
        case key
    }

    /// The events the curtain holds: the mouse and trackpad, the keyboard, and trackpad gestures (29 to 31 are the
    /// gesture, Dock and fluid swipe events, which have no public names; they would let someone switch Spaces).
    static let mask: CGEventMask = {
        let named: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
                                    .leftMouseDragged, .rightMouseDragged, .keyDown, .keyUp, .flagsChanged,
                                    .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        return (named.map(\.rawValue) + [29, 30, 31]).reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }()

    static func decide(_ type: CGEventType, own: Bool, unlocking: Bool) -> Decision {
        if own { return .pass }
        switch type {
        case .keyDown:
            return unlocking ? .key : .wake
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return unlocking ? .swallow : .wake
        default:
            return .swallow
        }
    }
}

/// A key someone at the Mac pressed while unlocking.
enum CurtainKey: Equatable, Sendable {
    case text(String)
    case delete
    case submit
    case cancel

    init?(keyCode: Int64, characters: String, flags: CGEventFlags) {
        switch keyCode {
        case 36, 76: self = .submit
        case 51: self = .delete
        case 53: self = .cancel
        default:
            // Shortcuts, arrows and function keys aren't part of a password (function keys type private-use
            // characters).
            guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return nil }
            let typed = characters.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
            guard !typed.isEmpty else { return nil }
            self = .text(String(String.UnicodeScalarView(typed)))
        }
    }

    /// A key-down event, as the keyboard layout and modifiers type it.
    init?(_ event: CGEvent) {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        self.init(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                  characters: String(utf16CodeUnits: units, count: length), flags: event.flags)
    }
}
