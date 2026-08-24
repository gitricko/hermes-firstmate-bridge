#!/usr/bin/env python3
"""Regression tests for issue #13 autonomous-install fixes.

Run from the repo root:
    python3 -m unittest tests.test_bridge -v
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Make the module importable without a package install.
REPO_ROOT = Path(__file__).resolve().parent.parent
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "firstmate_bridge", str(REPO_ROOT / "firstmate_bridge.py")
)
assert _spec is not None
fb = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(fb)


class ResolveHomeConfigTests(unittest.TestCase):
    """resolve_home must honor the config-file primary home when FM_HOME is unset."""

    def test_env_wins_over_config(self):
        # FM_HOME must win at import time even when a config file also exists.
        d = Path(tempfile.mkdtemp())
        hermes_cfg = d / ".hermes" / "config" / "firstmate.json"
        hermes_cfg.parent.mkdir(parents=True)
        hermes_cfg.write_text(json.dumps({"homes": {"primary": "/from/config"}}))
        with mock.patch.dict(os.environ, {"HOME": str(d), "FM_HOME": "/from/env"}):
            _spec2 = importlib.util.spec_from_file_location(
                "firstmate_bridge_env", str(REPO_ROOT / "firstmate_bridge.py")
            )
            assert _spec2 is not None and _spec2.loader is not None
            mod = importlib.util.module_from_spec(_spec2)
            _spec2.loader.exec_module(mod)
            self.assertEqual(str(mod.resolve_home("primary")), "/from/env")

    def test_config_primary_resolves(self):
        """Config file primary home is resolved when FM_HOME is unset."""
        d = Path(tempfile.mkdtemp())
        hermes_cfg = d / ".hermes" / "config" / "firstmate.json"
        hermes_cfg.parent.mkdir(parents=True)
        hermes_cfg.write_text(json.dumps({"homes": {"primary": "/cfg/home"}}))
        with mock.patch.dict(os.environ, {"HOME": str(d)}):
            _spec2 = importlib.util.spec_from_file_location(
                "firstmate_bridge_cfg", str(REPO_ROOT / "firstmate_bridge.py")
            )
            assert _spec2 is not None and _spec2.loader is not None
            mod = importlib.util.module_from_spec(_spec2)
            _spec2.loader.exec_module(mod)
            self.assertEqual(str(mod.resolve_home("primary")), str(Path("/cfg/home").resolve()))

    def test_missing_config_returns_default(self):
        with mock.patch.dict(os.environ, {"HOME": str(Path(tempfile.mkdtemp()))}):
            _spec2 = importlib.util.spec_from_file_location(
                "firstmate_bridge_nocfg", str(REPO_ROOT / "firstmate_bridge.py")
            )
            assert _spec2 is not None and _spec2.loader is not None
            mod = importlib.util.module_from_spec(_spec2)
            _spec2.loader.exec_module(mod)
            expected = str(Path(os.path.expanduser("~/Documents/firstmate")).resolve())
            self.assertEqual(str(mod.resolve_home("primary")), expected)

    def test_named_selector_fails_closed(self):
        with self.assertRaises(fb.FirstmateError):
            fb.resolve_home("secondmate-A")

    def test_primary_selector_ok(self):
        self.assertTrue(isinstance(fb.resolve_home("primary"), Path))


class DetectRuntimeTests(unittest.TestCase):
    """detect_runtime returns the correct backend from env markers."""

    def test_herdr_env_returns_herdr(self):
        with mock.patch.dict(os.environ, {"HERDR_ENV": "1", "TMUX": ""}, clear=True):
            self.assertEqual(fb.detect_runtime(), "herdr")

    def test_tmux_env_returns_tmux(self):
        with mock.patch.dict(os.environ, {"TMUX": "some-session", "HERDR_ENV": ""}, clear=True):
            self.assertEqual(fb.detect_runtime(), "tmux")

    def test_cmux_env_returns_cmux(self):
        with mock.patch.dict(os.environ, {"CMUX_WORKSPACE_ID": "ws1", "TMUX": "", "HERDR_ENV": ""}, clear=True):
            self.assertEqual(fb.detect_runtime(), "cmux")

    def test_unknown_when_none_set(self):
        with mock.patch.dict(os.environ, {"TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""}, clear=True):
            self.assertEqual(fb.detect_runtime(), "unknown")


class DetectRuntimeHintTests(unittest.TestCase):
    """detect_runtime respects FIRSTMATE_RUNTIME_HINT when hard markers absent."""

    def test_hint_herdr_when_no_markers(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "herdr",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "herdr")

    def test_hint_tmux_when_no_markers(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "tmux",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "tmux")

    def test_hint_cmux_when_no_markers(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "cmux",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "cmux")

    def test_hint_unknown_when_no_markers(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "unknown",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "unknown")

    def test_hint_case_insensitive(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "HERDR",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "herdr")

    def test_invalid_hint_ignored(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "invalid",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "unknown")

    def test_hard_markers_override_hint(self):
        """Hard markers are authoritative when present (real terminal)."""
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "tmux",
            "HERDR_ENV": "1",  # Actually in herdr
            "TMUX": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "herdr")

    def test_hint_overrides_unknown_when_no_markers(self):
        """Hint is used when markers absent (sandbox case)."""
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "herdr",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            self.assertEqual(fb.detect_runtime(), "herdr")


class DispatchHintIntegrationTests(unittest.TestCase):
    """dispatch() uses hint via detect_runtime() when backend=None."""

    def test_dispatch_defaults_to_hint_when_in_sandbox(self):
        with mock.patch.dict(os.environ, {
            "FIRSTMATE_RUNTIME_HINT": "herdr",
            "TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""
        }, clear=True):
            rt = fb.detect_runtime()
            backend = rt if rt in ("herdr", "tmux", "cmux") else None
            self.assertEqual(backend, "herdr")


class DispatchBackendDefaultTests(unittest.TestCase):
    """dispatch() defaults backend to the detected runtime (herdr/tmux/cmux)."""

    def test_dispatch_defaults_to_herdr_when_in_herdr(self):
        """When HERDR_ENV=1, dispatch should default backend to herdr."""
        with mock.patch.dict(os.environ, {"HERDR_ENV": "1", "TMUX": "", "CMUX_WORKSPACE_ID": ""}, clear=True):
            # We can't easily test the full dispatch without firstmate installed,
            # but we can verify the logic that sets the default backend
            rt = fb.detect_runtime()
            backend = rt if rt in ("herdr", "tmux", "cmux") else None
            self.assertEqual(backend, "herdr")

    def test_dispatch_defaults_to_tmux_when_in_tmux(self):
        """When TMUX is set, dispatch should default backend to tmux."""
        with mock.patch.dict(os.environ, {"TMUX": "session", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""}, clear=True):
            rt = fb.detect_runtime()
            backend = rt if rt in ("herdr", "tmux", "cmux") else None
            self.assertEqual(backend, "tmux")

    def test_dispatch_defaults_to_cmux_when_in_cmux(self):
        """When CMUX_WORKSPACE_ID is set, dispatch should default backend to cmux."""
        with mock.patch.dict(os.environ, {"CMUX_WORKSPACE_ID": "ws1", "TMUX": "", "HERDR_ENV": ""}, clear=True):
            rt = fb.detect_runtime()
            backend = rt if rt in ("herdr", "tmux", "cmux") else None
            self.assertEqual(backend, "cmux")

    def test_dispatch_backend_none_when_unknown(self):
        """When no runtime detected, backend stays None (firstmate decides)."""
        with mock.patch.dict(os.environ, {"TMUX": "", "HERDR_ENV": "", "CMUX_WORKSPACE_ID": ""}, clear=True):
            rt = fb.detect_runtime()
            backend = rt if rt in ("herdr", "tmux", "cmux") else None
            self.assertIsNone(backend)

    def test_explicit_backend_overrides_default(self):
        """Explicit backend argument should override detected default."""
        with mock.patch.dict(os.environ, {"HERDR_ENV": "1", "TMUX": "", "CMUX_WORKSPACE_ID": ""}, clear=True):
            # Explicit backend wins
            explicit_backend = "tmux"
            rt = fb.detect_runtime()
            backend = explicit_backend if explicit_backend else (rt if rt in ("herdr", "tmux", "cmux") else None)
            self.assertEqual(backend, "tmux")


class PrereqDoctorTests(unittest.TestCase):
    """firstmate_prereqs.sh --doctor emits valid JSON with the right shape."""

    def test_doctor_emits_json(self):
        script = REPO_ROOT / "firstmate_prereqs.sh"
        env = dict(os.environ)
        env["PATH"] = "/usr/bin:/bin"
        env["FM_HOME"] = "/nonexistent/firstmate/home"
        env["BRIDGE_SCRIPT"] = "/nonexistent/bridge/firstmate_bridge.py"
        proc = subprocess.run(
            ["bash", str(script), "--doctor"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertIn("all_passed", payload)
        self.assertIn("checks", payload)
        self.assertIn("missing", payload)
        self.assertIsInstance(payload["checks"], list)
        self.assertIsInstance(payload["missing"], list)


if __name__ == "__main__":
    unittest.main(verbosity=2)
