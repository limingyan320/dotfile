import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class ApplyTest(unittest.TestCase):
    def test_managed_config_is_preserved_and_idempotent(self):
        repo = Path(__file__).resolve().parent.parent
        script = repo / "codex-notifications" / "apply.sh"
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            config_dir = home / ".codex"
            config_dir.mkdir()
            config_path = config_dir / "config.toml"
            hooks_path = config_dir / "hooks.json"
            config_path.write_text(
                'model = "keep-me"\n\n[tui]\ntheme = "tokyonight"\n',
                encoding="utf-8",
            )
            hooks_path.write_text(
                json.dumps(
                    {
                        "hooks": {
                            "Stop": [
                                {
                                    "hooks": [
                                        {
                                            "type": "command",
                                            "command": "python3 keep-me.py",
                                        }
                                    ]
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            environment = dict(os.environ, HOME=str(home))

            first = subprocess.run(
                ["bash", str(script)],
                cwd=repo,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            rendered = config_path.read_text(encoding="utf-8")
            self.assertIn('model = "keep-me"', rendered)
            self.assertIn('theme = "tokyonight"', rendered)
            self.assertIn(
                'notifications = ["agent-turn-complete", "approval-requested"]',
                rendered,
            )
            self.assertIn("animations = true", rendered)
            self.assertIn('terminal_title = ["spinner", "project"]', rendered)
            self.assertIn("tui.terminal_title", first.stdout)

            hooks = json.loads(hooks_path.read_text(encoding="utf-8"))["hooks"]
            stop_commands = [
                handler["command"]
                for group in hooks["Stop"]
                for handler in group.get("hooks", [])
            ]
            self.assertIn("python3 keep-me.py", stop_commands)
            self.assertTrue(
                any(
                    "dotfiles-codex-agent-state" in command for command in stop_commands
                )
            )

            before_second_run = config_path.read_bytes(), hooks_path.read_bytes()
            second = subprocess.run(
                ["bash", str(script)],
                cwd=repo,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                before_second_run,
                (config_path.read_bytes(), hooks_path.read_bytes()),
            )
            self.assertIn("Codex 通知与 hooks 配置已是最新", second.stdout)


if __name__ == "__main__":
    unittest.main()
