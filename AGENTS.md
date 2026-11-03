# AGENTS.md: working on Agent Hub

Agent Hub is an iPhone app (SwiftUI, iOS 26+) plus a Mac menu bar hub that runs AI coding agents in tmux and serves
the phone over Tailscale. Read `README.md` for the architecture before changing anything.

## Layout

| Path | What |
|---|---|
| `Shared/Protocol/` | The phone ⇄ hub wire protocol (Foundation only, `nonisolated` types). Change both sides together. |
| `Shared/Mascot/` | The mascot (ported from bloub, MIT): drawn in code; also renders the app icons (`scripts/make-icons.sh`). |
| `Shared/Terminal/` | Terminal colour parsing and the renderer for the logos the hub reads off each CLI. |
| `Mac/` | The hub: server (`Server/`), sessions/tmux/windows/prompt reading (`Sessions/`), transcript readers (`Transcripts/`), screen (`Screen/`), menu bar app (`App/`). Swift 5 mode. |
| `iOS/` | The app: model (`Model/`), design tokens (`Design/`), screens (`Views/`), Live Activity (`LiveActivity/`). Swift 6, MainActor by default. |
| `Widgets/` | The Lock Screen and Dynamic Island Live Activity (an app extension). |
| `Tests/HubCoreTests/` | Swift Testing tests for the readers, many built from real captured screens. Run: `xcodebuild -scheme AgentHubMac test`. |
| `UITests/` | The Screen tab's gestures played on a simulator against a debug-only harness (`-screenGestureTest YES`). Run: `xcodebuild test -scheme AgentHub -only-testing:AgentHubUITests -destination 'platform=iOS Simulator,name=…'`. |
| `scripts/` | configure, install, renew, renew-check, icons, uninstall. |

## Rules

- **Derive, don't hard-code.** Logos, model lists, effort levels, slash commands and usage are read from the agents
  themselves (their screens, menus, caches and non-interactive commands). Keep only neutral fallbacks in code.
- **Design:** Apple's Human Interface Guidelines. System components first; Liquid Glass only on the control layer
  (bars, composer, floating controls), never on content; one tint (Starlight); Dynamic Type; 44 pt targets; labels on
  icon buttons; colour never carries meaning alone. iOS 27 APIs only behind `#available`.
- **Never touch the person's own agent configs** (`~/.claude*/settings.json`, `~/.codex/config.toml`, …). The hub's
  Claude hooks and status line load only through `--settings` for sessions it starts. When driving an agent's picker,
  choose "this session only"; never make a choice its default unless asked.
- **Never type into a session the person is using** to test something. Start a throwaway session in
  `~/.agenthub/probe`, use only local commands there (`/context`, `/model` then Esc), and remove it afterwards. Don't
  send prompts to agents unless the person agreed.
- **Secrets:** never read or print the pairing token (`~/.agenthub/token`), `Config/Local.xcconfig` (git-ignored) or
  the Keychain.
- **Builds:** be gentle on small Macs (`nice -n 15`, `xcodebuild -jobs 2`, one build at a time). An optional
  `~/.agenthub/hold-status.sh` (exit 3 = busy) pauses heavy background work.
- Name the person with they/them.
