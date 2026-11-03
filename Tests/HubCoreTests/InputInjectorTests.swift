import CoreGraphics
import Testing

/// The mouse and keyboard events the hub makes from the phone's taps and keys.
@Suite("Mac input")
struct InputInjectorTests {
    /// An event carries exactly the modifiers the phone sent: a stray ⌃ in the system's input state must not make a
    /// tap a Control-click, which macOS takes as a right-click.
    @Test func eventsCarryOnlyTheModifiersSent() {
        let stray: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        #expect(InputInjector.flags(stray, modifiers: []) == [.maskNonCoalesced])
        #expect(InputInjector.flags(stray, modifiers: [.maskCommand]) == [.maskCommand, .maskNonCoalesced])
        #expect(InputInjector.flags([.maskAlphaShift], modifiers: [.maskShift]) == [.maskAlphaShift, .maskShift],
                "Caps Lock stays as it is")
    }
}
