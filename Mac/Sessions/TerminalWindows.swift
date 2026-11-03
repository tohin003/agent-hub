import AppKit
import ApplicationServices

/// Opens, raises and closes the Terminal windows that show hub sessions on the Mac, without needing macOS's
/// Automation permission.
///
/// Each window runs a small `.command` script: it attaches to the session's tmux and, alongside, watches for
/// request files from the hub (`<session>.focus`, `<session>.zoom`). Because that script runs inside Terminal, it may
/// script its own window (raise it, which also switches to its Space; zoom it; close it when tmux detaches) with no
/// consent prompt. The hub closes a window by detaching its tmux client. Full screen uses the Accessibility API.
@MainActor
final class TerminalWindows {
    private let tmux: Tmux
    let bundleID = "com.apple.Terminal"

    init(tmux: Tmux) {
        self.tmux = tmux
    }

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func open(session: String, title: String, fullScreen: Bool) async -> Bool {
        let path = "\(HubPaths.attach)/\(session).command"
        do {
            try script(session: session, title: title).write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            Log.error("windows: couldn't write \(path): \(error)")
            return false
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: configuration)
        } catch {
            Log.error("windows: Terminal didn't open \(path): \(error)")
            return false
        }
        // Wait for tmux to see the new client, then make the window full screen (or zoom it without Accessibility).
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(150))
            guard await hasClient(session) else { continue }
            if fullScreen {
                if accessibilityTrusted, let window = await waitForAXWindow(session) {
                    setFullScreen(window)
                } else {
                    request(session, "zoom")
                    Log.info("windows: \(session) zoomed instead of full screen (allow Accessibility for full screen)")
                }
            }
            return true
        }
        Log.warn("windows: the window for \(session) didn't attach in time")
        return false
    }

    /// Brings the session's window forward, which also switches the Mac to its Space. False when no window shows it.
    func focus(session: String) async -> Bool {
        guard await hasClient(session) else { return false }
        request(session, "focus")
        return true
    }

    /// Closes the session's window(s); the session itself keeps running.
    func close(session: String) async {
        _ = await Shell.run(tmux.path, ["-L", Tmux.socket, "detach-client", "-s", session], environment: Tmux.environment, timeout: 5)
    }

    /// Shows a session that moved here from a terminal tab in that same tab (`tty`), so the window carries on.
    /// For Terminal, a tiny script run inside Terminal (no Automation permission, as for the hub's own windows) types
    /// the attach command into the tab's shell, then closes its own window; leaving the session later returns the
    /// tab to that shell. Other apps can't be typed into: their tab gets a note saying where the session went.
    func reattach(session: String, title: String, tty: String, app: String?) async {
        let attachPath = "\(HubPaths.attach)/\(session).command"
        guard app == "Terminal" else {
            note(tty, "Agent Hub: this conversation continues in Agent Hub. To show it here: "
                 + "\(Shell.quote(tmux.path)) -L \(Tmux.socket) attach -t \(session)")
            return
        }
        let helperPath = "\(HubPaths.attach)/\(session)-here.command"
        do {
            try script(session: session, title: title).write(toFile: attachPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attachPath)
            try helper(tty: tty, attachPath: attachPath).write(toFile: helperPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperPath)
        } catch {
            Log.error("windows: couldn't write the scripts to show \(session) in \(tty): \(error)")
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: helperPath)], withApplicationAt: appURL,
                                                  configuration: configuration)
        } catch {
            Log.error("windows: Terminal didn't run the script to show \(session) in \(tty): \(error)")
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            if await hasClient(session) {
                Log.info("windows: \(session) shows in the tab it moved from (\(tty))")
                return
            }
        }
        Log.warn("windows: the tab \(tty) didn't attach to \(session)")
    }

    /// Prints a dim line into a terminal tab (its screen, not its input).
    private func note(_ tty: String, _ text: String) {
        guard tty.hasPrefix("/dev/tty"), let handle = FileHandle(forWritingAtPath: tty) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data("\r\n\u{1B}[2m\(text)\u{1B}[0m\r\n".utf8))
    }

    /// Run in a window of its own: types the attach command into the tab showing `tty`, then closes that window.
    private func helper(tty: String, attachPath: String) -> String {
        func appleScriptString(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // A leading space keeps it out of the shell's history where that's set up.
        let command = " /bin/zsh \(Shell.quote(attachPath)) here"
        return """
        #!/bin/zsh
        # Agent Hub: shows a session in the Terminal tab it moved from (\(tty)), then closes this window.
        /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
        tell application id "\(bundleID)"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is \(appleScriptString(tty)) then
                do script \(appleScriptString(command)) in t
                return
              end if
            end repeat
          end repeat
        end tell
        APPLESCRIPT
        TTY=$(/usr/bin/tty)
        /bin/rm -f "$0"
        ( /bin/sleep 0.3
          /usr/bin/osascript -e "tell application id \\"\(bundleID)\\"
            repeat with w in windows
              if tty of selected tab of w is \\"$TTY\\" then
                close w
                exit repeat
              end if
            end repeat
          end tell" >/dev/null 2>&1 ) &!
        exit 0
        """
    }

    // MARK: The window's script

    /// The script a window runs. Run with "here" (in a tab a session moved from), leaving the session returns the tab
    /// to its shell instead of closing the window.
    private func script(session: String, title: String) -> String {
        let label = "\(session) · \(title)"
        return """
        #!/bin/zsh
        # Agent Hub: shows session \(session) in this window. Closing the window leaves the session running.
        S=\(Shell.quote(session))
        DIR="$HOME/.agenthub/attach"
        TTY=$(/usr/bin/tty)
        printf '\\033]0;%s\\007' \(Shell.quote(label))
        own_window() {
          /usr/bin/osascript -e "tell application id \\"\(bundleID)\\"
            repeat with w in windows
              if tty of selected tab of w is \\"$TTY\\" then
                $1
                exit repeat
              end if
            end repeat
          end tell" >/dev/null 2>&1
        }
        (
          while :; do
            /bin/sleep 0.5
            if [ -e "$DIR/$S.focus" ]; then
              /bin/rm -f "$DIR/$S.focus"
              own_window 'set index of w to 1
                activate'
            fi
            if [ -e "$DIR/$S.zoom" ]; then
              /bin/rm -f "$DIR/$S.zoom"
              own_window 'set zoomed of w to true'
            fi
          done
        ) &!
        watcher=$!
        \(Shell.quote(tmux.path)) -L \(Tmux.socket) attach-session -t "$S"
        kill $watcher 2>/dev/null
        # In a tab the session moved from: back to that tab's own shell.
        [ "$1" = here ] && exit 0
        # Detached by the hub, or the session ended: close this window once the shell has exited.
        ( /bin/sleep 0.4; own_window 'close w' ) &!
        exit 0
        """
    }

    private func request(_ session: String, _ kind: String) {
        FileManager.default.createFile(atPath: "\(HubPaths.attach)/\(session).\(kind)", contents: Data())
    }

    private func hasClient(_ session: String) async -> Bool {
        let result = await Shell.run(tmux.path, ["-L", Tmux.socket, "list-clients", "-t", session, "-F", "#{client_tty}"],
                                     environment: Tmux.environment, timeout: 5)
        return result.ok && !result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Accessibility (full screen)

    private func waitForAXWindow(_ session: String) async -> AXUIElement? {
        for _ in 0..<20 {
            if let window = axWindow(titleContaining: session) { return window }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    private func axWindow(titleContaining text: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return (title as? String)?.contains(text) == true
        }
    }

    private func setFullScreen(_ window: AXUIElement) {
        let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        if result != .success { Log.warn("windows: full screen failed (\(result.rawValue))") }
    }
}
