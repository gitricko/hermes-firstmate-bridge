---
name: firstmate-bridge
description: Dispatch code-work to firstmate crews; Hermes stays captain.
version: 2.1.0
author: Gram Ricko (gitricko), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [firstmate, crew, delegation, captain, herdr]
    related_skills: [computer-use]
---

# firstmate-bridge

Hermes is the **captain**: it owns chat intake, intent parsing, durable memory
(mnemon + llm-wiki), scheduling, and delegation. firstmate owns the **crew
backend**: herdr/tmux spawning, treehouse worktrees, no-mistakes gate, merge
authority. This skill is the thin glue between them — a Python module plus the
firstmate bin/ scripts it wraps.

## When to Use

- Captain sends a code-work verb in a project context: fix, build, refactor,
  add, migrate, audit, ship, bump, deprecate.
- Captain explicitly names firstmate ("use firstmate to…", "send a crewmate").
- Captain asks about fleet state (active tasks, PRs waiting, secondmates).
- A herdr terminal is detected (`HERDR_ENV=1` / `$TMUX` /
  `CMUX_WORKSPACE_ID`) and a code-work request is present → offer firstmate as
  the default suggestion; never auto-dispatch without explicit "use firstmate".
- When Hermes runs inside herdr (or tmux/cmux), `dispatch()` defaults the
  crewmate backend to that same multiplexer so the crew stays visible where the
  captain already is. Explicit `backend=` argument always overrides.

Don't use for: plain chat, questions, ops requests, or work inside `~/.hermes`
glue files — crewmates never touch files outside their project worktree, and
`~/.hermes` is not a registrable project (firstmate hard rule).

## Prerequisites

- firstmate cloned with `bin/` on an executable path; `FM_HOME` resolvable
  (env, `~/.hermes/config/firstmate.json` `homes.primary`, or auto-discovery
  from the repo marker — see module `resolve_home`).
- Pinned crewmate harness in `config/crew-harness` (default: `pi` / Pi-Agent).
- Firstmate-family binaries on PATH: `treehouse` (worktree provider, required
  by every backend), `tasks-axi` (completion gate / teardown), `jq` (herdr
  JSON), plus the selected harness binary (`pi`, `claude`, …).
- Verify with `terminal(command="firstmate_prereqs.sh [--fix]")` before any
  dispatch.

## How to Run

1. Load this skill before delegating.
2. Run `terminal(command="python3 <skill_dir>/firstmate_bridge.py snapshot")`
   to read fleet state (or `snapshot()` from Python).
3. For a new crew task, call `dispatch(request, project, harness="pi", ...)`
   via `execute_code` with `from firstmate_bridge import *`; the module is bundled
   in this skill dir at `firstmate_bridge.py` (a live copy is also at
   `~/.hermes/scripts/firstmate_bridge.py`). Prereq checker:
   `firstmate_prereqs.sh` (also bundled here).
4. Watch for the crewmate's report/PR; report the PR URL in full
   `https://…` form. Merge only on explicit captain word.

## Quick Reference

| Call | Firstmate wrapper | Notes |
|---|---|---|
| `snapshot()` | `fm-fleet-snapshot.sh --json` | Schema `fm-fleet-snapshot.v1` |
| `detect_runtime()` | env markers | herdr / tmux / cmux / unknown |
| `resolve_home(name)` | FM_HOME resolution | fail closed on ambiguity |
| `dispatch(req, project, ...)` | `fm-brief.sh` + `fm-spawn.sh` | kind ship/scout; harness pi default |
| `steer(id, msg)` / `decide(id, key, ans)` | `fm-send.sh` | `--resolve-key` for decisions |
| `interrupt(id)` / `exit_task(id)` | `fm-control.sh` | stop a live crewmate |
| `merge(id, pr_url)` | `fm-pr-merge.sh` | GATED: captain word only |
| `teardown(id)` | `fm-teardown.sh` | needs `tasks-axi` installed |

## no-mistakes gate (mode)

Ship tasks carry a **delivery mode** (`fm-brief.sh --mode <no-mistakes|direct-PR|local-only>`).
The module's `dispatch()` defaults to `mode="no-mistakes"` — do NOT override to
`direct-PR` unless the captain explicitly asks (a `direct-PR` short-circuits the
gate). `no-mistakes` runs the full pipeline: implement → /no-mistakes review →
push → PR → merge authority. See `references/no-mistakes-gate.md` for the full
workflow, install, config, and pitfalls (this is correct as of v1.48.0).

