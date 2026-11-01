#!/bin/bash
# Builds the Mac hub ("Agent Hub" in the menu bar), puts it in ~/Applications, and starts it at every login with a
# LaunchAgent. Also installs the renewal LaunchAgent that keeps the iPhone app signed.
#
#   scripts/install-mac.sh            build, install, (re)start
#   scripts/install-mac.sh --no-build install the last build again
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS="$HOME/Applications"
APP="$APPS/Agent Hub.app"
AGENTS="$HOME/Library/LaunchAgents"
# Your bundle ID prefix (Config/Local.xcconfig, else the shared default) names the login items.
PREFIX=$(/usr/bin/sed -n 's/^AGENTHUB_BUNDLE_PREFIX *= *\([A-Za-z0-9.-]*\).*/\1/p' "$ROOT/Config/Local.xcconfig" "$ROOT/Config/Base.xcconfig" 2>/dev/null | /usr/bin/head -1)
HUB_LABEL="${PREFIX:-io.github.agenthub}.AgentHubMac"
RENEW_LABEL="${PREFIX:-io.github.agenthub}.AgentHub.renew"
DOMAIN="gui/$(/usr/bin/id -u)"
LOGS="$HOME/Library/Logs/AgentHub"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build=1

say() { printf 'install-mac.sh: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) build=0 ;;
    -h|--help) /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) say "unknown option: $1"; exit 64 ;;
  esac
  shift
done

command -v tmux >/dev/null || { say "tmux is missing: brew install tmux"; exit 69; }
[ -f "$ROOT/Config/Local.xcconfig" ] || "$ROOT/scripts/configure.sh"

if [ "$build" -eq 1 ]; then
  say "building the Mac hub (low priority, two jobs)..."
  (cd "$ROOT" && xcodegen generate --quiet)
  if ! (cd "$ROOT" && /usr/bin/nice -n 15 xcodebuild -project AgentHub.xcodeproj -scheme AgentHubMac -configuration Release \
        -derivedDataPath build/dd -jobs 2 -allowProvisioningUpdates build > "$ROOT/build/mac-build.log" 2>&1); then
    /usr/bin/grep -E "error:" "$ROOT/build/mac-build.log" | /usr/bin/head -10
    say "the build failed; see build/mac-build.log"
    exit 1
  fi
fi
built="$ROOT/build/dd/Build/Products/Release/Agent Hub.app"
[ -d "$built" ] || { say "no build at $built"; exit 66; }

# Stop the running hub, swap the app in, start it again.
/bin/launchctl bootout "$DOMAIN/$HUB_LABEL" >/dev/null 2>&1 || true
/usr/bin/pkill -f "Agent Hub.app/Contents/MacOS/Agent Hub" >/dev/null 2>&1 || true
/bin/mkdir -p "$APPS" "$AGENTS" "$LOGS"
/bin/rm -rf "$APP.new"
/usr/bin/ditto "$built" "$APP.new"
/bin/rm -rf "$APP"
/bin/mv "$APP.new" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
say "installed $APP ($(/usr/bin/codesign -dv "$APP" 2>&1 | /usr/bin/grep -E '^Authority=' | /usr/bin/head -1 | /usr/bin/sed 's/Authority=//' || echo 'signed'))"

write_agent() {
  # $1 label, $2 plist body (the dict's inner XML)
  /bin/cat > "$AGENTS/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$1</string>
$2
</dict>
</plist>
EOF
  /usr/bin/plutil -lint "$AGENTS/$1.plist" >/dev/null
}

write_agent "$HUB_LABEL" "	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/Agent Hub</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOGS/hub.stderr.log</string>"

write_agent "$RENEW_LABEL" "	<key>ProgramArguments</key>
	<array>
		<string>$ROOT/scripts/renew-check.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>Nice</key>
	<integer>15</integer>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>DEVELOPER_DIR</key>
		<string>/Applications/Xcode.app/Contents/Developer</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$LOGS/renew.log</string>
	<key>StandardErrorPath</key>
	<string>$LOGS/renew.log</string>"

/bin/chmod +x "$ROOT/scripts/"*.sh
/bin/launchctl bootout "$DOMAIN/$RENEW_LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$DOMAIN" "$AGENTS/$HUB_LABEL.plist"
/bin/launchctl bootstrap "$DOMAIN" "$AGENTS/$RENEW_LABEL.plist"
say "started the hub and the renewal check (every 30 minutes)."
say "first time only, on the Mac: allow Agent Hub in System Settings › Privacy & Security › Screen & System Audio Recording"
say "and Accessibility (the Mac tab in the iPhone app has buttons that ask)."
