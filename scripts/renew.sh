#!/bin/bash
# Builds Agent Hub for iPhone, signs it with your Personal Team and installs it on your iPhone. A free Apple ID's
# signing lasts 7 days; building again with -allowProvisioningUpdates renews it, and installing over the old app
# keeps its settings and pairing.
#
#   scripts/renew.sh                    rebuild the build last installed (a snapshot of the sources) and install it
#   scripts/renew.sh --from-tree        build this working tree instead, install it, and make it the new snapshot
#   scripts/renew.sh --device ID        install on this devicectl identifier
#   scripts/renew.sh --force            go ahead even while ~/.agenthub/hold-status.sh says the Mac is busy
#   scripts/renew.sh --reason auto|phone|manual   recorded with the result (auto: started by renew-check.sh)
#   scripts/renew.sh --dry-run          print what would happen
#
# Records every attempt in ~/.agenthub/renew/state.json (installed time, expiry, device, last result), which the
# Mac hub shows on the phone and renew-check.sh uses to decide when to renew next.
# Exit codes: 0 done, 64 usage, 66 no project, 69 no Xcode or no iPhone, 75 busy (HOLD or another renewal), 1 failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/.agenthub/renew"
STATE="$STATE_DIR/state.json"
LOCK="$STATE_DIR/lock"
SNAPSHOT="$STATE_DIR/src"
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
from_tree=0
force=0
dry=0
device=""
reason="manual"
locked=0
tmp=""

say() { printf '%s renew.sh: %s\n' "$(/bin/date '+%H:%M:%S')" "$*"; }
cleanup() {
  if [ -n "$tmp" ]; then /bin/rm -rf "$tmp"; fi
  if [ "$locked" -eq 1 ]; then /bin/rm -rf "$LOCK"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --from-tree) from_tree=1 ;;
    --force) force=1 ;;
    --dry-run) dry=1 ;;
    --device) device="${2:-}"; shift ;;
    --reason) reason="${2:-manual}"; shift ;;
    -h|--help) /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) say "unknown option: $1 (see --help)"; exit 64 ;;
  esac
  shift
done

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$XCODE_DEV" ]; then export DEVELOPER_DIR="$XCODE_DEV"; fi
/bin/mkdir -p "$STATE_DIR"
/bin/chmod 700 "$HOME/.agenthub" "$STATE_DIR" 2>/dev/null || true

# Writes one attempt's result into state.json (keeping what it doesn't change).
record() {
  # $1 succeeded (true/false)  $2 message  [$3 profile plist to read dates from]
  /usr/bin/python3 -I - "$STATE" "$1" "$2" "${3:-}" "$device" "$reason" <<'PY'
import datetime, json, os, plistlib, sys, tempfile
state_path, ok, message, profile_path, device, reason = sys.argv[1:7]
def iso(moment):
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
try:
    with open(state_path) as handle:
        state = json.load(handle)
except Exception:
    state = {}
now = datetime.datetime.now(datetime.timezone.utc)
state['version'] = 1
state['lastAttempt'] = iso(now)
state['lastSucceeded'] = ok == 'true'
state['lastResult'] = message
state['lastReason'] = reason
if profile_path:
    with open(profile_path, 'rb') as handle:
        profile = plistlib.load(handle)
    previous = state.get('profileExpires')
    state['installedAt'] = iso(now)
    state['profileCreated'] = iso(profile['CreationDate'])
    state['profileExpires'] = iso(profile['ExpirationDate'])
    state['expiryMoved'] = previous != state['profileExpires']
    if device:
        state['device'] = device
folder = os.path.dirname(state_path)
handle, temporary = tempfile.mkstemp(dir=folder, prefix='.state-', suffix='.json')
with os.fdopen(handle, 'w') as out:
    json.dump(state, out, indent=2, sort_keys=True)
    out.write('\n')
os.replace(temporary, state_path)
PY
}

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Agent Hub\"" >/dev/null 2>&1 || true
}

fail() {
  say "$1"
  if [ "$dry" -eq 0 ]; then
    record false "$1"
    # Automatic runs notify, at most every 12 hours, so a lasting problem doesn't nag.
    stamp="$STATE_DIR/notified"
    if [ "$reason" != "manual" ] && [ -z "$(/usr/bin/find "$stamp" -mmin -720 2>/dev/null)" ]; then
      notify "Couldn't renew the iPhone app: $1"
      /usr/bin/touch "$stamp"
    fi
  fi
  exit "${2:-1}"
}