## Procedure

1. **Classify**: is this code-work in a registrable project? If it's
   `~/.hermes` glue, answer directly; do not dispatch.
2. **Check prereqs**: run `firstmate_prereqs.sh`; it must report ALL REQUIRED
   PREREQUISITES MET before dispatch.
3. **Resolve home**: `resolve_home("primary")` — always require an explicit
   FM_HOME per call; never infer a named secondmate (Phase 5).
4. **Confirm intent** in one sentence: project · action · kind (ship/scout) ·
   mode · harness · home.
5. **Dispatch** in the background
   (`dispatch(request, project, kind, harness="pi", timeout=600)`) so the
   session keeps working; do not block on the crewmate.
6. **Arm a watcher** with the bundled `fm-watch.sh` (background +
   `notify_on_complete=true`); never poll in a blocking loop. Unlike a bare
   terminal-state loop, `fm-watch.sh` treats **every state transition as
   news** and exits `3` on `parked`/`pending_decision` so the captain can feed
   the no-mistakes gate instead of waiting on a silent timeout. Exit codes:
   `0` terminal (done/failed/blocked + PR URL), `3` parked (feed the gate),
   `2` timeout (re-arm to continue), `1` error.
7. **Relay** task_id, backend, and the PR URL or report path. Failure is news —
   report it honestly.
8. **Teardown** completed tasks with `teardown(id)`; lifecycle closes cleanly
   only when `tasks-axi` is present.

## Pitfalls

- **Trust prompts**: firstmate's worktrees are fresh paths; harnesses prompt
  "trust this folder?" once. Pre-seed trust: `~/.pi/agent/trust.json` is
  a flat `{"abs/path": true}` map (pi), `.claude.json` `trustedDirs` (claude).
  Without pre-seeding, the crewmate blocks on an interactive prompt.
- **`tasks-axi` missing** ⇒ teardown refuses (decision-hold gate); install with
  `npm install -g tasks-axi` and re-run prereqs.
- **`treehouse` missing** ⇒ every spawn fails on worktree acquisition; install
  via firstmate's `bin/fm-install-treehouse.sh` (SHA256-pinned).
- **Stale task dir**: `dispatch()` clears a leftover `data/<tid>` only when no
  live spawn lock exists; a live lock means a crew is in flight — steer or
  teardown, never re-dispatch.
- **dispatch() returns on spawn, not completion** — the crewmate runs
  autonomously; use a watcher, not the dispatch return value.
- **`{TASK}` appears twice** in a scaffolded brief; the module replaces all
  occurrences.
- **Parked ≠ stalled**: a no-mistakes crewmate that reaches the review gate
  sits at `state=parked` with `pending_decision=true`, NOT a terminal state.
  A terminal-only watcher will silently time out on it (observed bug). Always
  watch with `fm-watch.sh` and, on exit `3`, feed the gate
  (`no-mistakes axi respond --action …` in the worktree) or steer via
  `fm-send.sh`; never re-arm a parked crewmate without resolving the gate.
- **pi-agent LLM config missing**: if pi-agent uses unknown models, errors
  with "no providers configured", or fails to start, check that
  `~/.pi/agent/models.json` and `~/.pi/agent/settings.json` exist. See
  `references/models.json` and `references/settings.json`
  in this repo for templates. `firstmate_prereqs.sh` [10] will WARN (not FAIL)
  when these files are absent — copy the templates in yourself; the bridge
  intentionally does NOT auto-install provider configs.
- **pi-agent + large brief hangs**: when pi-agent is given a full encoded brief
  (via `fm-operational-input.sh encode launch-brief`) with the firstmate
  extension loaded, it can hang indefinitely (>30s) without output. Short
  prompts (<200 bytes) work reliably. This appears to be an LLM call timeout/
  stall with omniroute when the brief is large and complex. Workaround: keep
  briefs concise or debug omniroute/pi-agent config.

## Verification

- `firstmate_prereqs.sh` exits 0 with ALL REQUIRED PREREQUISITES MET.
- `snapshot()` returns `schema: fm-fleet-snapshot.v1` with a `tasks` list.
- A scout dispatch (< 60s) produces a report at
  `data/<task-id>/report.md` and teardown closes it without `--force`.
- Run tests: `python3 -m unittest tests.test_bridge -v` (from skill dir) — all tests pass.