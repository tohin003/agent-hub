import Foundation
import Testing

/// The fixtures are real first screens of the person's CLIs, captured with `tmux capture-pane -e` (personal details
/// replaced). The extractor knows none of these CLIs; it has to find each logo on its own.
@Suite("Reading a CLI's logo from its screen")
struct LogoExtractorTests {
    private func screen(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).ansi")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func plain(_ lines: [String]) -> [String] {
        lines.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
    }

    @Test func claudeCodeMascot() throws {
        let logo = try #require(LogoExtractor.extract(try screen("claude")))
        #expect(logo.source == "art")
        #expect(plain(logo.mark) == [" ▐▛███▛█", "▝▜██████▀", " ▝▝   ▝▝"])
        #expect(logo.mark[0].contains("38;5;174"))
        #expect(logo.mark[0].contains("48;5;16"))
    }

    @Test func codexSymbol() throws {
        let logo = try #require(LogoExtractor.extract(try screen("codex")))
        #expect(logo.source == "text")
        #expect(plain(logo.mark) == [">_"])
        #expect(logo.mark[0].contains("38;2;99;168;248"))
    }

    @Test func openCodeWordmarkAndMark() throws {
        let logo = try #require(LogoExtractor.extract(try screen("opencode")))
        #expect(logo.source == "art")
        #expect(plain(logo.full).count == 4)
        #expect(plain(logo.full)[1].hasPrefix("█▀▀█ █▀▀█ █▀▀█ █▀▀▄"))
        // The mark keeps whole letters and stays roughly square.
        let width = plain(logo.mark).map(\.count).max() ?? 0
        #expect(width <= 12)
        #expect(plain(logo.mark).contains { $0.hasPrefix("█▀▀█") })
    }

    @Test func geminiChevronIsTheMark() throws {
        let logo = try #require(LogoExtractor.extract(try screen("gemini")))
        #expect(logo.source == "art")
        #expect(plain(logo.mark) == ["▝▜▄", "  ▝▜▄", " ▗▟▀", "▝▀"])
        #expect(plain(logo.full)[0].contains("▗█▀▀▜▙"))
    }

    @Test func antigravityArch() throws {
        let logo = try #require(LogoExtractor.extract(try screen("agy")))
        #expect(logo.source == "art")
        #expect(plain(logo.mark).count == 5)
        #expect(plain(logo.mark)[0].trimmingCharacters(in: .whitespaces) == "▄▀▀▄")
        #expect(logo.mark[1].contains("38;5;149"))
        #expect(!logo.full.joined().contains("@"))
    }

    @Test func noLogoOnAPlainShell() {
        #expect(LogoExtractor.extract("you@mac project % ls\nREADME.md  src\nyou@mac project % ") == nil)
    }

    @Test func aRuleIsNotALogo() {
        let screen = String(repeating: "▀", count: 80) + "\n> type here\n" + String(repeating: "▄", count: 80)
        #expect(LogoExtractor.extract(screen) == nil)
    }

    @Test func roundTripKeepsColours() {
        let rows = LogoExtractor.parse("\u{1B}[38;2;1;2;3m▄\u{1B}[48;5;9m▀\u{1B}[0m")
        let lines = LogoExtractor.serialize(rows)
        #expect(LogoExtractor.parse(lines[0]) == rows)
    }
}

@Suite("What isn't a logo")
struct LogoFalsePositiveTests {
    @Test func statusLinesAreNotLogos() {
        #expect(LogoExtractor.extract("\u{1B}[38;5;114m[✔]\u{1B}[0m radar loaded\n\u{1B}[38;5;114m[✔]\u{1B}[0m clips loaded") == nil)
        #expect(LogoExtractor.extract("\u{1B}[32m✓\u{1B}[0m Done installing") == nil)
    }

    @Test func menuCursorsAreNotLogos() {
        #expect(LogoExtractor.extract(" \u{1B}[36m❯\u{1B}[0m No, exit\n   Yes, I trust this folder") == nil)
        #expect(LogoExtractor.extract("\u{1B}[1;36m›\u{1B}[0m Ask Codex to do anything") == nil)
    }

    @Test func brailleArtIsALogo() throws {
        let screen = "  ⣀⣤⣤⣀\n ⣼⣿⠿⠿⣿⣧\n ⢻⣿⣶⣶⣿⡟\n  ⠉⠛⠛⠉\n  Welcome to Something"
        let logo = try #require(LogoExtractor.extract(screen))
        #expect(logo.source == "art")
        #expect(logo.mark.count == 4)
    }
}
