#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the firstmate-bridge skill.
# Turns any Hermes install into a firstmate captain with a pi-agent crew.
# Idempotent: re-running is a no-op when everything is present. Zero prompts.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_REPO_URL="${FM_REPO_URL:-https://github.com/kunchenguid/firstmate.git}"
FM_HOME="${FM_HOME:-$HOME/Documents/firstmate}"
BACKEND_REF_FILE="$HERE/.firstmate-backend-ref"
CONFIG_DIR="$HOME/.hermes/config"
CONFIG_FILE="$CONFIG_DIR/firstmate.json"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

FAILED=0

echo "== firstmate-bridge install =="
echo "  FM_HOME   = $FM_HOME"
echo "  FM source = $FM_REPO_URL"
echo "  backend   = $(cat "$BACKEND_REF_FILE" 2>/dev/null || echo MISSING)"
echo ""

# 1. Detect OS deps
echo "[1/7] Detect OS deps"
for dep in git node npm; do
  if command -v "$dep" >/dev/null 2>&1; then ok "$dep present"; else fail "$dep MISSING — required"; fi
done
# session backend (herdr or tmux) — optional but recommended
if command -v herdr >/dev/null 2>&1; then
  ok "herdr present (session backend)"
elif command -v tmux >/dev/null 2>&1; then
  ok "tmux present (session backend)"
else
  warn "no herdr/tmux found — crew panes need a session backend; install herdr or tmux"
fi
[[ $FAILED -eq 1 ]] && { echo ""; echo "Install aborted: missing OS deps above."; exit 1; }

# 2. Clone + pin firstmate
echo "[2/7] Clone + pin firstmate"
if [[ -d "$FM_HOME/.git" ]]; then
  ok "firstmate already at $FM_HOME"
else
  info "cloning $FM_REPO_URL -> $FM_HOME"
  mkdir -p "$(dirname "$FM_HOME")"
  if git clone "$FM_REPO_URL" "$FM_HOME" >/dev/null 2>&1; then
    ok "cloned"
  else
    fail "git clone failed"; echo ""; echo "Install aborted."; exit 1
  fi
fi
BACKEND_PIN="$(cat "$BACKEND_REF_FILE" 2>/dev/null || echo "")"
if [[ -n "$BACKEND_PIN" ]]; then
  if git -C "$FM_HOME" rev-parse --verify "$BACKEND_PIN" >/dev/null 2>&1; then
    git -C "$FM_HOME" checkout --detach "$BACKEND_PIN" >/dev/null 2>&1
    ok "pinned to backend $BACKEND_PIN"
  else
    info "backend pin $BACKEND_PIN not local; fetching"
    git -C "$FM_HOME" fetch origin >/dev/null 2>&1
    if git -C "$FM_HOME" rev-parse --verify "$BACKEND_PIN" >/dev/null 2>&1; then
      git -C "$FM_HOME" checkout --detach "$BACKEND_PIN" >/dev/null 2>&1
      ok "pinned to backend $BACKEND_PIN"
    else
      warn "backend pin $BACKEND_PIN not found on remote — leaving firstmate at HEAD (update .firstmate-backend-ref)"
    fi
  fi
else
  warn ".firstmate-backend-ref empty — firstmate at HEAD"
fi

# 3. Prereqs (treehouse + tasks-axi + pi + jq)
echo "[3/7] Install prereqs"
export FM_HOME
# Let agents recover in any (non-root) environment: install treehouse into the
# user-writable bin dir instead of the hardcoded /config/.local/bin. The prereq
# script already honors $TREEHOUSE_DEST when set, so we just seed it here.
export TREEHOUSE_DEST="${TREEHOUSE_DEST:-$HOME/.local/bin}"
# Make the bridge importable everywhere Hermes runs (on sys.path via
# start-hermes.sh), so firstmate_prereqs.sh / firstmate_bridge.py resolve without
# a hard-coded /config/.hermes/scripts path.
mkdir -p "$HOME/.hermes/scripts"
cp "$HERE/firstmate_bridge.py" "$HOME/.hermes/scripts/firstmate_bridge.py"
ok "bridge module copied to $HOME/.hermes/scripts"
if bash "$HERE/firstmate_prereqs.sh" --fix; then
  ok "prereqs met"
else
  warn "prereqs incomplete — see output above"
fi

# 4. Pin crew harness = pi
echo "[4/7] Pin crew harness"
if [[ -f "$FM_HOME/config/crew-harness" ]]; then
  if [[ "$(cat "$FM_HOME/config/crew-harness")" == "pi" ]]; then
    ok "crew-harness already pi"
  else
    printf 'pi\n' > "$FM_HOME/config/crew-harness"
    ok "crew-harness -> pi (was $(tr -d '\n' < "$FM_HOME/config/crew-harness"))"
  fi
else
  mkdir -p "$FM_HOME/config"
  printf 'pi\n' > "$FM_HOME/config/crew-harness"
  ok "wrote crew-harness = pi"
fi

# 5. Pre-seed trust
echo "[5/7] Pre-seed worktree trust"
# pi: flat {"/abs/path": true} map at ~/.pi/agent/trust.json
PI_TRUST="$HOME/.pi/agent/trust.json"
if command -v pi >/dev/null 2>&1 || [[ -f "$PI_TRUST" ]]; then
  mkdir -p "$(dirname "$PI_TRUST")"
  python3 - "$PI_TRUST" "$FM_HOME" <<'PY'
import json, os, sys
path, fm_home = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: d = {}
# treehouse worktree root is ~/.treehouse (not hardcoded /config/.treehouse)
d[os.path.join(os.path.expanduser("~"), ".treehouse")] = True
d[fm_home] = True
json.dump(d, open(path, "w"), indent=2)
print(f"  OK   pi trust seeded: {list(d.keys())}")
PY
else
  info "pi not installed yet — trust seeding skipped (rerun after prereqs fix)"
fi
# claude (if present): trustedDirs in ~/.claude.json
if command -v claude >/dev/null 2>&1 || [[ -f "$HOME/.claude.json" ]]; then
  CLAUDE_JSON="$HOME/.claude.json"
  if [[ -f "$CLAUDE_JSON" ]]; then
    python3 - "$CLAUDE_JSON" "$FM_HOME" <<'PY'
import json, os, sys
path, fm_home = sys.argv[1], sys.argv[2]
d = json.load(open(path))
td = d.setdefault("trustedDirs", [])
treehouse_root = os.path.join(os.path.expanduser("~"), ".treehouse")
for add in (treehouse_root, fm_home):
    if add not in td: td.append(add)
json.dump(d, open(path, "w"))
print("  OK   claude trustedDirs seeded")
PY
  fi
fi

# 6. Write config
echo "[6/7] Write firstmate config"
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
  ok "config already exists: $CONFIG_FILE"
else
  printf '{\n  "homes": {\n    "primary": "%s"\n  }\n}\n' "$FM_HOME" > "$CONFIG_FILE"
  ok "wrote $CONFIG_FILE"
fi

# 7. Verify
echo "[7/7] Verify"
export PATH="$PATH:$HOME/.local/bin"
if bash "$HERE/firstmate_prereqs.sh" 2>&1 | grep -q "ALL REQUIRED PREREQUISITES MET"; then
  ok "bridge ready to dispatch"
  echo ""
  echo "== DONE =="
  echo "  Skill:    $HERE"
  echo "  FM_HOME:  $FM_HOME"
  echo "  Dispatch: use the firstmate-bridge skill (snapshot() / dispatch())"
  exit 0
else
  fail "prereq verification failed — run $HERE/firstmate_prereqs.sh --fix manually"
  exit 1
fi
