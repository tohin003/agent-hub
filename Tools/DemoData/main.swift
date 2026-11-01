// Writes a made-up Mac for screenshots (Agent Hub's `-demo <file>`): a few agents at work, one waiting for an
// approval, a conversation with its tools, usage and models. The agents' logos and model lists are read from this
// Mac's hub (~/.agenthub), so they are the real ones; everything else is invented. Run by scripts/screenshots.sh.
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let now = Date()
func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }

// MARK: Accounts, with the logos the hub read off each CLI

func logo(_ id: String) -> TerminalLogo? {
    guard let data = FileManager.default.contents(atPath: "\(home)/.agenthub/logos/\(id).json") else { return nil }
    return try? WireCoding.decoder.decode(TerminalLogo.self, from: data)
}

let accounts: [Account] = [
    Account(id: "claude-w", name: "Claude · Work", provider: .claude, command: "claude-w", dataDir: nil, badge: "W",
            available: true, detail: nil, logo: logo("claude-w") ?? logo("claude")),
    Account(id: "claude-p", name: "Claude · Personal", provider: .claude, command: "claude-p", dataDir: nil, badge: "P",
            available: true, detail: nil, logo: logo("claude-p") ?? logo("claude")),
    Account(id: "codex", name: "Codex", provider: .codex, command: "codex", dataDir: nil, badge: nil, available: true,
            detail: nil, logo: logo("codex")),
    Account(id: "opencode", name: "OpenCode", provider: .opencode, command: "opencode", dataDir: nil, badge: nil,
            available: true, detail: nil, logo: logo("opencode")),
    Account(id: "agy", name: "Antigravity", provider: .antigravity, command: "agy", dataDir: nil, badge: nil,
            available: true, detail: nil, logo: logo("agy")),
    Account(id: "gemini", name: "Gemini CLI", provider: .gemini, command: "gemini", dataDir: nil, badge: nil,
            available: true, detail: nil, logo: logo("gemini")),
    Account(id: "shell", name: "Terminal", provider: .shell, command: "", dataDir: nil, badge: nil, available: true,
            detail: "A plain shell in the folder"),
]

// MARK: Sessions

let reset = Calendar.current.date(bySettingHour: 22, minute: 30, second: 0, of: now) ?? now.addingTimeInterval(3 * 3600)
let week = now.addingTimeInterval(4 * 86_400)

var landing = SessionInfo(id: "demo-landing", accountId: "claude-w", provider: .claude, title: "Landing page redesign",
                          cwd: "/Users/you/Projects/acme-web", createdAt: ago(3600), lastActivity: ago(20), state: .working,
                          stateDetail: "Writing the hero section… (1m 12s · ↑ 3.4k tokens)", hasWindow: true,
                          transcriptAvailable: true, model: "claude-opus-5-5", permissionMode: "acceptEdits",
                          gitBranch: "redesign", runningTasks: 2,
                          lastMessage: "Redesign the landing page hero: one headline, a live demo, one call to action.")
landing.usage = SessionUsage(contextTokens: 412_300, contextWindow: 1_000_000, contextPercent: 41.2,
                             limits: [UsageLimit(name: "Current session", percent: 38, resetsAt: reset),
                                      UsageLimit(name: "Current week", percent: 12, resetsAt: week)],
                             modelName: "Opus 5.5", effort: "high")

var auth = SessionInfo(id: "demo-auth", accountId: "codex", provider: .codex, title: "Fix flaky auth tests",
                       cwd: "/Users/you/Projects/acme-api", createdAt: ago(1800), lastActivity: ago(45), state: .waiting,
                       hasWindow: true, transcriptAvailable: true, model: "gpt-6.1-sol", gitBranch: "fix/auth-flake",
                       lastMessage: "The login test fails one run in ten. Find out why and fix it.")
