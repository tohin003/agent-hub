import CoreGraphics
import Testing

/// The privacy screen's hold on the Mac's own mouse and keyboard: the phone's clicks and keys pass, the Mac's own are
/// swallowed, a key or click asks to unlock, and while unlocking the keys go to the password.
@Suite("Privacy screen")
struct PrivacyCurtainTests {
    @Test func thePhonesEventsPass() throws {
        let click = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
                                         mouseButton: .left))
        #expect(!InputInjector.isOwn(click))
        InputInjector.mark(click)
        #expect(InputInjector.isOwn(click))
        for type in [CGEventType.leftMouseDown, .mouseMoved, .keyDown, .scrollWheel] {
            #expect(CurtainInput.decide(type, own: true, unlocking: false) == .pass)
            #expect(CurtainInput.decide(type, own: true, unlocking: true) == .pass)
        }
    }

    @Test func theMacsOwnInputIsHeldBack() {
        #expect(CurtainInput.decide(.keyDown, own: false, unlocking: false) == .wake)
        #expect(CurtainInput.decide(.leftMouseDown, own: false, unlocking: false) == .wake)
        #expect(CurtainInput.decide(.rightMouseDown, own: false, unlocking: false) == .wake)
        for type in [CGEventType.mouseMoved, .leftMouseUp, .leftMouseDragged, .scrollWheel, .keyUp, .flagsChanged] {
            #expect(CurtainInput.decide(type, own: false, unlocking: false) == .swallow)
        }
        // A trackpad swipe between Spaces (a gesture event) does nothing either.
        if let swipe = CGEventType(rawValue: 29) {
            #expect(CurtainInput.decide(swipe, own: false, unlocking: false) == .swallow)
        }
        #expect(CurtainInput.mask & (CGEventMask(1) << 29) != 0)
        #expect(CurtainInput.mask & (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)) != 0)
    }

    @Test func whileUnlockingKeysGoToThePassword() {
        #expect(CurtainInput.decide(.keyDown, own: false, unlocking: true) == .key)
        #expect(CurtainInput.decide(.keyUp, own: false, unlocking: true) == .swallow)
        #expect(CurtainInput.decide(.leftMouseDown, own: false, unlocking: true) == .swallow)
    }

    @Test func keysForThePassword() {
        #expect(CurtainKey(keyCode: 0, characters: "a", flags: []) == .text("a"))
        #expect(CurtainKey(keyCode: 0, characters: "A", flags: .maskShift) == .text("A"))
        #expect(CurtainKey(keyCode: 36, characters: "\r", flags: []) == .submit)
        #expect(CurtainKey(keyCode: 76, characters: "\u{3}", flags: []) == .submit)
        #expect(CurtainKey(keyCode: 51, characters: "\u{7F}", flags: []) == .delete)
        #expect(CurtainKey(keyCode: 53, characters: "\u{1B}", flags: []) == .cancel)
        // Shortcuts, arrows and function keys type nothing.
        #expect(CurtainKey(keyCode: 9, characters: "v", flags: .maskCommand) == nil)
        #expect(CurtainKey(keyCode: 123, characters: "\u{F702}", flags: []) == nil)
        #expect(CurtainKey(keyCode: 122, characters: "\u{10}", flags: []) == nil)
    }
}
