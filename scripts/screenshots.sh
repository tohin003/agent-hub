#!/bin/bash
# Takes the README's screenshots from made-up sessions (Tools/DemoData: a few agents at work, one waiting for an
# approval), in a simulator of its own ("AgentHub Shots"), in dark mode with a 9:41 status bar. Nothing connects to
# your Mac's hub and no agent is sent anything. The agents' logos and model lists come from this Mac's ~/.agenthub
# when it has them. Writes docs/screenshots/*.png.
#
#   scripts/screenshots.sh [--wait SECONDS]   (seconds to let each screen settle; slow Macs need more)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$ROOT/build/screenshots"
OUT="$ROOT/docs/screenshots"
WAIT=20
[ "${1:-}" = "--wait" ] && WAIT="${2:-20}"
say() { printf 'screenshots.sh: %s\n' "$*"; }
mkdir -p "$WORK/raw" "$OUT"

# 1. The made-up Mac.
/usr/bin/nice -n 10 /usr/bin/xcrun swiftc -o "$WORK/demodata" "$ROOT/Tools/DemoData/main.swift" \
  "$ROOT/iOS/Model/DemoSnapshot.swift" "$ROOT"/Shared/Protocol/*.swift

# 2. A simulator of its own (an iPhone with a Dynamic Island, on the newest iOS).
runtime=$(/usr/bin/xcrun simctl list runtimes | /usr/bin/grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | /usr/bin/tail -1)
udid=$(/usr/bin/xcrun simctl list devices | /usr/bin/grep "AgentHub Shots" | /usr/bin/grep -oE '[0-9A-F-]{36}' | /usr/bin/head -1 || true)
if [ -z "$udid" ]; then
  type=$(/usr/bin/xcrun simctl list devicetypes | /usr/bin/grep -oE 'com.apple.CoreSimulator.SimDeviceType.iPhone-[0-9]+-Pro\b' | /usr/bin/tail -1)
  udid=$(/usr/bin/xcrun simctl create "AgentHub Shots" "$type" "$runtime")
fi
/usr/bin/xcrun simctl boot "$udid" 2>/dev/null || true
/usr/bin/xcrun simctl bootstatus "$udid" -b >/dev/null
/usr/bin/xcrun simctl ui "$udid" appearance dark
/usr/bin/xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

# 3. The app, built for it.
(cd "$ROOT" && xcodegen generate --quiet)
/usr/bin/nice -n 15 /usr/bin/xcodebuild -project "$ROOT/AgentHub.xcodeproj" -scheme AgentHub \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$ROOT/build/dd-sim" -jobs 2 CODE_SIGNING_ALLOWED=NO \
  build >/dev/null
app="$ROOT/build/dd-sim/Build/Products/Debug-iphonesimulator/AgentHub.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
/usr/bin/xcrun simctl install "$udid" "$app"
data=$(/usr/bin/xcrun simctl get_app_container "$udid" "$bundle" data)
mkdir -p "$data/Documents"

# 4. Each screen: fresh made-up data (so "2 min ago" stays true), launch, settle, capture.
shot() {
  local name=$1; shift
  "$WORK/demodata" "$data/Documents/demo.json" >/dev/null
  /usr/bin/xcrun simctl launch --terminate-running-process "$udid" "$bundle" -demo demo.json \
    -AppleLocale en_US -AppleLanguages "(en)" "$@" >/dev/null
  sleep "$WAIT"
  /usr/bin/xcrun simctl io "$udid" screenshot "$WORK/raw/$name.png" >/dev/null 2>&1
  /usr/bin/sips -Z 1311 "$WORK/raw/$name.png" --out "$OUT/$name.png" >/dev/null
  say "$name"
}
shot 01-sessions
shot 02-chat -openSession demo-landing
shot 03-approval -openSession demo-auth
shot 04-usage -openSession demo-landing -demoSheet usage
shot 05-models -openSession demo-landing -demoSheet models
shot 06-mac -startTab mac
say "done: $OUT"