auth.attention = AttentionPrompt(
    signature: "demo-auth-1", kind: .choice, question: "Would you like to run the following command?",
    context: "Reason: run the auth suite to confirm the race is gone\n\n$ npm test -- --runInBand auth",
    options: [
        AttentionOption(index: 1, label: "Yes, proceed (y)"),
        AttentionOption(index: 2, label: "Yes, and don't ask again for this command (a)"),
        AttentionOption(index: 3, label: "No, and tell Codex what to do differently (esc)"),
    ],
    selectedIndex: 1, hint: "Press enter to confirm or esc to cancel",
    keyActions: [KeyAction(keys: ["Enter"], label: "Confirm", keyName: "return"),
                 KeyAction(keys: ["Escape"], label: "Cancel", keyName: "esc")])
auth.usage = SessionUsage(contextTokens: 109_000, contextWindow: 475_000, contextPercent: 23,
                          limits: [UsageLimit(name: "5-hour limit", percent: 21, resetsAt: reset),
                                   UsageLimit(name: "Weekly limit", percent: 9, resetsAt: week)],
                          modelName: "GPT-6.1-Sol", effort: "medium")

var limiter = SessionInfo(id: "demo-limiter", accountId: "claude-p", provider: .claude, title: "API rate limiter",
                          cwd: "/Users/you/Projects/acme-api", createdAt: ago(7200), lastActivity: ago(840), state: .idle,
                          hasWindow: false, transcriptAvailable: true, model: "claude-sonnet-5-5", gitBranch: "main",
                          lastMessage: "Added a token-bucket limiter with tests. All 48 pass.")
limiter.usage = SessionUsage(contextTokens: 61_000, contextWindow: 1_000_000, contextPercent: 6.1, modelName: "Sonnet 5.5",
                             effort: "medium")

var notes = SessionInfo(id: "demo-notes", accountId: "opencode", provider: .opencode, title: "Release notes for 2.4",
                        cwd: "/Users/you/Projects/acme-web", createdAt: ago(900), lastActivity: ago(5), state: .working,
                        stateDetail: "Reading the changelog…", hasWindow: true, transcriptAvailable: true,
                        model: "claude-sonnet-5-5", lastMessage: "Draft the release notes for 2.4 from the merged PRs.")
notes.usage = SessionUsage(contextTokens: 38_400, contextWindow: 200_000, contextPercent: 19.2)

let onboarding = SessionInfo(id: "demo-onboarding", accountId: "agy", provider: .antigravity, title: "Mobile onboarding flow",
                             cwd: "/Users/you/Projects/acme-ios", createdAt: ago(10_800), lastActivity: ago(2400),
                             state: .idle, hasWindow: false, transcriptAvailable: false,
                             lastMessage: "Three screens, skippable, with the new illustrations.")

let sessions = [auth, landing, notes, limiter, onboarding]

// MARK: Conversations

var counter = 0
func item(_ kind: TimelineItem.Kind, _ text: String? = nil, tool: ToolCall? = nil, at seconds: Double) -> TimelineItem {
    counter += 1
    return TimelineItem(id: "demo-\(counter)", kind: kind, timestamp: ago(seconds), text: text, tool: tool)
}

func tool(_ name: String, _ category: ToolCall.Category, _ title: String, _ subtitle: String? = nil,
          status: ToolCall.Status = .done, output: String? = nil, diff: FileDiff? = nil, todos: [TodoItem]? = nil,
          agentId: String? = nil) -> ToolCall {
    counter += 1
    var call = ToolCall(id: "tool-\(counter)", name: name, category: category, title: title, input: nil, status: status)
    call.subtitle = subtitle
    call.output = output
    call.diff = diff
    call.todos = todos
    call.agentId = agentId
    return call
}

let heroDiff = FileDiff(path: "components/Hero.tsx", lines: [
    DiffLine(kind: .hunk, text: "@@ -12,9 +12,14 @@ export function Hero() {"),
    DiffLine(kind: .context, text: "  return ("),
    DiffLine(kind: .remove, text: "    <section className=\"hero hero--split\">"),
    DiffLine(kind: .add, text: "    <section className=\"hero\" aria-labelledby=\"hero-title\">"),
    DiffLine(kind: .remove, text: "      <h1>Build faster with Acme</h1>"),
    DiffLine(kind: .add, text: "      <h1 id=\"hero-title\">Ship your idea this week.</h1>"),
    DiffLine(kind: .add, text: "      <DemoVideo src=\"/demo.webm\" loading=\"lazy\" />"),
    DiffLine(kind: .add, text: "      <Button size=\"lg\">Start free</Button>"),
    DiffLine(kind: .context, text: "    </section>"),
], additions: 38, deletions: 21, isNewFile: false)

