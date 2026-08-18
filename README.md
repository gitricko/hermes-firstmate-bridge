# hermes-firstmate-bridge

Portable Hermes skill that turns any Hermes install into a **firstmate captain** with a **pi-agent crew**.

Hermes is the captain (chat intake, intent, memory, scheduling, delegation). firstmate is the crew backend (herdr/tmux spawning, treehouse worktrees, no-mistakes gate, merge authority). This repo is the thin glue: a skill folder you drop into `~/.hermes/skills/` and a one-shot installer.

## Quickstart

```bash
# 1. Copy the skill folder into Hermes
cp -r firstmate-bridge ~/.hermes/skills/productivity/

# 2. Run the one-shot bootstrap (idempotent, zero prompts)
bash ~/.hermes/skills/productivity/firstmate-bridge/install.sh
```

That's it. `install.sh` will:

1. Detect OS deps (git, node, npm; herdr/tmux recommended)
2. Clone firstmate and pin it to the SHA in `.firstmate-ref` (upstream + commit pin — no fork needed)
3. Install prereqs via `firstmate_prereqs.sh --fix` (treehouse, tasks-axi, pi, jq)
4. Pin the crew harness to `pi` (`config/crew-harness`)
5. Pre-seed worktree trust (pi trust.json + claude trustedDirs)
6. Write `~/.hermes/config/firstmate.json`
7. Verify — must print `ALL REQUIRED PREREQUISITES MET`

## Contents

| File | What it is |
|---|---|
| `SKILL.md` | Captain-side instructions (Hermes skill convention) |
| `firstmate_bridge.py` | Glue module: snapshot / detect_runtime / resolve_home / dispatch / steer / decide / interrupt / exit / merge / teardown |
| `firstmate_prereqs.sh` | Checker + installer (`--fix`): treehouse, tasks-axi, pi, jq, FM_HOME, crew-harness, snapshot probe |
| `install.sh` | One-shot bootstrap (see Quickstart) |
| `.firstmate-ref` | Pinned firstmate commit SHA — the version freeze |

## Requirements

- git, node, npm
- a session backend for crew panes: **herdr** (recommended) or tmux
- OmniRoute (or any OpenAI-compatible endpoint) for pi's model — configure via `~/.pi/agent/models.json`

## Version freeze

firstmate is pinned by commit SHA in `.firstmate-ref`. Bumps are deliberate: update the SHA, run CI (which tests the pinned SHA plus latest upstream), merge, done. The freeze is enforced by a test, not by memory.

## CI

- **Every PR:** SKILL.md lint (frontmatter, ≤60-char description, no `trigger:` field) + module parse + prereqs in a clean container
- **main/releases:** full scout smoke dispatch (spawn a pi crewmate, get a report, teardown) proving the whole lifecycle against the pinned version

To run a no-mistakes gate review locally, first initialize the gate (this creates the `no-mistakes` remote):

```bash
no-mistakes init
no-mistakes runs   # list/status of existing pipeline runs (does not trigger a review)
git push no-mistakes <branch>   # this is what actually triggers the gate review
```

## Design

- Crewmate harness: **pi** (Pi-Agent) — pinned in `config/crew-harness`
- firstmate source: **upstream `kunchenguid/firstmate`** cloned to `~/Documents/firstmate`, pinned via `.firstmate-ref`
- The skill **offers, never auto-dispatches** — on a herdr terminal it suggests firstmate; it only spawns on explicit captain intent
- Merge stays gated on the captain's word (`fm-pr-merge.sh`); crew PRs are review surfaces

## License

MIT
