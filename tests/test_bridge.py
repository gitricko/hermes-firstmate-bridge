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
        """_read_primary_home_from_config returns the expanded primary path."""
        d = Path(tempfile.mkdtemp())
        hermes_cfg = d / ".hermes" / "config" / "firstmate.json"
        hermes_cfg.parent.mkdir(parents=True)
        hermes_cfg.write_text(json.dumps({"homes": {"primary": "/cfg/home"}}))
        with mock.patch.dict(os.environ, {"HOME": str(d)}):
            result = fb._read_primary_home_from_config()
            self.assertIsNotNone(result)
            self.assertEqual(str(result), str(Path("/cfg/home").resolve()))

    def test_missing_config_returns_none(self):
        with mock.patch.dict(os.environ, {"HOME": str(Path(tempfile.mkdtemp()))}):
            self.assertIsNone(fb._read_primary_home_from_config())

    def test_named_selector_fails_closed(self):
        with self.assertRaises(fb.FirstmateError):
            fb.resolve_home("secondmate-A")

    def test_primary_selector_ok(self):
        self.assertTrue(isinstance(fb.resolve_home("primary"), Path))


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