let landingTimeline: [TimelineItem] = [
    item(.user, "Redesign the landing page hero: one bigger headline, a live demo of the app, and a single call to action. Keep it fast on phones.", at: 600),
    item(.thinking, "The hero lives in components/Hero.tsx and pulls its spacing from tokens.css. The current version splits attention between two buttons and a carousel…", at: 590),
    item(.assistant, "I'll read the current hero and the design tokens first, then rework the layout.", at: 585),
    item(.tool, tool: tool("Read", .read, "Read Hero.tsx", "components/Hero.tsx"), at: 580),
    item(.tool, tool: tool("Grep", .search, "Search for cta-button", "components/"), at: 575),
    item(.tool, tool: tool("TodoWrite", .todo, "Updated the to-do list", todos: [
        TodoItem(content: "Rework the hero layout", status: .completed),
        TodoItem(content: "Add the live demo, loaded lazily", status: .inProgress),
        TodoItem(content: "Keep one call to action", status: .pending),
        TodoItem(content: "Check Lighthouse on mobile", status: .pending),
    ]), at: 570),
    item(.tool, tool: tool("Edit", .edit, "Edit Hero.tsx", "components/Hero.tsx", diff: heroDiff), at: 420),
    item(.tool, tool: tool("Bash", .shell, "Run the hero's unit tests", "npm test -- hero",
                           output: "PASS  components/Hero.test.tsx\n  ✓ renders one call to action (14 ms)\n  ✓ loads the demo lazily (9 ms)\n\nTests: 6 passed, 6 total"), at: 300),
    item(.tool, tool: tool("Agent", .agent, "Review the hero for accessibility", "general-purpose", agentId: "demo-a11y"), at: 240),
    item(.assistant, """
    The hero now leads with **one headline and one button**, and the demo only loads once it scrolls into view:

    - Headline: 56 pt on desktop, 34 pt on phones
    - One call to action: *Start free*
    - The demo is a 380 KB WebM instead of a 4 MB GIF

    Next I'm checking Lighthouse on mobile.
    """, at: 120),
    item(.tool, tool: tool("Bash", .shell, "Lighthouse on mobile", "npx lighthouse http://localhost:3000 --preset=mobile",
                           status: .background), at: 60),
]

let authTimeline: [TimelineItem] = [
    item(.user, "The login test fails one run in ten. Find out why and fix it.", at: 1500),
    item(.tool, tool: tool("shell", .shell, "Ran the auth tests 20 times", "for i in $(seq 20); do npm test -- auth || break; done",
                           output: "✗ login › refreshes an expired session (run 7)\n  Expected 200, received 401"), at: 1400),
    item(.tool, tool: tool("read", .read, "Read session.ts", "src/auth/session.ts"), at: 1300),
    item(.assistant, "Found it: the refresh timer and the request share a clock, so a token that expires **during** the request is refreshed after it's sent. I've made the refresh happen before the request instead.", at: 900),
    item(.tool, tool: tool("apply_patch", .edit, "Edit session.ts", "src/auth/session.ts",
                           diff: FileDiff(path: "src/auth/session.ts", lines: [
                               DiffLine(kind: .hunk, text: "@@ -41,6 +41,9 @@ export async function authorized(request) {"),
                               DiffLine(kind: .add, text: "  if (token.expiresIn() < REFRESH_MARGIN) {"),
                               DiffLine(kind: .add, text: "    await refresh(token)"),
                               DiffLine(kind: .add, text: "  }"),
                               DiffLine(kind: .context, text: "  return send(request, token)"),
                           ], additions: 3, deletions: 0, isNewFile: false)), at: 600),
]

let limiterTimeline: [TimelineItem] = [
    item(.user, "Add rate limiting to the public API: 100 requests a minute per key, with a clear error.", at: 3000),
    item(.tool, tool: tool("Write", .write, "Write rateLimit.ts", "src/middleware/rateLimit.ts"), at: 2600),
    item(.tool, tool: tool("Bash", .shell, "Run the API tests", "npm test", output: "Tests: 48 passed, 48 total"), at: 1200),
    item(.assistant, "Added a token-bucket limiter with tests. All 48 pass. Requests over the limit get a **429** with a `Retry-After` header.", at: 840),
]

