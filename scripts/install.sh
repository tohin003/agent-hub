#!/bin/bash
# One-time setup of Agent Hub on this Mac and your iPhone:
#   1. tmux (the terminal sessions), via Homebrew, if missing
#   2. Config/Local.xcconfig: your team and bundle ID prefix, this Mac's tailnet name, the pairing token
#                                                                                      (scripts/configure.sh)
#   3. the app icons from the mascot, with your agents' logos once the hub has read them (scripts/make-icons.sh)
#   4. the Mac hub in the menu bar, started at login, and the renewal check          (scripts/install-mac.sh)
#   5. the iPhone app, built, signed with your Personal Team and installed           (scripts/renew.sh --from-tree)
#
#   scripts/install.sh [--team ABCDE12345] [--prefix io.github.you] [--skip-phone]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
team_args=()
phone=1

while [ $# -gt 0 ]; do
  case "$1" in
    --team) team_args+=(--team "${2:-}"); shift ;;
    --prefix) team_args+=(--prefix "${2:-}"); shift ;;
    --skip-phone) phone=0 ;;
    -h|--help) /usr/bin/awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $1"; exit 64 ;;
  esac
  shift
done

command -v tmux >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install tmux
command -v xcodegen >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
"$ROOT/scripts/configure.sh" ${team_args[@]+"${team_args[@]}"}
"$ROOT/scripts/make-icons.sh"
"$ROOT/scripts/install-mac.sh"
if [ "$phone" -eq 1 ]; then
  "$ROOT/scripts/renew.sh" --from-tree --reason manual
fi
echo
echo "Agent Hub is set up. On the iPhone, open Agent Hub; it connects to this Mac over Tailscale."
echo "If iOS says the developer isn't trusted: Settings › General › VPN & Device Management › your Apple ID › Trust."
