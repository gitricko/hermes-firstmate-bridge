# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- pi-agent LLM config (`~/.pi/agent/models.json` + `settings.json`) is **warn-only**, never auto-installed by `install.sh`. Templates live at `references/models.json` and `references/settings.json` (fetched from hermes-webtop `main`). `firstmate_prereqs.sh` [10] WARNs when these files are absent; see SKILL.md "Pitfalls > pi-agent LLM config missing".
- **pi-agent + large brief hangs**: when pi-agent is given a full encoded brief (via `fm-operational-input.sh encode launch-brief`) with the firstmate extension loaded, it can hang indefinitely (>30s) without output. Short prompts (<200 bytes) work reliably. This appears to be an LLM call timeout/stall with omniroute when the brief is large and complex. Workaround: keep briefs concise or debug omniroute/pi-agent config. (Observed 2026-08-20)

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
