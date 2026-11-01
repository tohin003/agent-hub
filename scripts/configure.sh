#!/bin/bash
# Writes Config/Local.xcconfig (git-ignored) with your own values, so both apps are built for your Mac and phone:
#   - your Personal Team (signing), from --team, an existing Local.xcconfig, or Xcode's signed-in accounts
#   - your bundle ID prefix (bundle IDs are unique per Apple ID), from --prefix, an existing Local.xcconfig, or
#     io.github.<your Mac user name>
#   - this Mac's tailnet name and address (from `tailscale status --json`), which the phone connects to
#   - the pairing token in ~/.agenthub/token (created here if missing; the Mac hub uses the same file)
#
#   scripts/configure.sh [--team ABCDE12345] [--prefix io.github.you] [--port 7860]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$ROOT/Config/Local.xcconfig"
AGENTHUB="$HOME/.agenthub"
TOKEN_FILE="$AGENTHUB/token"
team=""
prefix=""
port="7860"

say() { printf 'configure.sh: %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="${2:-}"; shift ;;
    --prefix) prefix="${2:-}"; shift ;;
    --port) port="${2:-7860}"; shift ;;
    -h|--help) /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) say "unknown option: $1"; exit 64 ;;
  esac
  shift
done

# 1. The pairing token (32 random bytes as hex), owner-only.
/bin/mkdir -p "$AGENTHUB"
/bin/chmod 700 "$AGENTHUB"
if [ ! -s "$TOKEN_FILE" ]; then
  /usr/bin/openssl rand -hex 32 > "$TOKEN_FILE"
  /bin/chmod 600 "$TOKEN_FILE"
  say "created a new pairing token in $TOKEN_FILE"
fi
token=$(/usr/bin/tr -d '[:space:]' < "$TOKEN_FILE")

# 2. The team: --team, then the current Local.xcconfig, then Xcode's signed-in accounts (a Personal Team first).
if [ -z "$team" ] && [ -f "$LOCAL" ]; then
  team=$(/usr/bin/sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' "$LOCAL" | /usr/bin/head -1)
fi
if [ -z "$team" ]; then
  team=$(/usr/bin/defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -I -c '
import plistlib, sys
try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
teams = [t for ts in (prefs.get("IDEProvisioningTeamByIdentifier") or {}).values() for t in ts]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))
print(teams[0].get("teamID", "") if teams else "")
' || true)
fi
if [ -z "$team" ]; then
  say "no team found. Sign in to Xcode (Settings › Accounts › +, your Apple ID), or find your team's ID there, then run:"
  say "  scripts/configure.sh --team <TEAMID>"
  exit 66
fi

# 3. This Mac on the tailnet.
tailscale_cli=""
for candidate in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  if [ -x "$candidate" ]; then tailscale_cli="$candidate"; break; fi
done
hosts=""
if [ -n "$tailscale_cli" ]; then
  hosts=$("$tailscale_cli" status --json 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
try:
    me = json.load(sys.stdin).get("Self", {})
except Exception:
    sys.exit(0)
names = []
dns = (me.get("DNSName") or "").rstrip(".")
if dns:
    names.append(dns)
names += [ip for ip in me.get("TailscaleIPs", []) if "." in ip]
print(",".join(names))
' || true)
fi
if [ -z "$hosts" ]; then
  say "warning: Tailscale isn't running, so the phone can't find this Mac yet. Start Tailscale and run this again."
fi
mac_name=$(/usr/sbin/scutil --get ComputerName 2>/dev/null || echo Mac)

# 4. The bundle ID prefix: --prefix, then the current Local.xcconfig, then io.github.<your Mac user name>.
if [ -z "$prefix" ] && [ -f "$LOCAL" ]; then
  prefix=$(/usr/bin/sed -n 's/^AGENTHUB_BUNDLE_PREFIX *= *\([A-Za-z0-9.-]*\).*/\1/p' "$LOCAL" | /usr/bin/head -1)
fi
if [ -z "$prefix" ]; then
  prefix="io.github.$(/usr/bin/id -un | /usr/bin/tr -cd 'A-Za-z0-9-' | /usr/bin/tr 'A-Z' 'a-z')"
fi

umask 077
/bin/cat > "$LOCAL" <<EOF
// Written by scripts/configure.sh on $(/bin/date '+%Y-%m-%d %H:%M'). Git-ignored: it holds your pairing token.
DEVELOPMENT_TEAM = $team
AGENTHUB_BUNDLE_PREFIX = $prefix
AGENTHUB_HOSTS = $hosts
AGENTHUB_PORT = $port
AGENTHUB_TOKEN = $token
AGENTHUB_MAC_NAME = $mac_name
EOF
say "wrote $LOCAL (team $team, prefix $prefix, hosts ${hosts:-none}, port $port)"
