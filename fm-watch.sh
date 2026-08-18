#!/usr/bin/env bash
# fm-watch.sh — Captain-side crewmate watcher for firstmate-bridge.
#
# FIX (v2.1): monitors for ACTIONABLE states, not just terminal ones.
# The previous peer watcher only watched for done/failed/blocked and silently
# timed out when a crewmate parked at the no-mistakes review gate
# (state=parked, pending_decision=true). This watcher treats every state
# transition as news and fires IMMEDIATELY on parked/needs-decision so the
# captain can feed the gate instead of waiting on a silent timeout.
#
# Exit codes:
#   0  terminal  (done | failed | blocked)  -> relay the PR URL / failure
#   3  parked    (pending_decision)         -> FEED THE GATE, do not re-watch
#   2  timeout   (no transition within N secs; still running, re-arm to continue)
#   1  error     (snapshot malformed / task not found)
#
# Usage:
#   fm-watch.sh <task-id-prefix> [timeout_seconds]
#
# Required: FM_HOME resolvable (see skill), python3, jq.
set -uo pipefail

PREFIX="${1:?usage: fm-watch.sh <task-id-prefix> [timeout_seconds]}"
TIMEOUT="${2:-1800}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_HOME resolution mirrors the module: env > config > discovery.
if [[ -z "${FM_HOME:-}" ]]; then
  FM_HOME="$(python3 -c "
import json,os
p=os.path.expanduser('~/.hermes/config/firstmate.json')
try:
    print(json.load(open(p))['homes']['primary'])
except Exception:
    print('')
" 2>/dev/null)"
fi
FM_HOME="${FM_HOME:-$HOME/Documents/firstmate}"

elapsed=0
last_event=""
while [[ $elapsed -lt $TIMEOUT ]]; do
  SNAP="$(cd "$FM_HOME" && FM_HOME="$FM_HOME" ./bin/fm-fleet-snapshot.sh --json 2>/dev/null)"
  if [[ -z "$SNAP" ]]; then
    echo "ERROR: fm-fleet-snapshot returned nothing (FM_HOME=$FM_HOME)" >&2
    exit 1
  fi
  TASK="$(printf '%s' "$SNAP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
prefix='${PREFIX//\'/}'
for t in d.get('tasks',[]):
    if t['id'].startswith(prefix):
        print(json.dumps(t)); break
")"
  if [[ -z "$TASK" ]]; then
    echo "ERROR: no task with prefix '$PREFIX'" >&2
    exit 1
  fi

  STATE="$(printf '%s' "$TASK" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['current_state']['state'])")"
  PEND="$(printf '%s' "$TASK" | python3 -c "import json,sys;d=json.load(sys.stdin);print(str(d['hints']['pending_decision']).lower())")"
  EVENT="$(printf '%s' "$TASK" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['hints']['last_event_text'][:200])")"

  # NEW EVENT -> always surface it (any transition is news).
  if [[ "$EVENT" != "$last_event" && -n "$EVENT" ]]; then
    last_event="$EVENT"
    echo "[$(date -u +%H:%M:%SZ)] state=$STATE pending_decision=$PEND :: $EVENT"
  fi

  # TERMINAL -> relay result.
  case "$STATE" in
    done|failed|blocked)
      echo "TERMINAL: $STATE"
      PR="$(printf '%s' "$TASK" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['pr']['url'] or '')")"
      echo "PR_URL=${PR:-none}"
      echo "REPORT=$(printf '%s' "$TASK" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['paths']['report']['path'] or '')")"
      exit 0
      ;;
    parked)
      echo "PARKED: crewmate at review gate awaiting decision. FEED the gate (no-mistakes axi respond) or steer/fm-send; do NOT just re-watch."
      printf '%s' "$TASK" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for dec in d['hints'].get('open_decisions',[]):
    print('  DECISION key=',dec.get('key'),'verb=',dec.get('verb'))
    print('  ',dec.get('summary','')[:300])
"
      exit 3
      ;;
  esac

  sleep 15
  elapsed=$((elapsed+15))
done
echo "TIMEOUT: no terminal/parked state within ${TIMEOUT}s (still running). Re-arm with a new fm-watch.sh to continue."
exit 2
