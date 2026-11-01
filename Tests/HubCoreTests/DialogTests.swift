import Foundation
import Testing

/// Dialogs captured from the real CLIs on this Mac (Claude Code 2.1.316), and layouts read from their source.
@Suite("Claude Code's pickers and questions")
struct ClaudeDialogTests {
    /// `/model`: descriptions in a second column, ✔ on the current model, a list that scrolls, effort under it.
    @Test func modelPicker() throws {
        let pane = """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach for focus tracking ▔
           Select model
           Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names,
           specify with --model.
             1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
           ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks
             3.  Fable 5.1              For your toughest challenges
             4.  Sonnet 5.5             Most efficient for simpler tasks
             5.  Haiku 5.5              Fastest for quick answers
             6.  Haiku 4.5              Fastest for quick answers
             7.  Sonnet 5               Efficient for routine tasks
             8.  Opus 5                 Best for everyday, complex tasks
             9.  Fable 5                Most capable for your hardest and longest-running tasks
           ↓ 10. Opus 4.8               Best for everyday, complex tasks
              … +3 models
           ◐ Medium effort (default) ←/→ to adjust
           Enter to set as default · s to use this session only · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.question == "Select model")
        #expect(prompt.options.count == 10)
        #expect(prompt.options[0].label == "Default (recommended)")
        #expect(prompt.options[0].detail == "Opus 5.5 · Best for everyday, complex tasks")
        #expect(prompt.options[1].label == "Opus 5.5")
        #expect(prompt.options[1].detail == "For complex work and everyday tasks")
        #expect(prompt.options[1].isCurrent == true)
        #expect(prompt.options[9].label == "Opus 4.8")
        #expect(prompt.options[9].index == 10)
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.footer?.contains("… +3 models") == true)
        #expect(prompt.footer?.contains("Medium effort") == true)
        #expect(PaneReader.effortWord(prompt) == "medium")
        let keys = (prompt.keyActions ?? []).map(\.keyName)
        #expect(keys.contains("s"))
        #expect(keys.contains("◀") && keys.contains("▶"))
        #expect(prompt.keyActions?.first { $0.keyName == "s" }?.label == "Use this session only")
    }

    /// `/effort`: a slider, the level under ▲ is the current one.
    @Test func effortSlider() throws {
        let pane = """
           Effort
                                     Faster                             Smarter
                                     ──────────▲───────────────────────────────      Ultracode  off
                                     low     medium     high     xhigh      max      Tab to toggle
                                                    The default effort for this model
           ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.horizontal == true)
        #expect(prompt.question == "Effort")
        #expect(prompt.options.map(\.label) == ["low", "medium", "high", "xhigh", "max"])
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.footer?.contains("Ultracode off") == true)
        let keys = (prompt.keyActions ?? []).map(\.keyName)
        #expect(keys.contains("◀") && keys.contains("▶") && keys.contains("s") && keys.contains("tab"))
    }

    /// AskUserQuestion with "Chat about this" under a divider and the free-text option, cursor on the chat line.
    @Test func questionWithChatAndTypedAnswer() throws {
        let pane = """
           ←  ☐ Framework  ✔ Submit  →

          Which framework should we use?

            1. React
               Popular component library
            2. Vue
               Progressive framework
            3. Type something.
          ────────────────────────────────────────
          ❯ Chat about this

          Enter to select · ↑/↓ to navigate · Tab to switch questions · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.question == "Which framework should we use?")
        #expect(prompt.options.map(\.label) == ["React", "Vue", "Type something.", "Chat about this"])
        #expect(prompt.options[0].detail == "Popular component library")
        #expect(prompt.options[2].takesText == true)
        #expect(prompt.selectedIndex == 4)
    }

    /// The same question with the cursor on an answer.
    @Test func questionCursorOnAnswer() throws {
        let pane = """
          Which framework should we use?

          ❯ 1. React
               Popular component library
            2. Vue
               Progressive framework
            3. Type something.
          ────────────────────────────────────────
            Chat about this

          Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["React", "Vue", "Type something.", "Chat about this"])
        #expect(prompt.selectedIndex == 1)
    }

    /// The survey after a turn: digits answer it, and nothing waits on it.
    @Test func sessionSurvey() throws {
        let pane = """
        ● Done. The tests pass.

        ● How is Claude doing this session? (optional)
          1: Bad    2: Fine   3: Good   0: Dismiss

        ────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────
        """
        let reading = PaneReader.read(pane)
        let prompt = try #require(reading.prompt)
        #expect(prompt.optional == true)
        #expect(prompt.question == "How is Claude doing this session? (optional)")
        #expect(prompt.options.map(\.label) == ["Bad", "Fine", "Good", "Dismiss"])
        #expect(prompt.options.map { $0.keys ?? [] } == [["1"], ["2"], ["3"], ["0"]])
    }
}

