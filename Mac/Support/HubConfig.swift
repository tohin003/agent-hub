import Foundation
import Security

/// Where the hub keeps its files: ~/.agenthub (owner-only).
enum HubPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let root = "\(home)/.agenthub"
    static let token = "\(root)/token"
    static let config = "\(root)/config.json"
    static let sessions = "\(root)/sessions.json"
    static let events = "\(root)/events"
    static let attach = "\(root)/attach"
    static let launch = "\(root)/launch"
    static let uploads = "\(root)/uploads"
    static let bin = "\(root)/bin"
    static let hookScript = "\(root)/bin/agenthub-hook"
    static let claudeSettings = "\(root)/claude-hooks.json"
    static let tmuxConf = "\(root)/tmux.conf"
    static let renewState = "\(root)/renew/state.json"
    static let renewLock = "\(root)/renew/lock"
    /// Present while automatic renewal is switched off (renew-check.sh then does nothing).
    static let renewAutoOff = "\(root)/renew/auto-off"

    static func prepare() {
        let fm = FileManager.default
        for dir in [root, events, attach, launch, uploads, bin, "\(root)/renew"] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
    }
}

/// The hub's settings, kept in ~/.agenthub/config.json. Missing keys take their defaults, and accounts the person
/// hasn't configured are detected from their shell setup (claude, claude-w, claude-p, codex, agy, opencode...).
struct HubConfig: Codable {
    var port: Int = WireProtocol.defaultPort
    /// Also listen on the Mac's LAN addresses (the tailnet and this Mac are always on).
    var listenOnLAN: Bool = false
    /// Accept connections only from tailnet devices signed in as the same person as this Mac.
    var requireSameTailnetUser: Bool = true
    var terminalApp: String = "Terminal"
    var accounts: [Account] = []
    var recentFolders: [String] = []
    /// The Agent Hub repository, so the hub can run its renewal script.
    var repoPath: String?
    /// ntfy topic URL for alerts while the phone app is closed (e.g. https://ntfy.sh/my-secret-topic).
    var ntfyURL: String?
    /// The live screen in the app: when off, the hub doesn't capture the screen at all.
    var screenSharing: Bool = true

    static func load() -> HubConfig {
        var config = HubConfig()
        if let data = FileManager.default.contents(atPath: HubPaths.config),
           let decoded = try? JSONDecoder().decode(HubConfig.self, from: data) {
            config = decoded
        }
        config.accounts = AccountDetector.merge(configured: config.accounts)
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        let url = URL(fileURLWithPath: HubPaths.config)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? WireProtocol.defaultPort
        listenOnLAN = try c.decodeIfPresent(Bool.self, forKey: .listenOnLAN) ?? false
        requireSameTailnetUser = try c.decodeIfPresent(Bool.self, forKey: .requireSameTailnetUser) ?? true
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? "Terminal"
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        recentFolders = try c.decodeIfPresent([String].self, forKey: .recentFolders) ?? []
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
        ntfyURL = try c.decodeIfPresent(String.self, forKey: .ntfyURL)
        screenSharing = try c.decodeIfPresent(Bool.self, forKey: .screenSharing) ?? true
    }
}

