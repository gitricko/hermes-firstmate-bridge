#!/usr/bin/env bash
# firstmate_prereqs.sh — verify everything firstmate-bridge needs to dispatch a crew.
#
# Checks (each PASS/FAIL/WARN):
#   1. firstmate code root + bin/ present
#   2. FM_HOME resolves (explicit, fail-closed)
#   3. python3 + firstmate_bridge module importable
#   4. pi (Pi-Agent) harness present (pinned crewmate harness)
#   5. backend session provider: herdr detected (primary) — tmux optional
#   6. treehouse worktree provider (REQUIRED by every session-provider backend)
#   7. jq (required by herdr backend JSON parsing) — --fix installable via apt/brew
#   8. config/crew-harness == pi (the pinned default)
#   9. tasks-axi (backlog/completion-gate backend, required for teardown)
#   9b. pi harness (pinned crewmate: Pi-Agent)
#   10. pi-agent LLM config (WARN only — see references/pi-models.example.json + pi-settings.example.json)
#   11. fm-fleet-snapshot.sh --json returns valid JSON
#
# Note: the claude CLI is informational only — a valid but NON-default firstmate
# harness; its absence never fails a check.
#
# Exit code: 0 if all REQUIRED checks pass, 1 otherwise.
# Usage: firstmate_prereqs.sh [--fix]   (--fix installs treehouse + tasks-axi + pi
#                                       and pins config/crew-harness = pi)

