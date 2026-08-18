#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the firstmate-bridge skill.
# Turns any Hermes install into a firstmate captain with a pi-agent crew.
# Idempotent: re-running is a no-op when everything is present. Zero prompts.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_REPO_URL="${FM_REPO_URL:-https://github.com/kunchenguid/firstmate.git}"
FM_HOME="${FM_HOME:-$HOME/Documents/firstmate}"
REF_FILE="$HERE/.firstmate-ref"
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
echo "  pin       = $(cat "$REF_FILE" 2>/dev/null || echo MISSING)"
echo ""

# 1. Detect OS deps
echo "[1/8] Detect OS deps"
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
echo "[2/8] Clone + pin firstmate"
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
PIN="$(cat "$REF_FILE" 2>/dev/null || echo "")"
if [[ -n "$PIN" ]]; then
  if git -C "$FM_HOME" rev-parse --verify "$PIN" >/dev/null 2>&1; then
    git -C "$FM_HOME" checkout --detach "$PIN" >/dev/null 2>&1
    ok "pinned to $PIN"
  else
    info "pin $PIN not local; fetching"
    git -C "$FM_HOME" fetch origin >/dev/null 2>&1
    if git -C "$FM_HOME" rev-parse --verify "$PIN" >/dev/null 2>&1; then
      git -C "$FM_HOME" checkout --detach "$PIN" >/dev/null 2>&1
      ok "pinned to $PIN"
    else
      warn "pin $PIN not found on remote — leaving firstmate at HEAD (update .firstmate-ref)"
    fi
  fi
else
  warn ".firstmate-ref empty — firstmate at HEAD"
fi

# 3. Prereqs (treehouse + tasks-axi + pi + jq)
echo "[3/8] Install prereqs"
export FM_HOME
if bash "$HERE/firstmate_prereqs.sh" --fix; then
  ok "prereqs met"
else
  warn "prereqs incomplete — see output above"
fi

# 4. Install pi-agent LLM config
PI_AGENT_DIR="$HOME/.pi/agent"
echo "[4/8] Install pi-agent LLM config"
if mkdir -p "$PI_AGENT_DIR" 2>/dev/null; then
  for f in models.json settings.json; do
    src="$HERE/references/pi-$f"
    dst="$PI_AGENT_DIR/$f"
    if [[ -f "$dst" && ! -f "$dst.bridge-bak" ]]; then
      cp "$dst" "$dst.bridge-bak"
      info "backed up existing $dst -> $dst.bridge-bak"
    fi
    if [[ -f "$src" ]]; then
      cp "$src" "$dst"
      ok "installed $dst"
    else
      warn "source $src not found, skipping $dst"
    fi
  done
  info "Installed pi-agent LLM config: $PI_AGENT_DIR/models.json + settings.json"
else
  warn "cannot create $PI_AGENT_DIR — skipping pi-agent config install"
fi

# 5. Pin crew harness = pi
echo "[5/8] Pin crew harness"
if [[ -f "$FM_HOME/config/crew-harness" ]]; then
  if [[ "$(cat "$FM_HOME/config/crew-harness")" == "pi" ]]; then
    ok "crew-harness already pi"
  else
    printf 'pi\n' > "$FM_HOME/config/crew-harness"
    ok "crew-harness -> pi (was $(cat "$FM_HOME/config/crew-harness" | tr -d '\n'))"
  fi
else
  mkdir -p "$FM_HOME/config"
  printf 'pi\n' > "$FM_HOME/config/crew-harness"
  ok "wrote crew-harness = pi"
fi

# 6. Pre-seed trust
echo "[6/8] Pre-seed worktree trust"
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
d["/config/.treehouse"] = True          # covers every future treehouse worktree root
d[fm_home] = True                        # the project itself
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
for add in ("/config/.treehouse", fm_home):
    if add not in td: td.append(add)
json.dump(d, open(path, "w"))
print("  OK   claude trustedDirs seeded")
PY
  fi
fi

# 7. Write config
echo "[7/8] Write firstmate config"
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
  ok "config already exists: $CONFIG_FILE"
else
  printf '{\n  "homes": {\n    "primary": "%s"\n  }\n}\n' "$FM_HOME" > "$CONFIG_FILE"
  ok "wrote $CONFIG_FILE"
fi

# 8. Verify
echo "[8/8] Verify"
export PATH="$PATH:/config/.local/bin"
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
