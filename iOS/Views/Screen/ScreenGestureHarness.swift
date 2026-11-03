#if DEBUG
import SwiftUI

/// For UI tests (`-screenGestureTest YES`, debug builds only): the Screen tab's view over a made-up Mac screen, in the
/// same tab, navigation stack and Spaces pager, showing what each gesture would send to the Mac. Nothing connects.
struct ScreenGestureHarness: View {
    @State private var inputs: [String] = []
    @State private var zoomed = false
    @State private var scrollMode = false
    @State private var page: Int? = 0
    /// Where on the display the last click went, and the last drag (from where to where).
    @State private var lastClickPoint = "none"
    @State private var dragFrom = "none"
    @State private var lastDrag = "none"
    private let image = Self.makeImage()

    var body: some View {
        TabView {
            Tab("Screen", systemImage: "display") {
                NavigationStack {
                    VStack(spacing: 0) {
                        HStack {
                            Text(inputs.last ?? "none").accessibilityIdentifier("lastInput")
                            Text(inputs.suffix(6).joined(separator: ", "))
                                .lineLimit(1)
                                .accessibilityIdentifier("recentInputs")
                            Spacer()
                            Text("\(inputs.count)").accessibilityIdentifier("inputCount")
                            Text(zoomed ? "zoomed" : "whole").accessibilityIdentifier("zoom")
                            Text("page \(page ?? -1)").accessibilityIdentifier("page")
                            Toggle("Drag to Scroll", isOn: $scrollMode)
                                .labelsHidden()
                                .accessibilityIdentifier("scrollMode")
                        }
                        .font(.caption.monospaced())
                        .padding(.horizontal)
                        HStack {
                            Text(dragCounts).accessibilityIdentifier("dragCounts")
                            Text("scrolls \(inputs.filter { $0.hasPrefix("scroll") }.count)").accessibilityIdentifier("scrollCount")
                            Text(lastClickPoint).accessibilityIdentifier("lastClickPoint")
                            Text(lastDrag).accessibilityIdentifier("lastDrag")
                            Spacer()
                        }
                        .lineLimit(1)
                        .font(.caption2.monospaced())
                        .padding(.horizontal)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(0..<2, id: \.self) { index in
                                    RemoteScreenView(image: image, live: true, displayId: 1, scrollMode: scrollMode,
                                                     zoomed: $zoomed) { input in
                                        inputs.append(Self.describe(input))
                                        note(input)
                                    }
                                    .containerRelativeFrame(.horizontal)
                                    .id(index)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: $page)
                        .scrollDisabled(zoomed || scrollMode)
                        .scrollIndicators(.hidden)
                    }
                    .navigationTitle("Gesture Test")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarVisibility(zoomed ? .hidden : .automatic, for: .tabBar)
                }
            }
        }
    }

    /// How many live-drag messages went: starts, moves, ends.
    private var dragCounts: String {
        let count = { (name: String) in inputs.filter { $0 == name }.count }
        return "drags \(count("dragStart")) \(count("dragMove")) \(count("dragEnd"))"
    }

    private func note(_ input: ScreenInputParams) {
        guard let x = input.x, let y = input.y else { return }
        let spot = String(format: "%.3f,%.3f", x, y)
        switch input.action {
        case .click: lastClickPoint = spot
        case .dragStart: dragFrom = spot
        case .dragEnd: lastDrag = "\(dragFrom) to \(spot)"
        default: break
        }
    }

    private static func describe(_ input: ScreenInputParams) -> String {
        switch input.action {
        case .click: "click \(input.clickCount ?? 1)"
        case .scroll: (input.dy ?? 0) < 0 ? "scroll down" : (input.dy ?? 0) > 0 ? "scroll up" : "scroll sideways"
        default: input.action.rawValue
        }
    }

    /// A 16:10 "screen" with a grid, so a zoom shows.
    private static func makeImage() -> UIImage {
        let size = CGSize(width: 1600, height: 1000)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.4, alpha: 1).setFill()
            for x in stride(from: 0, to: size.width, by: 100) { context.fill(CGRect(x: x, y: 0, width: 2, height: size.height)) }
            for y in stride(from: 0, to: size.height, by: 100) { context.fill(CGRect(x: 0, y: y, width: size.width, height: 2)) }
        }
    }
}
#endif
