---
name: firstmate-bridge
description: Dispatch code-work to firstmate crews; Hermes stays captain.
version: 2.0.0
author: Gram Ricko (gitricko), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [firstmate, crew, delegation, captain, herdr]
    related_skills: [coding-agent-orchestration, computer-use]
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
6. **Arm a watcher** that alerts when the report/PR lands
   (`background=true` + `notify_on_complete=true`); never poll in a blocking
   loop.
7. **Relay** task_id, backend, and the PR URL or report path. Failure is news —
   report it honestly.
8. **Teardown** completed tasks with `teardown(id)`; lifecycle closes cleanly
   only when `tasks-axi` is present.

## Pitfalls

- **Trust prompts**: firstmate's worktrees are fresh paths; harnesses prompt
  "trust this folder?" once. Pre-seed trust: `/config/.pi/agent/trust.json` is
  a flat `{"/abs/path": true}` map (pi), `.claude.json` `trustedDirs` (claude).
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

## Verification

- `firstmate_prereqs.sh` exits 0 with ALL REQUIRED PREREQUISITES MET.
- `snapshot()` returns `schema: fm-fleet-snapshot.v1` with a `tasks` list.
- A scout dispatch (< 60s) produces a report at
  `data/<task-id>/report.md` and teardown closes it without `--force`.