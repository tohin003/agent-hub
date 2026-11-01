import SwiftUI

/// The session's terminal exactly as tmux shows it on the Mac, colours included. Pinch or use the size menu to
/// zoom; scroll sideways for wide screens; "Earlier output" loads the scrollback.
struct TerminalView: View {
    var model: SessionModel
    @AppStorage("terminal.fontSize") private var fontSize = 9.5
    @State private var scrollback: AttributedString?
    @State private var loadingScrollback = false
    @GestureState private var pinch = 1.0

    var body: some View {
        // No automatic scrolling: the screen updates in place and you stay where you are, scrolled right included.
        // It starts at the bottom left, the way a terminal opens.
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if let scrollback {
                    Text(scrollback)
                        .font(.system(size: effectiveSize, design: .monospaced))
                        .foregroundStyle(.primary)
                        .opacity(0.75)
                    Divider().padding(.vertical, 6)
                }
                Text(model.terminalText)
                    .font(.system(size: effectiveSize, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .fixedSize()
            .padding(10)
        }
        .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
        .scrollDismissesKeyboard(.never)
        .background(Color(.systemBackground))
        .gesture(MagnifyGesture().updating($pinch) { value, state, _ in
            state = value.magnification
        }.onEnded { value in
            fontSize = min(22, max(5, fontSize * value.magnification))
        })
        .overlay(alignment: .top) {
            if pinch != 1 {
                Text("\(Int(effectiveSize.rounded())) pt")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: effectiveSize.rounded()))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityHidden(true)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pinch == 1)
        .sensoryFeedback(.impact(weight: .light), trigger: effectiveSize <= 4 || effectiveSize >= 24) { _, atLimit in atLimit }
        .overlay {
            if model.terminal == nil {
                ContentUnavailableView("Connecting to the Terminal", systemImage: "terminal",
                                       description: Text("The screen of the agent's terminal on your Mac appears here."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Text Size", systemImage: "textformat.size") {
                    Button("Larger", systemImage: "plus.magnifyingglass") { fontSize = min(22, fontSize + 1) }
                    Button("Smaller", systemImage: "minus.magnifyingglass") { fontSize = max(5, fontSize - 1) }
                    Button("Fit Width", systemImage: "arrow.left.and.right") { fitWidth() }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Copy Screen Text", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = (model.terminal?.lines ?? []).map(ANSIRenderer.strip)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(scrollback == nil ? "Earlier Output" : "Hide Earlier Output", systemImage: "clock.arrow.circlepath") {
                    Task { await toggleScrollback() }
                }
                .disabled(loadingScrollback)
            }
        }
        .task {
            if !model.showTerminal && model.session.provider.hasStructuredTranscript {
                await model.setTerminalVisible(true)
            }
        }
    }

    private var effectiveSize: Double { min(24, max(4, fontSize * pinch)) }

    private func fitWidth() {
        let columns = Double(model.terminal?.columns ?? 120)
        let width = Double(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }.first ?? 390)
        fontSize = max(4, min(22, (width - 24) / (columns * 0.61)))
    }

    private func toggleScrollback() async {
        if scrollback != nil {
            scrollback = nil
            return
        }
        loadingScrollback = true
        let lines = await model.scrollback(lines: 3000)
        let visible = model.terminal?.lines.count ?? 0
        let earlier = Array(lines.dropLast(visible))
        scrollback = ANSIRenderer.render(lines: earlier.isEmpty ? ["(no earlier output)"] : earlier)
        loadingScrollback = false
    }
}
