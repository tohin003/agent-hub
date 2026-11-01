import Foundation
import Testing

@Suite("Reading prompts off the terminal")
struct PaneReaderTests {
    @Test func claudeBoxedPermissionPrompt() throws {
        let pane = """
        ⏺ I'll list the files.

        ╭───────────────────────────────────────────────────────────────╮
        │ Bash command                                                  │
        │                                                               │
        │   ls -la                                                      │
        │   List files                                                  │
        │                                                               │
        │ Do you want to proceed?                                       │
        │ ❯ 1. Yes                                                      │
        │   2. Yes, and don't ask again for ls commands in /tmp/x       │
        │   3. No, and tell Claude what to do differently (esc)         │
        ╰───────────────────────────────────────────────────────────────╯
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.kind == .choice)
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.options.map(\.label) == [
            "Yes", "Yes, and don't ask again for ls commands in /tmp/x", "No, and tell Claude what to do differently (esc)",
        ])
        #expect(prompt.selectedIndex == 1)
        #expect(prompt.context?.contains("ls -la") == true)
        #expect(prompt.options[2].isNegative)
    }

    @Test func claudeOpenStylePromptWithCursorOnSecond() throws {
        let pane = """
        ────────────────────────────────────────────────────────────────
         Edit file
         src/app.swift
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
          12 -    let a = 1
          12 +    let a = 2
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to make this edit to app.swift?
           1. Yes
         ❯ 2. Yes, allow all edits during this session (shift+tab)
           3. No, and tell Claude what to do differently (esc)

        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.question == "Do you want to make this edit to app.swift?")
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.options.count == 3)
    }

    @Test func codexApproval() throws {
        let pane = """
        • I need to run the tests.

          Would you like to run the following command?

          $ npm test

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """
        let reading = PaneReader.read(pane)
        let prompt = try #require(reading.prompt)
        #expect(prompt.options.count == 3)
        #expect(prompt.options[0].label == "Yes, proceed (y)")
        #expect(prompt.hint == "Press enter to confirm or esc to cancel")
        #expect(!reading.working)
    }

    @Test func plainNumberedListIsNotAPrompt() {
        let pane = """
        ⏺ Here's the plan:
          1. Read the config
          2. Update the parser
          3. Run the tests

        >
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }

    @Test func numberedListHighInTheScreenIsNotAPrompt() {
        var lines = ["Options:", "❯ 1. First", "  2. Second"]
        lines += (1...12).map { "output line \($0)" }
        #expect(PaneReader.read(lines.joined(separator: "\n")).prompt == nil)
    }

    @Test func workingStatusLine() {
        let pane = """
        ⏺ Reading files…

        ✻ Pondering… (34s · ↑ 1.2k tokens · esc to interrupt)

        ╭──────────────────────────────╮
        │ >                            │
        ╰──────────────────────────────╯
        """
        let reading = PaneReader.read(pane)
        #expect(reading.working)
        #expect(reading.statusLine == "Pondering… (34s · ↑ 1.2k tokens)")
        #expect(reading.prompt == nil)
    }

    @Test func yesNoQuestion() throws {
        let pane = "Need to install the following packages:\ncreate-app@1.0.0\nOk to proceed? (y/N) "
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.kind == .yesNo)
        #expect(prompt.options.first?.keys == ["y", "Enter"])
    }

    @Test func signatureIsStable() {
        #expect(PaneReader.stableHash("abc") == PaneReader.stableHash("abc"))
        #expect(PaneReader.stableHash("abc") != PaneReader.stableHash("abd"))
    }
}

@Suite("Menus without numbers")
struct CursorMenuTests {
    /// Captured from Claude Code 2.1.316's folder trust dialog in the hub's tmux.
    @Test func claudeTrustDialog() throws {
        let pane = """
        ──────────────────────────────────────────────────────────────────────────────────────────────
         Accessing workspace:

         /private/tmp/example/ctest

         Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project)
         If not, take a moment to review what's in this folder first.

         Claude Code'll be able to read, edit, and execute files here.

         ]8;id=zaxmda;https://code.claude.com/docs/en/security\\Security guide]8;;\\

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel
        """
        let reading = PaneReader.read(pane)
        let prompt = try #require(reading.prompt)
        #expect(prompt.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(prompt.selectedIndex == 1)
        #expect(prompt.question.hasPrefix("Quick safety check: Is this a project"))
        #expect(prompt.hint == "Enter to confirm · Esc to cancel")
        #expect(prompt.context?.contains("Security guide") == true)
        #expect(prompt.context?.contains("]8;") == false)
        #expect(!reading.working)
    }

    @Test func questionWithDescriptions() throws {
        let pane = """
        ────────────────────────────────────────
         Which database should we use?

           Postgres
             Relational, strong consistency
         ❯ SQLite
             File-based, simple
           Redis
             In-memory

         Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["Postgres", "SQLite", "Redis"])
        #expect(prompt.options[1].detail == "File-based, simple")
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.question == "Which database should we use?")
    }

    @Test func typedInputIsNotAMenu() {
        let pane = """
        ╭────────────────────────────────────╮
        │ ❯ fix the login bug                │
        │   and add a test                   │
        ╰────────────────────────────────────╯
          ? for shortcuts
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }
}

@Suite("Antigravity's menus")
struct AntigravityMenuTests {
    /// Antigravity CLI 1.2.10's trust question: a ">" cursor and a hint line at the options' indent.
    @Test func trustQuestion() throws {
        let pane = """
        Accessing workspace:

        /tmp/project

        Do you trust the contents of this project?

        Antigravity CLI requires permission to read, edit, and execute files here.

        > Yes, I trust this folder
          No, exit

          ↑/↓ Navigate · enter Confirm
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["Yes, I trust this folder", "No, exit"])
        #expect(prompt.selectedIndex == 1)
        #expect(prompt.question == "Do you trust the contents of this project?")
        #expect(prompt.hint == "↑/↓ Navigate · enter Confirm")
    }

    /// Its empty input line ("> ") isn't a menu.
    @Test func inputLineIsNotAMenu() {
        let pane = """
          Antigravity CLI 1.2.10
        ────────────────────────────────────────
        >
        ────────────────────────────────────────
        ? for shortcuts
        """
        #expect(PaneReader.read(pane).prompt == nil)
    }
}

