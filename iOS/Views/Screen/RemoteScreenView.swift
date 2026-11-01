import SwiftUI

/// One display's picture with the gestures that drive the Mac: tap clicks, double tap double-clicks, touch and hold
/// right-clicks, pinch zooms (then drag pans), and in scroll mode a drag scrolls.
struct RemoteScreenView: View {
    var image: UIImage?
    var live: Bool
    var displayId: UInt32
    var scrollMode: Bool
    @Binding var zoomed: Bool
    var onInput: (ScreenInputParams) -> Void

    @State private var scale = 1.0
    @State private var offset = CGSize.zero
    @GestureState private var pinch = 1.0
    @GestureState private var pan = CGSize.zero
    @State private var ripple: CGPoint?
    @State private var lastScroll = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            ZStack {
                Color.black.opacity(0.92)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(currentScale)
                        .offset(currentOffset)
                        .opacity(live ? 1 : 0.55)
                } else {
                    ProgressView().tint(.white)
                }
                if let ripple {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 34, height: 34)
                        .position(ripple)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(tapGestures(container: container))
            .simultaneousGesture(magnify)
            .gesture(panGesture, including: scale > 1.01 && !scrollMode ? .gesture : .subviews)
            .gesture(scrollGesture(container: container), including: scrollMode ? .gesture : .subviews)
            .accessibilityElement()
            .accessibilityLabel("Your Mac's screen")
            .accessibilityHint("Tap to click. Touch and hold to right-click.")
            .accessibilityAddTraits(.allowsDirectInteraction)
        }
        .clipped()
        .onChange(of: scale) { _, new in zoomed = new > 1.01 }
    }

    private var currentScale: Double { min(6, max(1, scale * pinch)) }

    private var currentOffset: CGSize {
        CGSize(width: offset.width + pan.width, height: offset.height + pan.height)
    }

    // MARK: Gestures

    private func tapGestures(container: CGSize) -> some Gesture {
        let double = SpatialTapGesture(count: 2).onEnded { value in
            emit(.doubleClick, at: value.location, container: container)
        }
        let single = SpatialTapGesture(count: 1).onEnded { value in
            emit(.click, at: value.location, container: container)
        }
        let longPress = LongPressGesture(minimumDuration: 0.45).sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    emit(.rightClick, at: drag.location, container: container)
                }
            }
        return longPress.exclusively(before: double.exclusively(before: single))
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                scale = min(6, max(1, scale * value.magnification))
                if scale <= 1.01 {
                    withAnimation(.snappy) {
                        scale = 1
                        offset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($pan) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private func scrollGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let dx = value.translation.width - lastScroll.width
                let dy = value.translation.height - lastScroll.height
                guard abs(dx) + abs(dy) > 6, let point = normalized(value.location, container: container) else { return }
                lastScroll = value.translation
                onInput(ScreenInputParams(displayId: displayId, action: .scroll, x: point.x, y: point.y, dx: dx * 2, dy: dy * 2))
            }
            .onEnded { _ in lastScroll = .zero }
    }

    private func emit(_ action: ScreenInputParams.Action, at location: CGPoint, container: CGSize) {
        guard live, let point = normalized(location, container: container) else { return }
        withAnimation(.easeOut(duration: 0.15)) { ripple = location }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.25)) { ripple = nil }
        }
        onInput(ScreenInputParams(displayId: displayId, action: action, x: point.x, y: point.y))
    }

    /// Maps a point in the view to 0...1 on the Mac's display, undoing zoom, pan and the letterboxing.
    private func normalized(_ point: CGPoint, container: CGSize) -> CGPoint? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let aspect = image.size.width / image.size.height
        let fitted: CGSize = container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
        let origin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let unpanned = CGPoint(x: point.x - currentOffset.width, y: point.y - currentOffset.height)
        let unscaled = CGPoint(x: center.x + (unpanned.x - center.x) / currentScale,
                               y: center.y + (unpanned.y - center.y) / currentScale)
        let x = (unscaled.x - origin.x) / fitted.width
        let y = (unscaled.y - origin.y) / fitted.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Typing on the Mac: text, and its keys drawn as they are on a Mac keyboard. Hold a modifier (it lights up), then
/// type a letter or press a key for a shortcut, such as ⌘ C.
struct MacKeyboardSheet: View {
    var displayId: UInt32
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var held: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        TextField(held.isEmpty ? "Type on the Mac" : "Letter for \(heldSymbols)", text: $text, axis: .vertical)
                            .focused($focused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                        Button("Type", systemImage: "arrow.up.circle.fill") { typeText() }
                            .labelStyle(.iconOnly)
                            .font(.largeTitle)
                            .disabled(text.isEmpty)
                    }
                    Text("Goes to whatever is focused on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Row 1: esc, tab, delete.
                    HStack(spacing: 8) {
                        key(.escape)
                        key(.tab)
                        Spacer(minLength: 0)
                        key(.delete)
                    }
                    // Row 2: modifiers, return.
                    HStack(spacing: 8) {
                        modifier(.shift, name: "shift")
                        modifier(.control, name: "control")
                        Spacer(minLength: 0)
                        key(.returnKey)
                    }
                    // Row 3: option, command, space; arrows in the inverted T.
                    HStack(alignment: .bottom, spacing: 8) {
                        modifier(.option, name: "option")
                        modifier(.command, name: "command")
                        key(.space)
                        Spacer(minLength: 0)
                        VStack(spacing: 4) {
                            KeyCapButton(key: .up, height: 30) { press(MacKey.up) }
                            HStack(spacing: 4) {
                                KeyCapButton(key: .left, height: 30) { press(MacKey.left) }
                                KeyCapButton(key: .down, height: 30) { press(MacKey.down) }
                                KeyCapButton(key: .right, height: 30) { press(MacKey.right) }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Mac Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var heldSymbols: String {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")].filter { held.contains($0.0) }.map(\.1).joined()
    }

    private func key(_ key: MacKey) -> some View {
        KeyCapButton(key: key) { press(key) }
    }

    private func modifier(_ key: MacKey, name: String) -> some View {
        let wireName = name == "command" ? "cmd" : name
        return KeyCapButton(key: key, isOn: held.contains(wireName)) {
            if held.contains(wireName) { held.remove(wireName) } else { held.insert(wireName) }
        }
    }

    private func typeText() {
        let value = text
        text = ""
        let mods = Array(held)
        Task {
            await store.perform {
                if mods.isEmpty {
                    try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .type, text: value))
                } else if let first = value.first {
                    // With modifiers held, a typed letter becomes a shortcut, e.g. ⌘ C.
                    try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .key,
                                                                                      key: String(first), modifiers: mods))
                }
            }
            held.removeAll()
        }
    }

    private func press(_ key: MacKey) {
        guard let name = key.macKey else { return }
        let mods = Array(held)
        Task {
            await store.perform {
                try await store.client.send(Method.screenInput, ScreenInputParams(displayId: displayId, action: .key, key: name,
                                                                                  modifiers: mods))
            }
            held.removeAll()
        }
    }
}