let tasks: [String: [BackgroundTask]] = [
    "demo-landing": [
        BackgroundTask(id: "t1", kind: .shell, title: "Lighthouse on mobile", detail: "npx lighthouse --preset=mobile",
                       status: .running, startedAt: ago(60)),
        BackgroundTask(id: "t2", kind: .agent, title: "Review the hero for accessibility", detail: "general-purpose",
                       status: .running, startedAt: ago(240)),
    ],
]

// MARK: Models and usage, as this Mac's agents list them

func catalog(_ id: String) -> ModelCatalog? {
    guard let data = FileManager.default.contents(atPath: "\(home)/.agenthub/models/\(id).json"),
          var catalog = try? WireCoding.decoder.decode(ModelCatalog.self, from: data) else { return nil }
    catalog.accountId = id
    return catalog
}

func codexCatalog() -> ModelCatalog? {
    guard let data = FileManager.default.contents(atPath: "\(home)/.codex/models_cache.json"),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]] else { return nil }
    let options = models.filter { ($0["visibility"] as? String ?? "list") == "list" }.prefix(6).enumerated().map { index, model in
        ModelOption(number: index + 1, label: model["display_name"] as? String ?? "Model", detail: model["description"] as? String,
                    slug: model["slug"] as? String,
                    effortLevels: (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String })
    }
    return ModelCatalog(accountId: "codex", options: Array(options), effortLevels: ["low", "medium", "high", "xhigh", "max"],
                        source: "cache", capturedAt: now)
}

var catalogs: [String: ModelCatalog] = [:]
if let claude = catalog("claude-w") ?? catalog("claude") {
    catalogs["claude-w"] = claude
    var personal = claude
    personal.accountId = "claude-p"
    catalogs["claude-p"] = personal
}
if let codex = codexCatalog() { catalogs["codex"] = codex }

let usage: [String: AccountUsage] = [
    "claude-w": AccountUsage(accountId: "claude-w",
                             limits: [UsageLimit(name: "Current session", percent: 38, resetsAt: reset),
                                      UsageLimit(name: "Current week (all models)", percent: 12, resetsAt: week)],
                             notes: ["You are currently using your subscription to power your Claude Code usage"],
                             sections: [UsageSection(title: "Last 24h · 1,284 requests · 9 sessions", lines: [
                                 UsageLine(percent: 61, text: "Start fresh when you switch tasks · run /clear"),
                                 UsageLine(percent: 34, text: "Save max effort for hard tasks"),
                                 UsageLine(percent: nil, text: "Top subagents: general-purpose 22%"),
                             ])],
                             fetchedAt: now),
]

let hub = HubInfo(macName: "MacBook Pro", user: "you", version: "1.0", tailscaleName: "macbook-pro.tail-demo.ts.net",
                  tailscaleIP: "100.101.102.103", port: 7860, screenRecording: true, accessibility: true,
                  tmuxPath: "/opt/homebrew/bin/tmux", terminalApp: "Terminal",
                  renewal: RenewalInfo(installedAt: ago(86_400), expiresAt: now.addingTimeInterval(6 * 86_400),
                                       lastAttempt: ago(86_400), lastResult: "Installed; signed for 7 days.",
                                       lastSucceeded: true, running: false, autoRenew: true, lastReason: "auto"),
                  clients: 1, screenSharing: true)

let snapshot = DemoSnapshot(hub: hub, accounts: accounts, sessions: sessions,
                            timelines: ["demo-landing": landingTimeline, "demo-auth": authTimeline, "demo-limiter": limiterTimeline],
                            tasks: tasks, catalogs: catalogs, usage: usage)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.json"
try WireCoding.encoder.encode(snapshot).write(to: URL(fileURLWithPath: out))
print("wrote \(out): \(sessions.count) sessions, \(catalogs.count) model lists, \(accounts.filter { $0.logo != nil }.count) logos")
