import SwiftUI

/// A key as it looks on a Mac keyboard: its symbol in the top corner and its name along the bottom ("⌘ command",
/// "⌥ option", "⌃ control", "⇧ shift", "⌫ delete", "↩ return", "⇥ tab", "esc"), or one large character for letter,
/// number and arrow keys.
struct MacKey: Hashable, Identifiable {
    var id: String { name + symbol + (character ?? "") }
    /// The symbol printed on the key ("⌘"), if it has one.
    var symbol: String
    /// The word printed on the key ("command"), if it has one.
    var name: String
    /// A single large character instead (letters, digits, arrows).
    var character: String?
    /// tmux key names sent to a terminal.
    var terminalKeys: [String]
    /// The key name the Mac's event code understands, for the screen keyboard.
    var macKey: String?
    var width: Double = 1

    static let escape = MacKey(symbol: "", name: "esc", terminalKeys: ["Escape"], macKey: "escape")
    static let tab = MacKey(symbol: "⇥", name: "tab", terminalKeys: ["Tab"], macKey: "tab", width: 1.3)
    static let shiftTab = MacKey(symbol: "⇧⇥", name: "shift tab", terminalKeys: ["BTab"], width: 1.5)
    static let returnKey = MacKey(symbol: "↩", name: "return", terminalKeys: ["Enter"], macKey: "return", width: 1.5)
    static let delete = MacKey(symbol: "⌫", name: "delete", terminalKeys: ["BSpace"], macKey: "delete", width: 1.4)
    static let space = MacKey(symbol: "", name: "space", terminalKeys: ["Space"], macKey: "space", width: 2.2)
    static let up = MacKey(symbol: "", name: "", character: "▲", terminalKeys: ["Up"], macKey: "up")
    static let down = MacKey(symbol: "", name: "", character: "▼", terminalKeys: ["Down"], macKey: "down")
    static let left = MacKey(symbol: "", name: "", character: "◀", terminalKeys: ["Left"], macKey: "left")
    static let right = MacKey(symbol: "", name: "", character: "▶", terminalKeys: ["Right"], macKey: "right")
    static let pageUp = MacKey(symbol: "⇞", name: "page up", terminalKeys: ["PageUp"], macKey: "pageup", width: 1.4)
    static let pageDown = MacKey(symbol: "⇟", name: "page down", terminalKeys: ["PageDown"], macKey: "pagedown", width: 1.5)

    static let command = MacKey(symbol: "⌘", name: "command", terminalKeys: [], width: 1.5)
    static let option = MacKey(symbol: "⌥", name: "option", terminalKeys: [], width: 1.3)
    static let control = MacKey(symbol: "⌃", name: "control", terminalKeys: [], width: 1.4)
    static let shift = MacKey(symbol: "⇧", name: "shift", terminalKeys: [], width: 1.5)

    static func character(_ value: String) -> MacKey {
        MacKey(symbol: "", name: "", character: value, terminalKeys: [value], macKey: value.lowercased())
    }

    /// Control plus a letter, as macOS writes it: ⌃C.
    static func control(_ letter: String) -> MacKey {
        MacKey(symbol: "⌃", name: "control", character: letter.uppercased(), terminalKeys: ["C-\(letter.lowercased())"],
               width: 1.3)
    }

    /// A key a dialog names in its hint (Space, Esc, Return, Tab, ⇧Tab, ⌃E, ◀ ▶, a letter such as "s").
    static func named(_ keyName: String, keys: [String]) -> MacKey {
        switch keyName {
        case "esc": .escape
        case "space": .space
        case "return": .returnKey
        case "tab": .tab
        case "⇧ tab": .shiftTab
        case "◀": .left
        case "▶": .right
        case let name where name.hasPrefix("⌃"):
            MacKey(symbol: "⌃", name: "control", character: String(name.dropFirst()), terminalKeys: keys, width: 1.3)
        default: MacKey(symbol: "", name: "", character: keyName.uppercased(), terminalKeys: keys)
        }
    }

    var accessibilityName: String {
        if let character, symbol == "⌃" { return "control \(character)" }
        switch character {
        case "▲": return "up arrow"
        case "▼": return "down arrow"
        case "◀": return "left arrow"
        case "▶": return "right arrow"
        default: return character ?? name
        }
    }
}

/// Draws a Mac key. `isOn` lights a held modifier.
struct KeyCapLabel: View {
    var key: MacKey
    var isOn = false
    var height = 46.0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let character = key.character {
                Text(character)
                    .font(.system(size: key.symbol.isEmpty ? 17 : 16, weight: .medium, design: .rounded))
                if !key.symbol.isEmpty {
                    Text(key.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(5)
                }
            } else {
                if !key.symbol.isEmpty {
                    Text(key.symbol)
                        .font(.system(size: 13, weight: .regular))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 5)
                        .padding(.trailing, 6)
                }
                Text(key.name)
                    .font(.system(size: 10.5, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: key.symbol.isEmpty ? .center : .bottomLeading)
                    .padding(.bottom, key.symbol.isEmpty ? 0 : 5)
                    .padding(.leading, key.symbol.isEmpty ? 0 : 6)
            }
        }
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .frame(width: 44 * key.width, height: height)
        .background(keyFill, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.6 : 0.22), radius: 0, x: 0, y: 1)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.5)
        }
    }

    private var keyFill: Color {
        if isOn { return .accentColor }
        return colorScheme == .dark ? Color(white: 0.2) : .white
    }
}

/// A key you press: sends `action` and taps a light haptic.
struct KeyCapButton: View {
    var key: MacKey
    var isOn = false
    var height = 46.0
    var action: () -> Void
    @State private var presses = 0

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            KeyCapLabel(key: key, isOn: isOn, height: height)
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(key.accessibilityName)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: presses)
    }
}

/// A key goes down a little when pressed.
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}
