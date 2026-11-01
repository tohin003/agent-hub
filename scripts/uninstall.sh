#!/bin/bash
# Removes Agent Hub from this Mac: stops the hub and the renewal check, removes their LaunchAgents and the app.
#   scripts/uninstall.sh          keeps ~/.agenthub (token, sessions, renewal state) and the logs
#   scripts/uninstall.sh --all    also removes ~/.agenthub and ~/Library/Logs/AgentHub, and kills hub tmux sessions
# The iPhone app stays until you delete it on the phone.
set -euo pipefail
DOMAIN="gui/$(/usr/bin/id -u)"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX=$(/usr/bin/sed -n 's/^AGENTHUB_BUNDLE_PREFIX *= *\([A-Za-z0-9.-]*\).*/\1/p' "$ROOT_DIR/Config/Local.xcconfig" "$ROOT_DIR/Config/Base.xcconfig" 2>/dev/null | /usr/bin/head -1)
for label in "${PREFIX:-io.github.agenthub}.AgentHubMac" "${PREFIX:-io.github.agenthub}.AgentHub.renew"; do
  /bin/launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
/bin/rm -rf "$HOME/Applications/Agent Hub.app"
if [ "${1:-}" = "--all" ]; then
  /opt/homebrew/bin/tmux -L agenthub kill-server >/dev/null 2>&1 || true
  /bin/rm -rf "$HOME/.agenthub" "$HOME/Library/Logs/AgentHub"
fi
echo "uninstall.sh: removed."
