import Foundation
import Testing

/// Conversations open outside the hub, as Claude Code 2.1.316 lists them (`claude agents --json`), and what's typed
/// in an agent's message box, which the phone's own box mirrors.
@Suite("Sessions open elsewhere, and message-box drafts")
struct ElsewhereTests {
    @Test func agentListAfterShellOutput() throws {
        // The person's login shell may print before the list; one row has no process, one is a kind we don't know.
        let output = """
        Restored session: Sun Nov  1 21:02:43 IST 2026
        [{"id":"a0703efc","cwd":"/Users/me/Projects/site","kind":"background","startedAt":1793527090633,"sessionId":"a0703efc-8735-4ef2-90c0-71e38f7b0184","name":"site-scenes","state":"blocked"},{"pid":40332,"cwd":"/Users/me/Projects","kind":"interactive","startedAt":1793529206324,"sessionId":"886d57a3-ba57-4221-961b-eb1c38c0118d","name":"projects-36","status":"busy"},{"pid":47066,"id":"6d19241d","cwd":"/Users/me/Projects/app","kind":"background","startedAt":1793561304934,"sessionId":"6d19241d-f007-49c0-a7f5-6fb6b628de21","name":"Lock screen polish","status":"idle","state":"working"},{"cwd":"/x","kind":"interactive","sessionId":"no-process"},{"pid":12,"kind":"cloud","sessionId":"elsewhere"}]
        """
        let agents = try #require(RunningAgents.parse(output))
        #expect(agents.map(\.sessionId) == ["a0703efc-8735-4ef2-90c0-71e38f7b0184", "886d57a3-ba57-4221-961b-eb1c38c0118d",
                                            "6d19241d-f007-49c0-a7f5-6fb6b628de21"])
        #expect(agents[0].kind == .background && agents[0].shortId == "a0703efc" && agents[0].pid == nil)
        #expect(agents[1].kind == .interactive && agents[1].pid == 40332 && agents[1].busy && agents[1].name == "projects-36")
        #expect(agents[2].shortId == "6d19241d" && !agents[2].busy)
    }

    @Test func agentListPrettyPrintedOrMissing() throws {
        let pretty = """
        [
          {
            "pid": 50039,
            "cwd": "/Users/me/Projects/app",
            "kind": "interactive",
            "sessionId": "3c4fce56-67ab-4070-9699-352a70ccad68",
            "status": "idle"
          }
        ]
        """
        let agents = try #require(RunningAgents.parse(pretty))
        #expect(agents.count == 1 && agents[0].pid == 50039 && !agents[0].busy)
        #expect(RunningAgents.parse("[]")?.isEmpty == true)
        // An older Claude Code without `agents` prints its usage: not a list.
        #expect(RunningAgents.parse("error: unknown command 'agents'") == nil)
    }

    @Test func hostsFromTheProcessList() {
        let listing = """
          642     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        49621   642 ttys009  login
        49625 49621 ttys009  -zsh
        50039 49625 ttys009  claude
         7000     1 ??       tmux
         7001  7000 ttys012  -zsh
         7002  7001 ttys012  claude
         8000     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
         8001  8000 ttys013  /bin/zsh
         8002  8001 ttys013  claude
         9000     1 ??       claude
        """
        let hosts = RunningAgents.hosts(of: [50039, 7002, 8002, 9000], listing: listing)
        #expect(hosts[50039] == RunningAgents.Host(tty: "/dev/ttys009", app: "Terminal"))
        #expect(hosts[7002] == RunningAgents.Host(tty: "/dev/ttys012", app: "tmux"))
        #expect(hosts[8002] == RunningAgents.Host(tty: "/dev/ttys013", app: "Visual Studio Code"))
        #expect(hosts[9000] == RunningAgents.Host(tty: nil, app: nil))
    }

    // MARK: Drafts

    @Test func longClaudeDraft() {
        // A message Claude Code handed back to edit (Opus's safeguards flagged it): many rows in the box.
        let pane = """
        ⚠ Opus 5.5's safeguards flagged this session. Opus 4.8 is answering instead, or you can edit and retry with Opus 5.5.

        ────────────────────────────────────────────
        ❯ look at the screen recorder and make the
          lock screen stay dark while it records,
          then check the settings page
          and the onboarding
          and the tests
          and the docs
        ────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
        #expect(PaneReader.inputDraft(plain: pane) == "look at the screen recorder and make the lock screen stay dark while it records, then check the settings page and the onboarding and the tests and the docs")
    }

    @Test func dialogCursorIsNotADraft() {
        let permission = """
        ────────────────────────────────────────────
         Bash command

           rm -rf build

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for rm commands in /Users/me/app
           3. No, and tell Claude what to do differently (esc)

         Esc to cancel · Tab to amend
        """
        #expect(PaneReader.inputDraft(plain: permission) == nil)
        let codex = """
          Would you like to run the following command?

          $ rm -rf build

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm · esc to cancel
        """
        #expect(PaneReader.inputDraft(plain: codex) == nil)
    }

    @Test func codexDraftOverSeveralLines() {
        let pane = """
        › first line of the draft
          second line
          GPT-6.1-Sol xhigh · ~/Projects/app
          ← for agents · ? for shortcuts
        """
        #expect(PaneReader.inputDraft(plain: pane) == "first line of the draft second line")
    }

    @Test func claudeDrawsItsPromptWithANoBreakSpace() {
        // As Claude Code 2.1.316 draws it: "❯" then U+00A0. Its grey placeholder and a real draft.
        let empty = "────────────\n❯\u{00A0}Try \"create a util logging.py\"\n────────────\n  ⏵⏵ auto mode on"
        let emptyStyled = "────────────\n\u{1B}[39m❯\u{00A0}\u{1B}[2mTry \"create a util logging.py\"\u{1B}[22m\n────────────\n  ⏵⏵ auto mode on"
        #expect(PaneReader.inputDraft(plain: empty, styled: emptyStyled) == nil)
        let suggestion = empty.replacingOccurrences(of: "Try \"create a util logging.py\"", with: "run the tests")
        let suggestionStyled = emptyStyled.replacingOccurrences(of: "Try \"create a util logging.py\"", with: "run the tests")
        #expect(PaneReader.inputDraft(plain: suggestion, styled: suggestionStyled) == nil)
        let pane = "────────────\n❯\u{00A0}please retry this with the\n  longer explanation\n────────────\n  ⏵⏵ auto mode on"
        #expect(PaneReader.inputDraft(plain: pane) == "please retry this with the longer explanation")
        let styled = pane.replacingOccurrences(of: "❯\u{00A0}please", with: "\u{1B}[39m❯\u{00A0}please")
        #expect(PaneReader.inputDraft(plain: pane, styled: styled) == "please retry this with the longer explanation")
    }

    @Test func draftsCompareByWords() {
        #expect(PaneReader.sameDraft("fix the\n  login page", "fix the login page"))
        #expect(PaneReader.sameDraft("  fix it ", "fix it"))
        #expect(!PaneReader.sameDraft("fix it", "fix it now"))
    }
}
