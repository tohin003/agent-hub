// Renders Agent Hub's app icons from the shared blob drawing code (Shared/Mascot), so the icon and the in-app
// mascot are the same artwork. Around it fly the agents' own logos, as the hub read them from their CLIs
// (~/.agenthub/logos, with the accounts in ~/.agenthub/config.json); plain dots until the hub has read them.
// Built and run by scripts/make-icons.sh:
//   swiftc -parse-as-library Shared/Mascot/*.swift Shared/Terminal/*.swift Shared/Protocol/*.swift \
//     Tools/IconGen/main.swift -o build/icongen && build/icongen <repo>
import AppKit
import SwiftUI

@main
struct IconGen {
    @MainActor
    static func main() {
        let repo = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        let iosIcons = "\(repo)/iOS/App/Assets.xcassets/AppIcon.appiconset"
        let macIcons = "\(repo)/Mac/App/Assets.xcassets/AppIcon.appiconset"
        let preview = "\(repo)/docs/images"
        for folder in [iosIcons, macIcons, preview] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let logos = agentLogos()
        print("agent logos: \(logos.count)")
        // iOS: full-bleed squares; the system applies the mask and the Liquid Glass treatment.
        write(IOSIcon(variant: .light, logos: logos), size: 1024, to: "\(iosIcons)/AppIcon-1024.png")
        write(IOSIcon(variant: .dark, logos: logos), size: 1024, to: "\(iosIcons)/AppIcon-1024-dark.png")
        // Tinted icons are one colour: the logos would turn to grey blots, so dots.
        write(IOSIcon(variant: .tinted, logos: []), size: 1024, to: "\(iosIcons)/AppIcon-1024-tinted.png")
        // macOS: the rounded-square plate is part of the artwork.
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            write(MacIcon(logos: size >= 64 ? logos : []), size: CGFloat(size), to: "\(macIcons)/icon_\(size).png")
        }
        // A large mascot for the README.
        write(MascotSheet(logos: logos), size: 1024, to: "\(preview)/mascot.png")
        print("icons written")
    }

    /// The agents' logos the hub has read, one per agent (Claude, Codex, Antigravity, OpenCode, …).
    static func agentLogos() -> [TerminalArt] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agenthub")
        struct Config: Decodable { var accounts: [Account]? }
        guard let data = try? Data(contentsOf: root.appending(path: "config.json")),
              let accounts = (try? JSONDecoder().decode(Config.self, from: data))?.accounts else { return [] }
        let withLogos = accounts.map { account -> Account in
            var account = account
            if let data = try? Data(contentsOf: root.appending(path: "logos/\(account.id).json")) {
                account.logo = try? WireCoding.decoder.decode(TerminalLogo.self, from: data)
            }
            return account
        }
        return Account.orbitLogos(withLogos).prefix(4).map { TerminalArt(ansi: $0.mark) }
    }

    @MainActor
    static func write(_ view: some View, size: CGFloat, to path: String) {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size).environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("couldn't render \(path)")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fatalError("couldn't write \(path): \(error)")
        }
    }
}

enum IconVariant {
    case light, dark, tinted
}

struct BlobCanvas: View {
    var palette: BlobPalette
    var shadow = true
    var logos: [TerminalArt] = []

    var body: some View {
        Canvas { context, size in
            BlobRenderer.draw(context, size: size, mood: .idle, time: 0, palette: palette, logos: logos, shadow: shadow)
        }
    }
}

struct IOSIcon: View {
    var variant: IconVariant
    var logos: [TerminalArt]

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                background
                BlobCanvas(palette: palette, shadow: variant != .tinted, logos: logos)
                    .frame(width: side * 0.94, height: side * 0.94)
            }
            .frame(width: side, height: side)
        }
    }

    /// On black (the person's choice, 2026-11-01): the Starlight blob, in light and dark mode alike; one colour for
    /// the tinted icon.
    private var palette: BlobPalette {
        switch variant {
        case .light, .dark: .starlight
        case .tinted: .mono
        }
    }

    private var background: some View {
        Color.black
    }
}

struct MacIcon: View {
    var logos: [TerminalArt]

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            let plate = side * 0.805
            ZStack {
                RoundedRectangle(cornerRadius: plate * 0.225, style: .continuous)
                    .fill(Color.black)
                    .frame(width: plate, height: plate)
                    .shadow(color: .black.opacity(0.25), radius: side * 0.012, y: side * 0.008)
                BlobCanvas(palette: .starlight, logos: logos)
                    .frame(width: plate * 0.96, height: plate * 0.96)
            }
            .frame(width: side, height: side)
        }
    }
}

struct MascotSheet: View {
    var logos: [TerminalArt]

    var body: some View {
        BlobCanvas(palette: .starlight(for: .light), logos: logos)
            .padding(40)
    }
}