@Suite("Checklists and key hints")
struct ChecklistTests {
    /// Claude Code's "new MCP servers" dialog, as the person saw it: Space ticks, "Enable selected" confirms.
    @Test func mcpServersChecklist() throws {
        let pane = """
        ──────────────────────────────────────────────────────────────────────
         2 new MCP servers found in this project
         Select any you wish to enable.

         MCP servers may execute code or access system resources. All tool calls require approval. Learn more in the MCP documentation.

           [✔] code-review-graph
         ❯ [✔] graphify-2nd-brain
               Enable selected
         Space to select · Esc to reject all
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["code-review-graph", "graphify-2nd-brain", "Enable selected"])
        #expect(prompt.options[0].checked == true)
        #expect(prompt.options[1].checked == true)
        #expect(prompt.options[2].isAction == true)
        #expect(prompt.options[2].checked == nil)
        #expect(prompt.selectedIndex == 2)
        #expect(prompt.multiSelect == true)
        #expect(prompt.question == "2 new MCP servers found in this project")
        #expect(prompt.context?.contains("MCP servers may execute code") == true)
        let actions = try #require(prompt.keyActions)
        #expect(actions.map(\.label) == ["Select", "Reject all"])
        #expect(actions.map(\.keys) == [["Space"], ["Escape"]])
    }

    @Test func untickedBoxes() throws {
        let pane = """
        Choose tools
        ❯ [ ] Bash
          [x] Read
          Done
        Space to toggle · Enter to confirm
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.checked) == [false, true, nil])
        #expect(prompt.options.last?.isAction == true)
    }

    @Test func hintKeys() {
        let actions = PaneReader.keyActions("Enter to confirm · Esc to cancel · Tab to amend · ctrl+e to explain")
        #expect(actions.map(\.label) == ["Confirm", "Cancel", "Amend", "Explain"])
        #expect(actions.map(\.keys) == [["Enter"], ["Escape"], ["Tab"], ["C-e"]])
        #expect(PaneReader.keyActions("↑/↓ Navigate · enter Confirm").map(\.label) == ["Confirm"])
    }
}

@Suite("Screens waiting for a key")
struct PressPromptTests {
    @Test func pressEnterToContinue() throws {
        let prompt = try #require(PaneReader.read("Login successful.\nPress Enter to continue…").prompt)
        #expect(prompt.options.map(\.label) == ["Continue"])
        #expect(prompt.options.first?.keys == ["Enter"])
        #expect(prompt.question == "Login successful.")
    }

    @Test func workingLineIsNotAPressPrompt() {
        #expect(PaneReader.read("✻ Thinking… (3s · esc to interrupt)").prompt == nil)
    }
}

@Suite("The real MCP dialog")
struct RealMCPDialogTests {
    /// Captured from the person's session: the cursor on the first server, "Enable selected" one column left of the
    /// names.
    @Test func cursorOnFirstServer() throws {
        let pane = """
        ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
          2 new MCP servers found in this project
          Select any you wish to enable.
          MCP servers may execute code or access system resources. All tool calls require approval. Learn more in the
          ❯ [✔] code-review-graph
            [✔] graphify-2nd-brain
               Enable selected
         Space to select · Esc to reject all
        """
        let prompt = try #require(PaneReader.read(pane).prompt)
        #expect(prompt.options.map(\.label) == ["code-review-graph", "graphify-2nd-brain", "Enable selected"])
        #expect(prompt.options.map(\.checked) == [true, true, nil])
        #expect(prompt.options[2].isAction == true)
        #expect(prompt.selectedIndex == 1)
    }
}