@Suite("Usage, as the agents report it")
struct UsageTests {
    /// `claude -p /usage`, as printed on this Mac (with the shell's own session lines around it).
    @Test func claudeUsageText() throws {
        let text = """
        Restored session: Sun Nov  1 19:23:39 IST 2026
        You are currently using your subscription to power your Claude Code usage

        Current session: 38% used · resets Nov 1 at 10:30pm (Asia/Calcutta)
        Current week (Fable): 0% used · resets Nov 6 at 7:30am (Asia/Calcutta)

        What's contributing to your usage?
        Approximate · sessions on this machine only · shares overlap

        Last 24h · 2138 requests · 20 sessions
          90%  Start fresh when you switch tasks · run /clear
          51%  Save max effort for hard tasks
          Top skills: /axiom-networking 13%, /launch-film-craft 8%

        Last 7d · 29639 requests · 47 sessions
          95%  Save max effort for hard tasks

        Saving session...
        ...completed.
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Calcutta")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 19, minute: 24))!
        let usage = ClaudeUsageText.parse(text, accountId: "claude", now: now)
        #expect(usage.limits.map(\.name) == ["Current session", "Current week (Fable)"])
        #expect(usage.limits.map(\.percent) == [38, 0])
        let reset = try #require(usage.limits[0].resetsAt)
        #expect(calendar.dateComponents([.month, .day, .hour, .minute], from: reset)
            == DateComponents(month: 11, day: 1, hour: 22, minute: 30))
        #expect(usage.notes.first == "You are currently using your subscription to power your Claude Code usage")
        #expect(usage.notes.contains("Approximate · sessions on this machine only · shares overlap"))
        #expect(usage.sections.map(\.title) == ["Last 24h · 2138 requests · 20 sessions", "Last 7d · 29639 requests · 47 sessions"])
        #expect(usage.sections[0].lines.first == UsageLine(percent: 90, text: "Start fresh when you switch tasks · run /clear"))
        #expect(usage.sections[0].lines.last?.percent == nil)
    }

    /// What Claude Code hands its status line.
    @Test func claudeStatusLine() throws {
        let json = """
        {"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"total_input_tokens":964500,
        "total_output_tokens":120,"context_window_size":1000000,"used_percentage":96.45,"remaining_percentage":3.55},
        "effort":{"level":"max"},"cost":{"total_cost_usd":12.5},
        "rate_limits":{"five_hour":{"used_percentage":31,"resets_at":1793034000},"seven_day":{"used_percentage":4,"resets_at":1793430000}}}
        """
        let usage = try #require(ClaudeStatus.usage(from: Data(json.utf8)))
        #expect(usage.contextTokens == 964_500)
        #expect(usage.contextWindow == 1_000_000)
        #expect(usage.contextPercent == 96.45)
        #expect(usage.modelName == "Opus 5.5")
        #expect(usage.effort == "max")
        #expect(usage.limits.map(\.name) == ["Current session", "Current week"])
        #expect(usage.limits[0].resetsAt == Date(timeIntervalSince1970: 1_793_034_000))
    }

    /// Codex's token count event, as in its rollouts.
    @Test func codexTokenCount() throws {
        let event: [String: Any] = [
            "type": "token_count",
            "info": ["last_token_usage": ["total_tokens": 192_629], "model_context_window": 475_000],
            "rate_limits": ["primary": ["used_percent": 13.0, "window_minutes": 300, "resets_at": 1_793_012_989],
                            "secondary": ["used_percent": 2.0, "window_minutes": 10_080, "resets_at": 1_793_599_789]],
        ]
        let usage = try #require(CodexTranscript.usage(event, stamp: nil))
        #expect(usage.contextTokens == 192_629)
        #expect(usage.contextWindow == 475_000)
        #expect(usage.limits.map(\.name) == ["5-hour limit", "Weekly limit"])
        #expect(usage.limits.map(\.percent) == [13, 2])
    }

    @Test func emptyMessageBox() {
        let pane = """
        ● Done.