# 1. One renewal at a time.
if [ "$dry" -eq 0 ]; then
  if ! /bin/mkdir "$LOCK" 2>/dev/null; then
    holder=$(/bin/cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      say "another renewal is running (pid $holder)."
      exit 75
    fi
    /bin/rm -rf "$LOCK"
    /bin/mkdir "$LOCK"
  fi
  locked=1
  echo $$ > "$LOCK/pid"
fi

# 2. Optional: ~/.agenthub/hold-status.sh exits 3 while the Mac is busy with something more important.
hold_script="$HOME/.agenthub/hold-status.sh"
if [ -x "$hold_script" ] && [ "$force" -eq 0 ]; then
  hold=0
  "$hold_script" >/dev/null 2>&1 || hold=$?
  if [ "$hold" -eq 3 ]; then
    fail "the Mac is busy (hold-status.sh); renewal waits until it's free." 75
  fi
fi

# 3. Xcode and the sources.
if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then fail "Xcode isn't installed or selected." 69; fi
if [ "$from_tree" -eq 1 ] || [ ! -f "$SNAPSHOT/project.yml" ]; then
  src="$ROOT"
  if [ "$from_tree" -eq 0 ]; then say "no snapshot yet; building the working tree."; from_tree=1; fi
else
  src="$SNAPSHOT"
fi
if [ ! -f "$src/project.yml" ]; then fail "no project.yml in $src" 66; fi
if [ ! -f "$src/Config/Local.xcconfig" ] && [ -f "$ROOT/Config/Local.xcconfig" ]; then
  /bin/cp "$ROOT/Config/Local.xcconfig" "$src/Config/Local.xcconfig"
fi
say "building from $src ($reason)"

if [ "$dry" -eq 1 ]; then
  say "would run: xcodegen generate; xcodebuild -scheme AgentHub -configuration Release -allowProvisioningUpdates; devicectl install"
  exit 0
fi

# 4. The iPhone: --device, then the one installed last time, then the only real paired iPhone.
tmp=$(/usr/bin/mktemp -d -t agenthub-renew)
/usr/bin/xcrun devicectl list devices --json-output "$tmp/devices.json" >/dev/null 2>&1 || true
pick=$(/usr/bin/python3 -I - "$tmp/devices.json" "$device" "$STATE" <<'PY'
import json, sys
devices_path, wanted, state_path = sys.argv[1:4]
try:
    devices = json.load(open(devices_path)).get('result', {}).get('devices', [])
except Exception:
    devices = []
def field(d, *path):
    for key in path:
        d = d.get(key) if isinstance(d, dict) else None
    return d
phones = [d for d in devices
          if field(d, 'hardwareProperties', 'platform') == 'iOS'
          and field(d, 'connectionProperties', 'pairingState') == 'paired'
          and field(d, 'connectionProperties', 'transportType') != 'sameMachine']
if not wanted:
    try:
        wanted = json.load(open(state_path)).get('device') or ''
    except Exception:
        wanted = ''
if wanted:
    match = [d for d in phones if d.get('identifier') == wanted]
    if match:
        d = match[0]
        print(d['identifier'], field(d, 'connectionProperties', 'tunnelState') or 'unknown')
        sys.exit(0)
connected = [d for d in phones if field(d, 'connectionProperties', 'tunnelState') == 'connected']
choice = connected or phones
if len(choice) == 1:
    print(choice[0]['identifier'], field(choice[0], 'connectionProperties', 'tunnelState') or 'unknown')
elif choice:
    print('MANY ' + ', '.join('%s (%s)' % (field(d, 'deviceProperties', 'name'), d['identifier']) for d in choice))
else:
    print('NONE')
PY
)
case "$pick" in
  NONE*) fail "no paired iPhone found. Connect it by cable once (Developer Mode on, trust this Mac)." 69 ;;
  MANY*) fail "several iPhones are paired: ${pick#MANY }. Run with --device <id>." 69 ;;
esac
device="${pick%% *}"
say "the iPhone: $device (${pick##* })"

# 5. Build. -allowProvisioningUpdates lets Xcode make a fresh 7-day profile for your Personal Team.
(cd "$src" && /opt/homebrew/bin/xcodegen generate --quiet) || fail "xcodegen couldn't generate the project."
log="$STATE_DIR/build.log"
if ! (cd "$src" && /usr/bin/nice -n 15 /usr/bin/xcrun xcodebuild -project AgentHub.xcodeproj -scheme AgentHub \
      -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$src/build/ios" -jobs 2 \
      -allowProvisioningUpdates build > "$log" 2>&1); then
  /usr/bin/grep -E "error:|Signing|provision" "$log" | /usr/bin/tail -5 || true
  if /usr/bin/grep -q "No Accounts" "$log"; then
    fail "Xcode isn't signed in to your Apple ID. Open Xcode › Settings › Accounts, add it, and the install happens on its own." 69
  fi
  fail "the build failed (see $log). Open Xcode › Settings › Accounts if your Apple ID needs signing in again."
fi
app=$(/usr/bin/find "$src/build/ios/Build/Products" -maxdepth 2 -type d -name 'AgentHub.app' -path '*-iphoneos/*' | /usr/bin/head -1)
[ -n "$app" ] || fail "the build finished but AgentHub.app wasn't found."

# 6. Install (a first try sometimes fails while the phone wakes; a second one works).
say "installing on $device..."
if ! /usr/bin/xcrun devicectl device install app --device "$device" "$app" > "$tmp/install.log" 2>&1; then
  say "install failed once; trying again in 10 seconds."
  /bin/sleep 10
  if ! /usr/bin/xcrun devicectl device install app --device "$device" "$app" > "$tmp/install.log" 2>&1; then
    /usr/bin/tail -3 "$tmp/install.log" || true
    fail "your iPhone wasn't reachable. Unlock it on the same Wi-Fi as this Mac, or plug it in, then renew again." 69
  fi
fi

# 7. The new expiry, read from the profile in the app just installed.
/usr/bin/security cms -D -i "$app/embedded.mobileprovision" > "$tmp/profile.plist" 2>/dev/null \
  || fail "installed, but the signing date couldn't be read."
expiry=$(/usr/bin/python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["ExpirationDate"])' "$tmp/profile.plist")
record true "Installed; signed until $expiry UTC." "$tmp/profile.plist"
say "installed. Signed until $expiry UTC."

# 8. A new build from the working tree becomes the snapshot that later renewals rebuild.
if [ "$from_tree" -eq 1 ] && [ "$src" = "$ROOT" ]; then
  /bin/mkdir -p "$SNAPSHOT"
  /usr/bin/rsync -a --delete --exclude build/ --exclude .git/ --exclude DerivedData/ --exclude '*.xcodeproj/' \
    --exclude .claude/ "$ROOT/" "$SNAPSHOT/"
  say "saved these sources as the snapshot for automatic renewals."
fi
if [ "$reason" = "auto" ]; then notify "Renewed the Agent Hub iPhone app. It works for another 7 days."; fi
