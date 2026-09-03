#!/usr/bin/env python3
"""Unit tests for the isolated Codex bundle generator."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("isolated_codex.py")
SPEC = importlib.util.spec_from_file_location("isolated_codex", MODULE_PATH)
assert SPEC and SPEC.loader
isolated_codex = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(isolated_codex)


class IsolatedCodexTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.workspace = self.root / "workspace"
        self.bundle = self.root / "bundle"
        self.workspace.mkdir()
        (self.bundle / "runtime").mkdir(parents=True)
        self.auth = self.root / "auth.json"
        self.codex_config = self.root / "config.toml"
        self.auth.write_text("{}\n", encoding="utf-8")
        self.codex_config.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def config(self) -> dict:
        return {
            "schema_version": 1,
            "name": "test-sandbox",
            "runtime": {
                "engine": "docker",
                "instance_id": "0123456789",
                "allow_degraded": False,
                "container_name": "isolated-codex-test-sandbox",
                "resources": {
                    "cpus": 1.0,
                    "memory": "1g",
                    "pids_limit": 64,
                    "shm_size": "128m",
                    "tmp_size": "128m",
                },
            },
            "image": {
                "source": "image",
                "base": "example.invalid/task:1",
                "injection": "layer",
            },
            "workspace": {"path": str(self.workspace), "mode": "rw"},
            "mounts": [],
            "auth": {
                "file": str(self.auth),
                "config_file": str(self.codex_config),
            },
            "network": {"mode": "none"},
            "environment": {},
            "environment_from_host": [],
            "failure_policy": {"preflight": []},
            "notifications": {"require_external": True, "channels": []},
        }

    def test_valid_minimal_config(self) -> None:
        isolated_codex.validate_config(self.config(), self.bundle)

    def test_rejects_slow_failure_polling(self) -> None:
        config = self.config()
        config["failure_policy"]["poll_interval_seconds"] = 3600
        with self.assertRaisesRegex(isolated_codex.UserError, "between 1 and 30"):
            isolated_codex.validate_config(config, self.bundle)

    def test_online_worker_requires_continuous_container_probe(self) -> None:
        config = self.config()
        config["network"]["mode"] = "bridge"
        with self.assertRaisesRegex(isolated_codex.UserError, "continuous"):
            isolated_codex.require_unattended_guards(config)
        config["failure_policy"]["preflight"] = [
            {
                "name": "model endpoint",
                "scope": "container",
                "type": "command",
                "argv": ["curl", "--fail", "https://example.com"],
                "continuous": True,
            }
        ]
        isolated_codex.validate_config(config, self.bundle)
        isolated_codex.require_unattended_guards(config)

    def test_probe_failure_threshold_is_bounded(self) -> None:
        config = self.config()
        config["failure_policy"]["preflight"] = [
            {
                "name": "model endpoint",
                "type": "command",
                "argv": ["curl", "https://example.com"],
                "failure_threshold": 3,
            }
        ]
        isolated_codex.validate_config(config, self.bundle)
        config["failure_policy"]["preflight"][0]["failure_threshold"] = 6
        with self.assertRaisesRegex(isolated_codex.UserError, "failure_threshold"):
            isolated_codex.validate_config(config, self.bundle)

    def test_codex_health_reports_only_safe_summary(self) -> None:
        config = self.config()
        config["network"]["mode"] = "bridge"
        report = {
            "overallStatus": "fail",
            "checks": {
                "auth.credentials": {"status": "ok", "summary": "configured"},
                "network.provider_reachability": {
                    "status": "fail",
                    "summary": "provider is unavailable",
                    "details": {"secret": "sk-do-not-report"},
                },
                "network.websocket_reachability": {
                    "status": "warning",
                    "summary": "fallback available",
                },
            },
        }
        completed = subprocess.CompletedProcess(
            ["docker"], 1, stdout=json.dumps(report), stderr="contains-secret"
        )
        with mock.patch.object(
            isolated_codex, "run_ephemeral_container", return_value=completed
        ), self.assertRaises(isolated_codex.UserError) as captured:
            isolated_codex.verify_codex_health(config, self.bundle)
        self.assertIn("provider is unavailable", str(captured.exception))
        self.assertNotIn("sk-do-not-report", str(captured.exception))
        self.assertNotIn("contains-secret", str(captured.exception))

    def test_health_checks_force_read_only_workspace(self) -> None:
        config = self.config()
        captured = []

        def fake_common(*args, **kwargs):
            captured.append(kwargs.get("workspace_mode_override"))
            return ["docker", "run"]

        completed = subprocess.CompletedProcess(["docker"], 0, stdout="", stderr="")
        with mock.patch.object(isolated_codex, "common_run_args", side_effect=fake_common), mock.patch.object(
            isolated_codex.subprocess, "run", return_value=completed
        ):
            isolated_codex.run_ephemeral_container(
                config, self.bundle, "health", ["true"], 5
            )
        self.assertEqual(captured, ["ro"])

    def test_multi_gpu_request_is_one_docker_csv_field(self) -> None:
        config = self.config()
        config["devices"] = {"nvidia": ["GPU-first", "GPU-second"]}
        command = isolated_codex.common_run_args(config, self.bundle, "test-container")
        position = command.index("--gpus")
        self.assertEqual(command[position + 1], '\"device=GPU-first,GPU-second\"')

    def test_command_failure_redacts_environment_tokens(self) -> None:
        command = [
            "docker",
            "run",
            "--env",
            "SHADOWLORD_CAPTCHA_TRAINING_EXPORT_TOKEN=do-not-print-this",
        ]
        failure = subprocess.CalledProcessError(125, command, stderr="do-not-print-this")
        with (
            mock.patch.object(isolated_codex.subprocess, "run", side_effect=failure),
            mock.patch.dict(
                isolated_codex.os.environ,
                {"SHADOWLORD_CAPTCHA_TRAINING_EXPORT_TOKEN": "do-not-print-this"},
            ),
            self.assertRaises(isolated_codex.UserError) as captured,
        ):
            isolated_codex.run_checked(command)
        self.assertNotIn("do-not-print-this", str(captured.exception))
        self.assertIn("SHADOWLORD_CAPTCHA_TRAINING_EXPORT_TOKEN=<redacted>", str(captured.exception))

    def test_podman_is_not_overclaimed(self) -> None:
        config = self.config()
        config["runtime"]["engine"] = "podman"
        with self.assertRaisesRegex(isolated_codex.UserError, "not supported"):
            isolated_codex.validate_config(config, self.bundle)

    def test_rejects_host_home_and_nested_control_mounts(self) -> None:
        config = self.config()
        config["mounts"] = [
            {"source": str(pathlib.Path.home()), "target": "/host-home", "mode": "ro"}
        ]
        with self.assertRaisesRegex(isolated_codex.UserError, "invalid additional"):
            isolated_codex.validate_config(config, self.bundle)

        config = self.config()
        config["mounts"] = [
            {"source": str(self.root), "target": "/usr/local/bin", "mode": "ro"}
        ]
        with self.assertRaisesRegex(isolated_codex.UserError, "invalid additional"):
            isolated_codex.validate_config(config, self.bundle)

    def test_rejects_home_workspace_and_overlapping_bundle(self) -> None:
        config = self.config()
        config["workspace"]["path"] = str(pathlib.Path.home())
        with self.assertRaisesRegex(isolated_codex.UserError, "task directory"):
            isolated_codex.validate_config(config, self.bundle)

        nested_bundle = self.workspace / "sandbox-bundle"
        (nested_bundle / "runtime").mkdir(parents=True)
        config = self.config()
        with self.assertRaisesRegex(isolated_codex.UserError, "must not contain"):
            isolated_codex.validate_config(config, nested_bundle)

    def test_rejects_auth_inside_writable_workspace(self) -> None:
        in_workspace = self.workspace / "auth.json"
        in_workspace.write_text("{}\n", encoding="utf-8")
        config = self.config()
        config["auth"]["file"] = str(in_workspace)
        with self.assertRaisesRegex(isolated_codex.UserError, "outside"):
            isolated_codex.validate_config(config, self.bundle)

        config = self.config()
        config["mounts"] = [
            {
                "source": str(self.root),
                "target": "/codex-control/extra",
                "mode": "ro",
            }
        ]
        with self.assertRaisesRegex(isolated_codex.UserError, "invalid additional"):
            isolated_codex.validate_config(config, self.bundle)

    def test_rejects_smtp_secret_in_worker_environment(self) -> None:
        config = self.config()
        config["notifications"]["channels"] = [
            {
                "type": "smtp",
                "host": "smtp.example.com",
                "username_env": "ALERT_USER",
                "password_env": "ALERT_PASSWORD",
                "to": ["owner@example.com"],
            }
        ]
        config["environment_from_host"] = ["ALERT_PASSWORD"]
        with self.assertRaisesRegex(isolated_codex.UserError, "host-only"):
            isolated_codex.validate_config(config, self.bundle)

    def test_rejects_literal_worker_secret(self) -> None:
        config = self.config()
        config["environment"] = {"SERVICE_API_KEY": "do-not-store-this"}
        with self.assertRaisesRegex(isolated_codex.UserError, "environment_from_host"):
            isolated_codex.validate_config(config, self.bundle)

    def test_rejects_control_environment_override(self) -> None:
        config = self.config()
        config["environment"] = {"ISOLATED_CODEX_CONTROL": "/tmp/hidden"}
        with self.assertRaisesRegex(isolated_codex.UserError, "control variables"):
            isolated_codex.validate_config(config, self.bundle)

    def test_contact_owner_writes_atomic_ready_event(self) -> None:
        control = self.root / "control"
        environment = dict(os.environ)
        environment["ISOLATED_CODEX_CONTROL"] = str(control)
        result = subprocess.run(
            [
                str(isolated_codex.ASSETS / "contact-owner"),
                "ssh_unreachable",
                "cannot reach target",
                "connection timed out",
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(result.returncode, isolated_codex.BLOCKED_EXIT)
        event = isolated_codex.read_blocked_from_control(control)
        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual(event["code"], "ssh_unreachable")
        self.assertEqual(event["detail"], "connection timed out")

    def test_notification_command_receives_spool_path(self) -> None:
        config = self.config()
        config["notifications"]["channels"] = [
            {"type": "command", "argv": ["/bin/test", "-f"]}
        ]
        isolated_codex.validate_config(config, self.bundle)
        path, delivered, errors = isolated_codex.notification_event(
            self.bundle,
            config,
            "test",
            "test event",
            "detail",
        )
        self.assertEqual(delivered, 1)
        self.assertEqual(errors, [])
        value = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(value["deliveries"], [{"channel": 0, "status": "delivered"}])

    def test_prepare_task_prompt_combines_fail_fast_and_task(self) -> None:
        prompt = self.root / "task.md"
        prompt.write_text("Create and pursue the training goal.\n", encoding="utf-8")
        combined = isolated_codex.prepare_task_prompt(self.bundle, str(prompt))
        content = combined.read_text(encoding="utf-8")
        self.assertIn("# Task", content)
        self.assertIn("Create and pursue the training goal.", content)
        self.assertIn("contact-owner", content)

    def test_interactive_run_loads_the_task_prompt(self) -> None:
        prompt = self.root / "task.md"
        prompt.write_text("Create and pursue the training goal.\n", encoding="utf-8")
        args = SimpleNamespace(
            bundle=str(self.bundle),
            mode="interactive",
            prompt_file=str(prompt),
        )
        with (
            mock.patch.object(isolated_codex, "load_config", return_value=self.config()),
            mock.patch.object(isolated_codex, "require_attestations"),
            mock.patch.object(isolated_codex, "codex_args", return_value=["codex"]),
            mock.patch.object(isolated_codex, "supervise", return_value=0) as supervise,
            self.assertRaises(SystemExit),
        ):
            isolated_codex.cmd_run(args)
        command = supervise.call_args.args[2]
        self.assertIn("/codex-control/current-prompt.md", command[-1])


if __name__ == "__main__":
    unittest.main()