        ────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────
          ⏵⏵ auto mode on · 1 shell · ↓ to manage
        """
        #expect(PaneReader.inputDraft(plain: pane) == nil)
    }

    @Test func draftInMessageBox() {
        let pane = """
        ────────────────────────────────────────────
        ❯ please also fix the
          login page
        ────────────────────────────────────────────
        """
        #expect(PaneReader.inputDraft(plain: pane) == "please also fix the login page")
        // The same line drawn grey is a placeholder hint.
        let styled = "────\n\u{1B}[39m❯ \u{1B}[2mplease also fix the\u{1B}[22m\n  login page\n────"
        #expect(PaneReader.inputDraft(plain: pane, styled: styled) == nil)
    }

    @Test func modelConfirmationLine() throws {
        let one = try #require(PaneReader.modelConfirmation("  ⎿  Set model to Sonnet 5.5 for this session only with low effort"))
        #expect(one.model == "Sonnet 5.5" && one.effort == "low")
        let two = try #require(PaneReader.modelConfirmation(
            "  ⎿  Set model to Opus 5.5 and saved as your default for new sessions · max effort for this session only"))
        #expect(two.model == "Opus 5.5" && two.effort == "max")
        let three = try #require(PaneReader.modelConfirmation("  ⎿  Set model to Opus 5.5 for this session only"))
        #expect(three.model == "Opus 5.5" && three.effort == nil)
    }
}

/// OpenCode draws its choice only as a background colour. Layouts from its source (1.18.21); colours made up.
@Suite("OpenCode's colour-only selections")
struct OpenCodeDialogTests {
    static let esc = "\u{1B}"
    static func bg(_ rgb: String) -> String { "\(esc)[48;2;\(rgb)m" }

    @Test func permissionButtons() throws {
        let panel = Self.bg("30;30;30"), accent = Self.bg("250;178;131"), reset = "\(Self.esc)[0m"
        let styled = [
            "\(panel)┃  △ Permission required\(reset)",
            "\(panel)┃    # Shell command\(reset)",
            "\(panel)┃\(reset)",
            "\(panel)┃   $ npm test\(reset)",
            "\(panel)┃\(reset)",
            "\(panel)┃   \(accent) Allow once \(panel)  Allow always   Reject        ⇆ select  enter confirm\(reset)",
        ].joined(separator: "\n")
        let plain = PaneReader.cleanEscapes(styled)
        #expect(PaneReader.wantsStyle(plain))
        let prompt = try #require(PaneReader.read(plain, styled: styled).prompt)
        #expect(prompt.horizontal == true)
        #expect(prompt.question == "Permission required")
        #expect(prompt.context?.contains("$ npm test") == true)
        #expect(prompt.options.map(\.label) == ["Allow once", "Allow always", "Reject"])
        #expect(prompt.selectedIndex == 1)
        // Moved to "Reject".
        let moved = styled.replacingOccurrences(of: "\(accent) Allow once \(panel)  Allow always   Reject ",
                                                with: " Allow once   Allow always  \(accent) Reject \(panel)")
        let again = try #require(PaneReader.read(PaneReader.cleanEscapes(moved), styled: moved).prompt)
        #expect(again.selectedIndex == 3)
        // Without the colours it isn't guessed.
        #expect(PaneReader.read(plain).prompt == nil)
    }

    /// The question tool: its cursor is only colour, so its digits answer it (they toggle a box, too).
    @Test func questionAnsweredByDigits() throws {
        let pane = """
        ┃   Which DB? (select all that apply)
        ┃
        ┃   1. [✓] Postgres
        ┃      fast relational
        ┃   2. [ ] SQLite
        ┃   3. [ ] Type your own answer
        ┃
        ┃   ⇆ tab  ↑↓ select  enter toggle  esc dismiss
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.kind == .yesNo)
        #expect(prompt.question == "Which DB? (select all that apply)")
        #expect(prompt.options.map(\.label) == ["Postgres", "SQLite", "Type your own answer"])
        #expect(prompt.options.map(\.checked) == [true, false, false])
        #expect(prompt.options.map { $0.keys ?? [] } == [["1"], ["2"], ["3"]])
        #expect(prompt.keyActions?.contains { $0.keyName == "esc" } == true)
    }

    /// Gemini's multiple choice: "●" is its cursor, "Done" sits under the list without a number.
    @Test func geminiChecklistWithDone() throws {
        let pane = """
         Answer Questions
         ← □ Stack │ ≡ Review →

         Which databases? (Select all that apply)
         ● 1. [x] Postgres
           2. [ ] SQLite
           3. All of the above
           4. Enter a custom value
           Done

         Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["Postgres", "SQLite", "All of the above", "Enter a custom value", "Done"])
        #expect(prompt.options[0].checked == true)
        #expect(prompt.options[3].takesText == true)
        #expect(prompt.options[4].isAction == true)
        #expect(prompt.selectedIndex == 1)
    }

    /// A numbered list in Claude's reply over its message box and footer ("↓ to manage") is not a question.
    @Test func numberedReplyOverClaudeFooterIsNotAQuestion() {
        let pane = """
        ⏺ radar: hooks.json changed — reloaded (modules: hooks/register.ts)
          1. hooks/register.ts
          2. hooks/session.ts
        usage ▸ 5h ▰▱▱▱▱ 18% · resets Mon 12:00 AM (in 3h 44m)  │  Fable week ▱▱▱▱▱ 0% · resets Thu 4:30 PM (in 3d 20h)  │  ctx 50%
        mac ▸ mem ▰▰▰▰▱ 6.0/8 GB ▆▆▆▆▆▆▆▆▆▇▆▆  swap 3.9 GB  │  disk 29.6 GB free ▂▂▂▂▂▂▂▅  │  load 9.23 ▄▄▄▄▄▆▆▆

        ──────────────────────────────────────────────────────────────────────────────────────────────────
        ❯
        ──────────────────────────────────────────────────────────────────────────────────────────────────
          ⏵⏵ auto mode on · 1 shell, 1 monitor · ↓ to manage
          ▸ mods 2/5 on
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }

    /// Claude Code's "/" menu, as captured on this Mac (descriptions wrap onto the next line).
    @Test func slashMenu() {
        let screen = """
          ❯ /dataviz                                     Chart and dashboard design guidance
            /vercel:react-best-practices                 (vercel) React best-practices reviewer for TSX files. Triggers
                                                         after editing multiple components
            /branch                                      Create a branch of the current conversation at this point
        usage ▸ 5h ▰▰▰▱▱ 67% · resets 10:30 PM (in 2h 9m)
        ──────────────────────────────────────────────────────────────
        ❯ /
        ──────────────────────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
        let items = PaneReader.slashMenu(screen)
        #expect(items.map(\.0) == ["/dataviz", "/vercel:react-best-practices", "/branch"])
        #expect(items[1].1 == "(vercel) React best-practices reviewer for TSX files. Triggers after editing multiple components")
        #expect(items[0].1 == "Chart and dashboard design guidance")
    }
}

/// Codex 0.166.0's pickers, captured on this Mac.
@Suite("Codex's model and effort pickers")
struct CodexPickerTests {
    @Test func modelList() throws {
        let pane = """
          Select Model and Effort
        › 1. GPT-6.1-Sol (current)  Latest workhorse model for coding and everyday work.
          2. GPT-6-Astra            Frontier intelligence for the most demanding work.
          3. GPT-6.1 Terra          GPT-6.1 Terra Codex model.
          4. GPT-6-Sol              Previous generation workhorse model.
          5. GPT-6-Luna             Fast and affordable model for easier tasks.
          6. GPT-5.6-Sol            Older generation workhorse model.
          7. GPT-5.6-Terra          Older balanced model for straightforward work.
          8. GPT-5.6-Luna           Older fast and efficient model.
          enter select · esc back
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.question == "Select Model and Effort")
        #expect(prompt.options.count == 8)
        #expect(prompt.options[0].label == "GPT-6.1-Sol")
        #expect(prompt.options[0].isCurrent == true)
        #expect(prompt.options[0].detail == "Latest workhorse model for coding and everyday work.")
        #expect(prompt.options[2].label == "GPT-6.1 Terra")
        #expect(prompt.selectedIndex == 1)
    }

    /// Return makes it the default; "s" keeps it to this session.
    @Test func effortList() throws {
        let pane = """
          Select Reasoning Level for GPT-6.1-Sol
          1. Low (default)         Fast responses with lighter reasoning
          2. Medium                Balances speed and reasoning depth for everyday tasks
          3. High                  Greater reasoning depth for complex problems
        › 4. Extra high (current)  Extra high reasoning depth for complex problems
          5. More reasoning…       Max and Ultra consume usage limits faster
          enter default · s session · esc back
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.question == "Select Reasoning Level for GPT-6.1-Sol")
        #expect(prompt.options.map(\.label) == ["Low (default)", "Medium", "High", "Extra high", "More reasoning…"])
        #expect(prompt.options[3].isCurrent == true)
        #expect(prompt.selectedIndex == 4)
        let session = try #require(prompt.keyActions?.first { $0.keyName == "s" })
        #expect(session.keys == ["s"] && session.label == "Session")
        #expect(prompt.keyActions?.contains { $0.keyName == "return" && $0.label == "Default" } == true)
    }

    @Test func modelLineAndEmptyBox() throws {
        let pane = """
        ⚠ Heads up, you have less than 5% of your weekly limit left. Run /status for a breakdown.
                                                                                                   ⚠ weekly limit: only 3% left · /status
        › Ask Codex to do anything
          GPT-6.1-Sol xhigh · ~/.agenthub/probe
          ← for agents · ? for shortcuts                                                                         ⚠ 1 warning · f2 to view
        """
        let line = try #require(PaneReader.codexModelLine(pane))
        #expect(line.model == "GPT-6.1-Sol" && line.effort == "xhigh")
        // The real screen ends in blank rows.
        let padded = try #require(PaneReader.codexModelLine(pane + String(repeating: "\n", count: 12)))
        #expect(padded.model == "GPT-6.1-Sol")
        #expect(PaneReader.read(pane).prompt == nil)
        // "Ask Codex to do anything" is Codex's placeholder, drawn dim.
        let styled = pane.replacingOccurrences(of: "› Ask Codex to do anything", with: "› \u{1B}[2mAsk Codex to do anything\u{1B}[22m")
        #expect(PaneReader.inputDraft(plain: pane, styled: styled) == nil)
        #expect(PaneReader.inputDraft(plain: pane.replacingOccurrences(of: "Ask Codex to do anything", with: "fix the tests")) == "fix the tests")
    }
}

@Suite("Context windows, as Claude Code writes them")
struct ContextWindowTests {
    @Test func fromContextCommand() {
        #expect(ContextText.window("**Model:** claude-opus-5-5   **Tokens:** 21.1k / 1m (2%)") == 1_000_000)
        #expect(ContextText.window("41.4k/1m tokens (4%)") == 1_000_000)
        #expect(ContextText.window("**Tokens:** 12k / 200k (6%)") == 200_000)
        #expect(ContextText.window("no numbers here") == nil)
    }

    @Test func fromStatusLine() throws {
        let json = #"{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000}}"#
        let learnt = try #require(ClaudeStatus.modelWindow(from: Data(json.utf8)))
        #expect(learnt.model == "claude-opus-5-5" && learnt.window == 1_000_000)
    }
}

/// Found by the verifier: screens that must not crash the hub or turn into a question.
@Suite("Verifier's screens")
struct VerifierScreenTests {
    /// The marker on the hint line itself: the hub must not crash.
    @Test func sliderMarkerOnTheHintLine() {
        let pane = """
        ⏺ Levels:
          low     medium     high     max
          ▲ marks the current one · ←/→ to adjust
        """
        _ = PaneReader.read(pane)
    }

    /// Your own numbered message, as Claude Code 2.1.316 echoes it, while it thinks.
    @Test func echoedNumberedMessageIsNotAQuestion() {
        let pane = """
        ❯ 1. fix the login page
          2. then run the tests

        ✻ Thinking… (3s · esc to interrupt)

        ────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────
          ⏵⏵ auto mode on · esc to interrupt · ↓ to manage
        """
        let reading = PaneReader.read(pane)
        #expect(reading.prompt == nil)
        #expect(reading.working)
    }

    /// The same in Codex.
    @Test func echoedNumberedMessageInCodexIsNotAQuestion() {
        let pane = """
        › 1. fix the login page
          2. then run the tests

        • Working (3s • esc to interrupt)

        › Ask Codex to do anything
          GPT-6.1-Sol xhigh · ~/project
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }

    /// A draft in Claude's message box with its footer hints isn't a menu.
    @Test func draftWithFooterIsNotAMenu() {
        let pane = """
        ⏺ Done.

        ────────────────────────────────────────────
        ❯ also check the
          settings page
        ────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }
}

@Suite("Accounts from the shell")
struct ShellAccountTests {
    @Test func functionsAndAliasesBecomeAccounts() {
        let shell = ShellDefinitions.parse("""
        claude-w() {
          CLAUDE_CONFIG_DIR="$HOME/.claude-work" command claude "$@"
        }
        function codex-2 {
          CODEX_HOME=~/.codex-second codex "$@"
        }
        alias opencode-p='XDG_DATA_HOME=~/.opencode-personal/share opencode'
        alias ll='ls -l'
        """)
        let claude = AccountDetector.extraAccounts(shell, base: "claude", provider: .claude, title: "Claude",
                                                   variable: "CLAUDE_CONFIG_DIR", home: "/Users/you") { $0 }
        #expect(claude.map(\.id) == ["claude-w"])
        #expect(claude.first?.name == "Claude · Work")
        #expect(claude.first?.dataDir == "/Users/you/.claude-work")
        #expect(claude.first?.badge == "W")
        let codex = AccountDetector.extraAccounts(shell, base: "codex", provider: .codex, title: "Codex",
                                                  variable: "CODEX_HOME", home: "/Users/you") { $0 }
        #expect(codex.first?.name == "Codex · Second" && codex.first?.dataDir == "/Users/you/.codex-second")
        let opencode = AccountDetector.extraAccounts(shell, base: "opencode", provider: .opencode, title: "OpenCode",
                                                     variable: "XDG_DATA_HOME", home: "/Users/you") { "\($0)/opencode" }
        #expect(opencode.first?.name == "OpenCode · Personal")
        #expect(opencode.first?.dataDir == "/Users/you/.opencode-personal/share/opencode")
    }
}