set -u
FM_HOME="${FM_HOME:-$HOME/Documents/firstmate}"
FM_ROOT="${FM_ROOT_OVERRIDE:-$FM_HOME}"
BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-/config/.hermes/scripts/firstmate_bridge.py}"
FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
fixed(){ printf '  \033[32mFIXED\033[0m %s\n' "$1"; if [[ $fail -gt 0 ]]; then fail=$((fail-1)); fi; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

echo "firstmate-bridge prerequisite check"
echo "  FM_HOME = $FM_HOME"
echo "  FM_ROOT = $FM_ROOT"
echo ""

echo "[1] firstmate code root + bin/"
if [[ -d "$FM_ROOT/bin" && -x "$FM_ROOT/bin/fm-spawn.sh" && -x "$FM_ROOT/bin/fm-fleet-snapshot.sh" ]]; then
  ok "bin/ present and executable"
else
  bad "bin/ missing or fm-spawn.sh/fm-fleet-snapshot.sh not executable at $FM_ROOT"
fi

echo "[2] FM_HOME resolves"
if [[ -d "$FM_HOME" ]]; then
  ok "FM_HOME exists"
else
  bad "FM_HOME $FM_HOME does not exist"
fi

echo "[3] python3 + firstmate_bridge module"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import importlib.util,sys; sys.path.insert(0,'$(dirname "$BRIDGE_SCRIPT")'); import firstmate_bridge" 2>/dev/null; then
    ok "firstmate_bridge.py imports"
  else
    bad "firstmate_bridge.py import failed ($(dirname "$BRIDGE_SCRIPT"))"
  fi
else
  bad "python3 not found"
fi

echo "[4] pi CLI (pinned crewmate harness)"
if command -v pi >/dev/null 2>&1; then
  ok "pi $(pi --version 2>&1 | head -1)"
else
  bad "pi not on PATH — pinned crewmate harness (config/crew-harness = pi)"
  if [[ $FIX -eq 1 ]]; then
    info "attempting npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    if npm install -g --ignore-scripts @earendil-works/pi-coding-agent >/dev/null 2>&1; then
      fixed "pi installed via npm"
    else
      bad "pi install failed (needs node/npm on PATH)"
    fi
  else
    info "rerun with --fix to install pi (npm install -g --ignore-scripts @earendil-works/pi-coding-agent)"
  fi
fi

# claude is a valid but NON-default firstmate harness — informational only (never a required check).
if command -v claude >/dev/null 2>&1; then
  info "claude $(claude --version 2>&1 | head -1) present (optional harness, not the pinned default)"
else
  info "claude not on PATH (optional harness — crew-harness pins pi, not claude)"
fi

echo "[5] backend session provider"
if command -v herdr >/dev/null 2>&1; then
  info "herdr $(herdr --version 2>&1 | head -1) — primary auto-detected backend"
elif command -v tmux >/dev/null 2>&1; then
  warn "tmux present but herdr absent — would need --backend tmux"
else
  bad "no session provider (herdr/tmux) on PATH"
fi

echo "[6] treehouse worktree provider (REQUIRED)"
if command -v treehouse >/dev/null 2>&1; then
  ok "treehouse $(treehouse --version 2>&1 | head -1)"
else
  bad "treehouse MISSING — every session-provider backend needs it to acquire a worktree"
  if [[ $FIX -eq 1 ]]; then
    info "attempting install via $FM_ROOT/bin/fm-install-treehouse.sh"
    if [[ -x "$FM_ROOT/bin/fm-install-treehouse.sh" ]]; then
      DEST="${TREEHOUSE_DEST:-/config/.local/bin}"
      mkdir -p "$DEST"
      if "$FM_ROOT/bin/fm-install-treehouse.sh" "$DEST"; then
        # make sure it's on PATH for this shell
        export PATH="$DEST:$PATH"
        if command -v treehouse >/dev/null 2>&1; then
          fixed "treehouse installed to $DEST -> $(command -v treehouse)"
        else
          warn "installed but not on PATH; add $DEST to PATH"
        fi
      else
        bad "fm-install-treehouse.sh failed"
      fi
    else
      bad "fm-install-treehouse.sh not found at $FM_ROOT/bin"
    fi
  else
    info "rerun with --fix to install treehouse via firstmate's pinned installer"
  fi
fi

echo "[7] jq (herdr backend JSON parsing)"
if command -v jq >/dev/null 2>&1; then
  ok "jq present"
else
  bad "jq missing — herdr backend requires it to parse JSON output"
  if [[ $FIX -eq 1 ]]; then
    info "attempting apt-get install -y jq"
    if apt-get install -y jq >/dev/null 2>&1; then
      fixed "jq installed via apt"
    else
      info "apt failed (may need sudo/root); attempting brew install jq"
      if command -v brew >/dev/null 2>&1 && brew install jq >/dev/null 2>&1; then
        fixed "jq installed via brew"
      else
        bad "jq install failed (needs apt or brew available)"
      fi
    fi
  else
    info "rerun with --fix to install jq (apt-get install -y jq)"
  fi
fi

echo "[8] config/crew-harness == pi (pinned crewmate harness)"
if [[ -f "$FM_HOME/config/crew-harness" ]]; then
  CH="$(cat "$FM_HOME/config/crew-harness")"
  if [[ "$CH" == "pi" || "$CH" == "pi-signed" ]]; then
    ok "crew-harness = $CH (pinned: Pi-Agent)"
  else
    warn "crew-harness = $CH (not pi) — bridge DEFAULT_HARNESS is pi; align if pi is intended"
  fi
else
  bad "no config/crew-harness — firstmate would resolve 'unknown'; pin it to pi"
  if [[ $FIX -eq 1 ]]; then
    info "writing $FM_HOME/config/crew-harness = pi"
    mkdir -p "$FM_HOME/config"
    printf 'pi\n' > "$FM_HOME/config/crew-harness"
    fixed "crew-harness pinned to pi"
  else
    info "rerun with --fix to pin crew-harness = pi"
  fi
fi

echo "[9] tasks-axi (backlog/completion-gate backend, required for teardown)"
if command -v tasks-axi >/dev/null 2>&1; then
  TV="$(tasks-axi --version 2>&1 | head -1)"
  if python3 -c "import sys; v='$TV'.split()[0] if '$TV' else '0'; 
try:
    from packaging.version import parse
except Exception:
    parse=lambda x:tuple(int(i) for i in x.split('.')[:3])
sys.exit(0 if parse(v)>=parse('0.2.4') else 1)" 2>/dev/null; then
    ok "tasks-axi $TV (>=0.2.4, firstmate completion gate + backlog backend)"
  else
    bad "tasks-axi $TV present but <0.2.4 — firstmate requires >=0.2.4"
    if [[ $FIX -eq 1 ]]; then
      info "attempting npm install -g tasks-axi"
      if npm install -g tasks-axi >/dev/null 2>&1; then
        fixed "tasks-axi upgraded via npm"
      else
        bad "npm install -g tasks-axi failed (needs node/npm on PATH)"
      fi
    else
      info "rerun with --fix to install via npm (npm install -g tasks-axi)"
    fi
  fi
else
  bad "tasks-axi not on PATH — required for teardown completion gate"
  if [[ $FIX -eq 1 ]]; then
    info "attempting npm install -g tasks-axi"
    if npm install -g tasks-axi >/dev/null 2>&1; then
      fixed "tasks-axi installed via npm"
    else
      bad "npm install -g tasks-axi failed (needs node/npm on PATH)"
    fi
  else
    info "rerun with --fix to install via npm (npm install -g tasks-axi)"
  fi
fi

echo "[9b] pi harness (pinned crewmate: Pi-Agent)"
if command -v pi >/dev/null 2>&1; then
  ok "pi $(pi --version 2>&1 | head -1)"
else
  bad "pi not on PATH — pinned crewmate harness (config/crew-harness = pi)"
  if [[ $FIX -eq 1 ]]; then
    info "attempting npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    if npm install -g --ignore-scripts @earendil-works/pi-coding-agent >/dev/null 2>&1; then
      fixed "pi installed via npm"
    else
      bad "pi install failed (needs node/npm on PATH)"
    fi
  else
    info "rerun with --fix to install pi (npm install -g --ignore-scripts @earendil-works/pi-coding-agent)"
  fi
fi

echo "[10] pi-agent LLM config (WARN — agent awareness only, not auto-installed)"
PI_AGENT_DIR="$HOME/.pi/agent"
PI_MODELS="$PI_AGENT_DIR/models.json"
PI_SETTINGS="$PI_AGENT_DIR/settings.json"
MISSING=()
[[ -f "$PI_MODELS" ]]  || MISSING+=("$PI_MODELS")
[[ -f "$PI_SETTINGS" ]] || MISSING+=("$PI_SETTINGS")
if [[ ${#MISSING[@]} -eq 0 ]]; then
  ok "models.json + settings.json present"
else
  printf '  \033[33mWARN\033[0m %s\n' "pi-agent LLM config missing"
  if [[ ${#MISSING[@]} -eq 1 ]]; then
    MSG="Missing: ${MISSING[0]}"
  else
    MSG="Missing: ${MISSING[0]} (${MISSING[1]})"
  fi
  printf '       %s\n' "$MSG"
  printf '       This will cause pi-agent to use default models that may not match your environment.\n'
  printf '       To configure, write the following files:\n'
  printf '\n'
  # Locate references/ relative to this script (works for any install layout)
  # Portable realpath: use realpath if available, else resolve manually
  if command -v realpath >/dev/null 2>&1; then
    _prereqs_self="$(realpath "${BASH_SOURCE[0]}")" 2>/dev/null
  else
    # Fallback: resolve $0 without symlinks (works on macOS/Linux without readlink -f)
    case "${BASH_SOURCE[0]}" in
      /*) _prereqs_self="${BASH_SOURCE[0]}" ;;
      *)  _prereqs_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" ;;
    esac
  fi
  _refs_dir="$(cd "$(dirname "$_prereqs_self")" && pwd)/references"
  printf '       mkdir -p "$HOME/.pi/agent"\n'
  printf '\n'
  printf '       # %s\n' "$PI_MODELS"
  printf '       cat > %s <<'"'"'EOF'"'"'\n' "$PI_MODELS"
  if [[ -f "$_refs_dir/models.json" ]]; then
    cat "$_refs_dir/models.json"
  else
    printf '  # (see references/models.json in the firstmate-bridge repo)\n'
  fi
  printf 'EOF\n'
  printf '\n'
  printf '       # %s\n' "$PI_SETTINGS"
  printf '       cat > %s <<'"'"'EOF'"'"'\n' "$PI_SETTINGS"
  if [[ -f "$_refs_dir/settings.json" ]]; then
    cat "$_refs_dir/settings.json"
  else
    printf '  # (see references/settings.json in the firstmate-bridge repo)\n'
  fi
  printf 'EOF\n'
  printf '\n'
  info "see references/models.json + references/settings.json in this repo"
fi

echo "[11] fm-fleet-snapshot.sh --json"
if FM_HOME="$FM_HOME" python3 -c "
import importlib.util,sys,json
sys.path.insert(0,'$(dirname "$BRIDGE_SCRIPT")')
import firstmate_bridge as fb
s=fb.snapshot()
assert s.get('schema')=='fm-fleet-snapshot.v1', s.get('schema')
print('  schema:', s['schema'])
" 2>/dev/null; then
  ok "snapshot returns fm-fleet-snapshot.v1"
else
  bad "snapshot() did not return valid JSON"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  echo "RESULT: \033[32mALL REQUIRED PREREQUISITES MET\033[0m — bridge ready to dispatch."
  exit 0
else
  echo "RESULT: \033[31m$fail REQUIRED CHECK(S) FAILED\033[0m — dispatch will fail until resolved."
  exit 1
fi
