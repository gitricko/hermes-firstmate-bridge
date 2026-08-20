#!/usr/bin/env python3
"""firstmate-bridge — thin glue between Hermes (captain) and firstmate (crew backend).

Phase 1 (shipped): read-only fleet-state access.
  - snapshot()        : wrap bin/fm-fleet-snapshot.sh --json with FM_HOME explicit
  - detect_runtime()  : herdr/tmux/cmux/unknown from env markers (herdr-aware offer)
  - resolve_home()    : explicit FM_HOME resolution, fail-closed on ambiguity

Phase 2 (shipped): dispatch / steer / merge / teardown — captain-gated.
  - dispatch()        : fm-brief.sh + fm-spawn.sh --harness claude, replaces {TASK}
  - steer()/decide()  : fm-send.sh (with --resolve-key for decisions)
  - interrupt()/exit_task(): fm-control.sh
  - merge()           : fm-pr-merge.sh — GATED on explicit captain word, never auto
  - teardown()        : fm-teardown.sh

Design: /config/Documents/_code/firstmate/.lavish/hermes-bridge-v2.html (proposal v3).

Contract notes (verified against firstmate 2026-08):
  - bin/ lives under FM_ROOT (the code root). state/data/config/projects live under
    FM_HOME. When FM_HOME is unset they default to the repo root (whole-root mode).
  - fm-send.sh REQUIRES FM_HOME set; it fails closed rather than steer the wrong home.
  - So every firstmate call here sets FM_HOME explicitly. No exceptions.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from glob import glob
from pathlib import Path

__all__ = [
    "FM_HOME",
    "FM_ROOT",
    "FM_BIN",
    "snapshot",
    "detect_runtime",
    "resolve_home",
    "dispatch",
    "steer",
    "interrupt",
    "exit_task",
    "merge",
    "decide",
    "teardown",
    "watch",
    "FirstmateError",
]

class FirstmateError(RuntimeError):
    """Raised when a firstmate bin/ script fails or returns no parseable data."""


def _run(cmd: list[str], home: Path | None = None, timeout: int = 30) -> dict:
    """Run a firstmate bin/ script with FM_HOME explicit; return parsed JSON.

    Fails closed: FM_HOME is always set from the resolved home so a steer can never
    hit the wrong operational home (fm-send.sh also enforces this).
    """
    home = home or FM_HOME
    env = dict(os.environ)
    env["FM_HOME"] = str(home)
    # whole-root mode if home == root; otherwise FM_ROOT_OVERRIDE keeps bin/ pinned
    if str(home) != str(FM_ROOT):
        env["FM_ROOT_OVERRIDE"] = str(FM_ROOT)
    try:
        proc = subprocess.run(
            cmd, cwd=FM_ROOT, env=env,
            capture_output=True, text=True, timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise FirstmateError(f"firstmate bin not found: {exc}") from exc

    if proc.returncode != 0:
        raise FirstmateError(
            f"{cmd[0]} failed (exit {proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )

    out = proc.stdout.strip()
    if not out:
        raise FirstmateError(f"{cmd[0]} produced no output")
    # Most firstmate bin/ scripts emit human text; only fleet-snapshot --json is JSON.
    # Try JSON, fall back to raw stdout so text-emitting scripts (fm-brief, fm-send,
    # fm-control, fm-pr-merge, fm-teardown) return their message instead of erroring.
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"ok": True, "stdout": out, "rc": 0}


def snapshot(home: str | Path | None = None) -> dict:
    """Return the current fleet state via bin/fm-fleet-snapshot.sh --json.

    Schema: fm-fleet-snapshot.v1 (tasks, backlog, secondmate_current, etc.).
    """
    return _run([str(FM_BIN / "fm-fleet-snapshot.sh"), "--json"], home=resolve_home(home))


def detect_runtime() -> str:
    """Detect the active multiplexer terminal, mirroring bin/fm-backend.sh.

    Innermost multiplexer wins: tmux > herdr > cmux. Used to offer firstmate
    dispatch when Hermes is itself running under herdr (hermes-webtop preinstall plan).
    """
    if os.environ.get("TMUX"):
        return "tmux"
    if os.environ.get("HERDR_ENV") == "1":
        return "herdr"
    if os.environ.get("CMUX_WORKSPACE_ID"):
        return "cmux"
    return "unknown"


# Optional fcntl for non-blocking lock (POSIX only). Self-healing import — the module
# still loads on platforms without fcntl (lock becomes a no-op).
try:
    import fcntl  # type: ignore
except ImportError:  # pragma: no cover - non-POSIX
    fcntl = None  # type: ignore


# Resolved primary home: env override (FM_HOME) → config file → installer default.
# An explicit FM_HOME always wins; the config file is honored only when the env
# var is unset; otherwise we fall back to the installer default.
_env_home = os.environ.get("FM_HOME")
if _env_home:
    FM_HOME: Path = Path(os.path.expanduser(_env_home)).resolve()
else:
    cfg = Path(os.path.expanduser("~/.hermes/config/firstmate.json"))
    primary = None
    if cfg.is_file():
        try:
            data = json.loads(cfg.read_text(encoding="utf-8"))
            primary = data.get("homes", {}).get("primary")
        except (json.JSONDecodeError, OSError):
            pass  # malformed/unreadable config → fall back to default
    if isinstance(primary, str) and primary:
        FM_HOME = Path(os.path.expanduser(primary)).resolve()
    else:
        FM_HOME = Path(os.path.expanduser("~/Documents/firstmate")).resolve()
FM_ROOT: Path = Path(os.environ.get("FM_ROOT_OVERRIDE", str(FM_HOME))).resolve()
FM_BIN: Path = FM_ROOT / "bin"


def resolve_home(selector: str | None = None) -> Path:
    """Resolve an explicit FM_HOME. Fail closed on ambiguity.

    Resolution order for the primary home:
      1. FM_HOME env var (always wins when set)
      2. ~/.hermes/config/firstmate.json → homes.primary
      3. installer default ~/Documents/firstmate

    Selector semantics (Phase 1): None or "primary" → the configured primary home.
    Named secondmates ("sg", "remote-A") are a Phase 5 feature; referenced here only
    to fail closed rather than silently fall back.
    """
    if selector in (None, "primary", ""):
        return FM_HOME
    # Future: look up ~/.hermes/config/firstmate.json["homes"][selector]
    # Until secondmate routing ships (Phase 5), any named selector is an error.
    raise FirstmateError(
        f"unknown FM_HOME selector {selector!r}: secondmate routing is not "
        f"implemented yet (Phase 5). Use 'primary'."
    )


# ---------------------------------------------------------------------------
# Phase 2 — dispatch / steer / merge / teardown.
# Hermes is the captain. These wrap firstmate's bin/ scripts with FM_HOME
# always explicit (fm-send fails closed if unset).
# ---------------------------------------------------------------------------
DEFAULT_HARNESS = "pi"  # Pine (pi-agent); captain switched from claude 2026-08-17
VALID_MODES = ("no-mistakes", "direct-PR", "local-only")
VALID_YOLO = ("on", "off")


def _slugify_task_id(text: str) -> str:
    """Turn a request into a bare firstmate task-id slug (lower a-z0-9-)."""
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    slug = slug[:48].strip("-")
    return slug or "task"


def _replace_task_in_brief(brief_path: Path, task_text: str) -> None:
    """Replace the {TASK} placeholder firstmate scaffolds with the real task.

    All occurrences are replaced (firstmate also prints {TASK} inside a doc note;
    leaving a literal {TASK} anywhere would confuse the crewmate).
    """
    text = brief_path.read_text(encoding="utf-8")
    if "{TASK}" not in text:
        return
    text = text.replace("{TASK}", task_text)
    brief_path.write_text(text, encoding="utf-8")


def dispatch(
    request: str,
    project: str,
    *,
    home: str | Path | None = None,
    harness: str = DEFAULT_HARNESS,
    kind: str = "ship",
    mode: str = "no-mistakes",
    yolo: str = "off",
    backend: str | None = None,
    model: str | None = None,
    task_id: str | None = None,
    timeout: int = 420,
) -> dict:
    """Spawn a firstmate crewmate to work on `request` in `project`'s repo.

    Args:
      request : natural-language task description (replaces {TASK} in the brief)
      project : firstmate project key (projects/<name>) or absolute repo path
      harness : verified crewmate harness (default claude, pinned per Q7)
      kind    : "ship" (PR deliverable) or "scout" (report only, no branch/PR)
      mode    : delivery contract (no-mistakes | direct-PR | local-only) [ship only]
      yolo    : "on" | "off" — autonomy posture [ship only; default off]
      backend : herdr | tmux | None (None → firstmate auto-detect)
      task_id : explicit slug; auto-derived from request if omitted

    Returns: {"task_id": ..., "backend": ..., "harness": ..., "kind": ...} on success.

    - ship: crewmate works in a disposable worktree, opens a PR for captain review.
      This does NOT auto-merge; merge() is gated on explicit captain word.
    - scout: scratch worktree, report-only deliverable, never pushes or opens a PR.
      Safer first run — bounded blast radius (discarded at teardown).
    """
    home_p = resolve_home(home)
    if kind not in ("ship", "scout"):
        raise FirstmateError(f"invalid kind {kind!r}; expected ship|scout")
    if kind == "ship":
        if mode not in VALID_MODES:
            raise FirstmateError(f"invalid mode {mode!r}; expected {VALID_MODES}")
        if yolo not in VALID_YOLO:
            raise FirstmateError(f"invalid yolo {yolo!r}; expected {VALID_YOLO}")
    tid = task_id or _slugify_task_id(request)

    # 1. guard against a stale task dir from a killed/aborted prior dispatch.
    #    firstmate's fm-brief.sh refuses to overwrite an existing brief, so we
    #    clear a stale data/<tid> ONLY when no live spawn lock is held (a live
    #    lock means a real crew is in flight — never clobber that).
    task_dir = home_p / "data" / tid
    lock_glob = home_p / "state" / f".spawn-{tid}.lock*"
    if task_dir.exists():
        live_lock = glob(str(lock_glob))
        if live_lock:
            raise FirstmateError(
                f"task {tid} has a live spawn lock ({live_lock[0]}); a crew may be "
                f"in flight. Use steer()/teardown() instead of re-dispatching."
            )
        shutil.rmtree(task_dir, ignore_errors=True)

    # 2. scaffold the brief (firstmate-owned contract)
    brief_cmd = [str(FM_BIN / "fm-brief.sh"), tid, str(project)]
    if kind == "scout":
        brief_cmd.append("--scout")
    else:
        brief_cmd += ["--mode", mode]
    _run(brief_cmd, home=home_p)
    brief_path = home_p / "data" / tid / "brief.md"
    if not brief_path.exists():
        raise FirstmateError(f"brief not created at {brief_path}")
    _replace_task_in_brief(brief_path, request)

    # Default the backend to the runtime we're actually running in, so a crew
    # spawned under herdr (or tmux/cmux) stays in that multiplexer and the
    # captain can supervise it where they already are. Explicit arg still wins.
    if backend is None:
        rt = detect_runtime()
        backend = rt if rt in ("herdr", "tmux", "cmux") else None

    # 2. spawn the crewmate (claude default; backend auto-detected unless given)
    spawn_cmd = [str(FM_BIN / "fm-spawn.sh"), tid, str(project)]
    if kind == "scout":
        spawn_cmd.append("--scout")
    else:
        spawn_cmd += ["--mode", mode, "--yolo", yolo]
    spawn_cmd += ["--harness", harness]
    if backend:
        spawn_cmd += ["--backend", backend]
    if model:
        spawn_cmd += ["--model", model]

    out = _run(spawn_cmd, home=home_p, timeout=timeout)
    out.setdefault("task_id", tid)
    out.setdefault("harness", harness)
    out.setdefault("backend", backend or detect_runtime())
    out.setdefault("kind", kind)
    return out


def steer(
    task_id: str,
    message: str,
    *,
    home: str | Path | None = None,
    resolve_key: str | None = None,
) -> dict:
    """Send a follow-up message / decision to a live crewmate via fm-send.sh.

    resolve_key: if the crewmate is blocked on a decision, resolving it forwards
    the answer and clears the hold.
    """
    home_p = resolve_home(home)
    cmd = [str(FM_BIN / "fm-send.sh"), task_id, message]
    if resolve_key:
        cmd[1:1] = ["--resolve-key", resolve_key]
    return _run(cmd, home=home_p)


def interrupt(task_id: str, *, home: str | Path | None = None) -> dict:
    return _run([str(FM_BIN / "fm-control.sh"), "interrupt", task_id], home=resolve_home(home))


def exit_task(task_id: str, *, home: str | Path | None = None) -> dict:
    return _run([str(FM_BIN / "fm-control.sh"), "exit", task_id], home=resolve_home(home))


def merge(
    task_id: str,
    pr_url: str,
    *,
    home: str | Path | None = None,
    yolo: str = "off",
) -> dict:
    """Merge a crewmate's PR. GATED: caller must have explicit captain word.

    Never call this without the captain saying "merge". yolo default off.
    """
    home_p = resolve_home(home)
    if yolo not in VALID_YOLO:
        raise FirstmateError(f"invalid yolo {yolo!r}; expected {VALID_YOLO}")
    return _run(
        [str(FM_BIN / "fm-pr-merge.sh"), task_id, pr_url, "--yolo", yolo],
        home=home_p,
    )


def decide(
    task_id: str,
    key: str,
    answer: str,
    *,
    home: str | Path | None = None,
) -> dict:
    return steer(task_id, answer, home=home, resolve_key=key)


def teardown(task_id: str, *, home: str | Path | None = None) -> dict:
    return _run([str(FM_BIN / "fm-teardown.sh"), task_id], home=resolve_home(home))


def watch(
    task_id: str,
    *,
    home: str | Path | None = None,
    timeout: int = 600,
    poll: int = 10,
) -> dict:
    """Watch a crewmate task via bin/fm-watch.sh, returning parsed state.

    Mirrors fm-watch.sh's exit semantics:
      0 = terminal (done/failed/blocked with PR URL)
      3 = parked / pending_decision (feed the no-mistakes gate)
      2 = timeout (re-arm to continue)
      1 = error

    Args:
      task_id: firstmate task id to watch
      home: FM_HOME override (default: resolved primary home)
      timeout: max seconds to wait before returning exit code 2 (passed via FM_STALE_ESCALATE_SECS)
      poll: interval between state checks in seconds (passed via FM_POLL)

    Returns: dict with at least {"exit_code": int, "stdout": str}.
    """
    home_p = resolve_home(home if home is None else str(home))
    cmd = [
        str(FM_BIN / "fm-watch.sh"),
        task_id,
    ]
    # fm-watch.sh uses exit codes 2 (timeout) and 3 (parked) as documented
    # control-flow signals, NOT errors. It reads config via environment variables:
    # FM_POLL (poll interval), FM_STALE_ESCALATE_SECS (stale timeout).
    # Run directly without _run()'s non-zero-raise logic so callers can
    # handle control-flow states properly.
    env = dict(os.environ)
    env["FM_HOME"] = str(home_p)
    env["FM_POLL"] = str(poll)
    env["FM_STALE_ESCALATE_SECS"] = str(timeout)
    if str(home_p) != str(FM_ROOT):
        env["FM_ROOT_OVERRIDE"] = str(FM_ROOT)
    try:
        proc = subprocess.run(
            cmd, cwd=FM_ROOT, env=env,
            capture_output=True, text=True, timeout=timeout + 30,
        )
    except FileNotFoundError as exc:
        raise FirstmateError(f"firstmate bin not found: {exc}") from exc

    # Return all exit codes — 0, 2, 3 are valid control-flow states
    out = proc.stdout.strip()
    if not out:
        return {"exit_code": proc.returncode, "stdout": "", "rc": proc.returncode}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"exit_code": proc.returncode, "stdout": out, "rc": proc.returncode}


if __name__ == "__main__":
    # Minimal CLI: `python3 firstmate_bridge.py [snapshot|runtime|dispatch]`
    if len(sys.argv) > 1 and sys.argv[1] == "snapshot":
        print(json.dumps(snapshot(), indent=2))
    elif len(sys.argv) > 1 and sys.argv[1] == "runtime":
        print(detect_runtime())
    elif len(sys.argv) > 1 and sys.argv[1] == "dispatch":
        # dispatch <request> <project> [--harness claude] [--mode no-mistakes]
        # NOTE: never invoked without explicit captain intent.
        req, proj = sys.argv[2], sys.argv[3]
        kw = {}
        if "--harness" in sys.argv:
            kw["harness"] = sys.argv[sys.argv.index("--harness") + 1]
        if "--mode" in sys.argv:
            kw["mode"] = sys.argv[sys.argv.index("--mode") + 1]
        print(json.dumps(dispatch(req, proj, **kw), indent=2))
    else:
        print("usage: firstmate_bridge.py [snapshot|runtime|dispatch <req> <proj>]", file=sys.stderr)
        sys.exit(2)