/// The pairing token: 32 random bytes, hex, in ~/.agenthub/token (0600). The iPhone build carries the same token.
enum PairingToken {
    static func loadOrCreate() -> String {
        if let data = FileManager.default.contents(atPath: HubPaths.token) {
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 32 { return value }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: HubPaths.token, contents: Data((token + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}

/// Finds the person's agent accounts from what is installed and how their shell names them: each CLI under its own
/// name, plus every shell function or alias named after one with a suffix ("claude-work", "codex-2", "opencode-p"),
/// with the data folder that function points the CLI at (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_DATA_HOME`).
enum AccountDetector {
    static func defaults() -> [Account] {
        let home = HubPaths.home
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        let shell = ShellDefinitions.read(home: home)
        let claudeBinary = findCLI("claude") != nil || exists("\(home)/.claude/local")

        var accounts: [Account] = []
        accounts.append(Account(id: "claude", name: "Claude", provider: .claude, command: "claude",
                                dataDir: "\(home)/.claude", badge: nil, available: claudeBinary, detail: nil))
        accounts += extraAccounts(shell, base: "claude", provider: .claude, title: "Claude", variable: "CLAUDE_CONFIG_DIR",
                                  home: home) { $0 }
        accounts.append(Account(id: "codex", name: "Codex", provider: .codex, command: "codex",
                                dataDir: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex",
                                badge: nil, available: exists("\(home)/.codex") || findCLI("codex") != nil,
                                detail: nil))
        accounts += extraAccounts(shell, base: "codex", provider: .codex, title: "Codex", variable: "CODEX_HOME",
                                  home: home) { $0 }
        accounts.append(Account(id: "agy", name: "Antigravity", provider: .antigravity, command: "agy",
                                dataDir: "\(home)/.gemini/antigravity-cli", badge: nil,
                                available: findCLI("agy") != nil, detail: nil))
        accounts.append(Account(id: "opencode", name: "OpenCode", provider: .opencode, command: "opencode",
                                dataDir: "\(home)/.local/share/opencode", badge: nil,
                                available: findCLI("opencode") != nil, detail: nil))
        accounts += extraAccounts(shell, base: "opencode", provider: .opencode, title: "OpenCode", variable: "XDG_DATA_HOME",
                                  home: home) { "\($0)/opencode" }
        if findCLI("gemini") != nil {
            accounts.append(Account(id: "gemini", name: "Gemini CLI", provider: .gemini, command: "gemini",
                                    dataDir: "\(home)/.gemini", badge: nil, available: true, detail: nil))
        }
        // Other terminal agents, when installed: they run in the terminal view and show their own logo.
        let others: [(String, String)] = [
            ("aider", "Aider"), ("goose", "Goose"), ("amp", "Amp"), ("cursor-agent", "Cursor Agent"), ("crush", "Crush"),
            ("qwen", "Qwen Code"), ("kimi", "Kimi CLI"), ("droid", "Droid"), ("copilot", "GitHub Copilot CLI"),
            ("kiro-cli", "Kiro"), ("auggie", "Augment"), ("cline", "Cline"),
        ]
        for (binary, name) in others where findCLI(binary) != nil {
            accounts.append(Account(id: binary, name: name, provider: .other, command: binary, dataDir: nil, badge: nil,
                                    available: true, detail: nil))
        }
        accounts.append(Account(id: "shell", name: "Terminal", provider: .shell, command: "", dataDir: nil, badge: nil,
                                available: true, detail: "A plain shell in the folder"))
        return accounts
    }

    /// "claude-work", "claude-p": the accounts the person's shell defines for a CLI. Each is named after the data
    /// folder it points the CLI at when that says more ("~/.claude-work" → "Claude · Work"), else after its suffix.
    static func extraAccounts(_ shell: [String: String], base: String, provider: ProviderKind, title: String,
                              variable: String, home: String, dataFolder: (String) -> String) -> [Account] {
        shell.keys.filter { $0.hasPrefix(base + "-") && $0.count > base.count + 1 }.sorted().compactMap { name in
            let suffix = String(name.dropFirst(base.count + 1))
            // A separate account points the CLI at its own data folder; a tool that merely shares the name doesn't.
            guard let folder = ShellDefinitions.value(of: variable, in: shell[name] ?? "", home: home) else { return nil }
            let label = folder.split(separator: "/").lazy.compactMap { part -> String? in
                let part = part.hasPrefix(".") ? part.dropFirst() : part[...]
                guard part.hasPrefix(base + "-") else { return nil }
                return String(part.dropFirst(base.count + 1))
            }.first ?? suffix
            return Account(id: name, name: "\(title) · \(label.prefix(1).uppercased() + label.dropFirst())", provider: provider,
                           command: name, dataDir: dataFolder(folder), badge: String(suffix.prefix(1)).uppercased(),
                           available: true, detail: nil)
        }
    }

    /// Looks for a CLI in the usual places, including global npm installs under nvm.
    static func findCLI(_ name: String) -> String? {
        if let path = Shell.which(name) { return path }
        let nvm = "\(HubPaths.home)/.nvm/versions/node"
        for version in (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [] {
            let path = "\(nvm)/\(version)/bin/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Configured accounts win; detected ones the config doesn't mention are added after them.
    static func merge(configured: [Account]) -> [Account] {
        var result = configured
        let known = Set(configured.map(\.id))
        for account in defaults() where !known.contains(account.id) {
            result.append(account)
        }
        return result
    }
}

/// The functions and aliases the person's shell defines (its rc files, and the files they source), by name, with
/// their bodies.
enum ShellDefinitions {
    static func read(home: String) -> [String: String] {
        var texts: [String] = []
        var seen: Set<String> = []
        func load(_ path: String, depth: Int) {
            guard depth < 3, seen.insert(path).inserted,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            texts.append(text)
            for line in text.split(separator: "\n") {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard words.count == 2, words[0] == "source" || words[0] == "." else { continue }
                let target = expand(String(words[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), home: home)
                if target.hasPrefix(home) { load(target, depth: depth + 1) }
            }
        }
        for file in [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"] {
            load("\(home)/\(file)", depth: 0)
        }
        return parse(texts.joined(separator: "\n"))
    }

    private static let function = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:function[ \t]+)?([A-Za-z0-9_.-]+)[ \t]*(?:\(\))?[ \t]*\{"#)
    private static let alias = try! NSRegularExpression(pattern: #"(?m)^[ \t]*alias[ \t]+([A-Za-z0-9_.-]+)=(['"])(.*?)\2"#)

    /// `name() { … }`, `function name { … }` (the body up to its matching brace), `alias name='…'`.
    static func parse(_ text: String) -> [String: String] {
        var found: [String: String] = [:]
        let ns = text as NSString
        for match in function.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let declaration = ns.substring(with: match.range)
            // "name {" only counts with the function keyword, "name() {" either way.
            guard declaration.contains("()") || declaration.contains("function") else { continue }
            let name = ns.substring(with: match.range(at: 1))
            var depth = 1
            var index = match.range.location + match.range.length
            let start = index
            while index < ns.length, depth > 0 {
                let character = ns.character(at: index)
                if character == 123 { depth += 1 } else if character == 125 { depth -= 1 }
                index += 1
            }
            found[name] = ns.substring(with: NSRange(location: start, length: max(0, index - start - 1)))
        }
        for match in alias.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            found[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 3))
        }
        return found
    }

    /// `VARIABLE=…` in a body, with ~ and $HOME expanded.
    static func value(of variable: String, in body: String, home: String) -> String? {
        let pattern = "\\b\(variable)=(\"([^\"]*)\"|'([^']*)'|([^\\s;]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = body as NSString
        guard let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return expand(ns.substring(with: match.range(at: group)), home: home)
        }
        return nil
    }

    static func expand(_ path: String, home: String) -> String {
        var path = path
        for token in ["${HOME}", "$HOME"] { path = path.replacingOccurrences(of: token, with: home) }
        if path == "~" { return home }
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        return path
    }
}
