#!/bin/bash
# Run by launchd every 30 minutes (and at login). Installs the iPhone app the first time (as soon as Xcode is signed
# in and the iPhone is nearby), then renews it when its 7-day signing is about to run out:
#   - within 30 hours of the end date, or already past it;
#   - not more often than every 45 minutes after a failure;
#   - when Xcode reused a cached profile last time (the date didn't move), right after the end date instead.
# The work itself is scripts/renew.sh --reason auto. Logs go to ~/Library/Logs/AgentHub/renew.log.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/.agenthub/renew/state.json"
# Switched off in Agent Hub's menu (or the app's Mac tab): renew only when asked.
[ -f "$HOME/.agenthub/renew/auto-off" ] && exit 0
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

decision=$(/usr/bin/python3 -I - "$STATE" <<'PY'
import datetime, json, sys
def parse(value):
    if not value:
        return None
    return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
try:
    state = json.load(open(sys.argv[1]))
except Exception:
    state = {}
now = datetime.datetime.now(datetime.timezone.utc)
expires = parse(state.get('profileExpires'))
last = parse(state.get('lastAttempt'))
if expires is None:
    # Never installed yet: try the first install (it needs Xcode signed in and the iPhone nearby).
    if last and (now - last).total_seconds() < 45 * 60:
        print('skip first-install-backoff')
    else:
        print('first-install')
    sys.exit(0)
hours_left = (expires - now).total_seconds() / 3600
if last and not state.get('lastSucceeded', True) and (now - last).total_seconds() < 45 * 60:
    print('skip backoff %.1f' % hours_left)
elif state.get('expiryMoved') is False and hours_left > -0.05 and state.get('lastSucceeded'):
    # Xcode reused the cached profile last time: try again just after it ends.
    print('skip wait-for-end %.1f' % hours_left)
elif hours_left <= 30:
    print('renew %.1f' % hours_left)
else:
    print('skip fine %.1f' % hours_left)
PY
)

case "$decision" in
  first-install)
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') renew-check: not installed on the iPhone yet; trying the first install."
    exec "$ROOT/scripts/renew.sh" --from-tree --reason auto
    ;;
  renew*)
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') renew-check: ${decision#renew } hours left; renewing."
    exec "$ROOT/scripts/renew.sh" --reason auto
    ;;
  *)
    exit 0
    ;;
esac
