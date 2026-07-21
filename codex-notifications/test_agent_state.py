import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agent_state


class AgentStateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.server = str(Path(self.temporary.name) / "nvim-test.sock")
        self.environment = mock.patch.dict(
            os.environ,
            {
                "DOTFILES_NVIM_SESSION_DIR": self.temporary.name,
                "NVIM": self.server,
            },
        )
        self.environment.start()
        self.query = mock.patch.object(agent_state, "_query_nvim", self._query_nvim)
        self.query.start()
        self.posts = []
        self.post = mock.patch.object(agent_state, "_post_listener", self._post_listener)
        self.post.start()

    def tearDown(self):
        self.post.stop()
        self.query.stop()
        self.environment.stop()
        self.temporary.cleanup()

    def _query_nvim(self, _server, expression):
        if "dotfiles_session_name" in expression:
            return "gpu experiment"
        return "v:false"

    def _post_listener(self, path, payload):
        self.posts.append((path, payload))
        return True

    @staticmethod
    def hook_payload(event, turn):
        return {
            "hook_event_name": event,
            "session_id": "thread-1",
            "turn_id": turn,
            "cwd": "/tmp/project",
        }

    @staticmethod
    def notify_payload(turn):
        return {
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": turn,
            "cwd": "/tmp/project",
            "last-assistant-message": "done",
        }

    def test_working_ready_notify_acknowledge(self):
        agent_state.handle_hook(self.hook_payload("UserPromptSubmit", "turn-1"))
        self.assertEqual(agent_state.read_state(self.server)["state"], agent_state.WORKING)

        agent_state.handle_hook(self.hook_payload("Stop", "turn-1"))
        ready = agent_state.read_state(self.server)
        self.assertEqual(ready["state"], agent_state.READY)
        self.assertTrue(ready["unread"])
        self.assertFalse(ready["notified"])

        enriched = agent_state.prepare_notification(self.notify_payload("turn-1"))
        self.assertEqual(enriched["nvim-session"], "gpu experiment")
        self.assertEqual(enriched["notification-id"], ready["notification_id"])
        self.assertTrue(agent_state.read_state(self.server)["notified"])

        acknowledged = agent_state.acknowledge(self.server)
        self.assertEqual(acknowledged["state"], agent_state.IDLE)
        self.assertFalse(acknowledged["unread"])
        self.assertEqual(self.posts[-1][0], "/dismiss")
        self.assertEqual(
            self.posts[-1][1]["notification-id"], ready["notification_id"]
        )

        self.assertIsNone(agent_state.prepare_notification(self.notify_payload("turn-1")))

    def test_new_turn_dismisses_ready_and_rejects_stale_completion(self):
        agent_state.handle_hook(self.hook_payload("UserPromptSubmit", "turn-1"))
        agent_state.handle_hook(self.hook_payload("Stop", "turn-1"))
        old_id = agent_state.read_state(self.server)["notification_id"]

        agent_state.handle_hook(self.hook_payload("UserPromptSubmit", "turn-2"))
        state = agent_state.read_state(self.server)
        self.assertEqual(state["state"], agent_state.WORKING)
        self.assertEqual(state["turn_id"], "turn-2")
        self.assertIn(("/dismiss", {"notification-id": old_id}), self.posts)

        agent_state.handle_hook(self.hook_payload("Stop", "turn-1"))
        self.assertEqual(agent_state.read_state(self.server)["turn_id"], "turn-2")
        self.assertIsNone(agent_state.prepare_notification(self.notify_payload("turn-1")))

    def test_observed_completion_is_seen_without_notification(self):
        agent_state.record_working(self.hook_payload("UserPromptSubmit", "turn-1"))
        with mock.patch.object(agent_state, "_nvim_observes_codex", return_value=True):
            result = agent_state.record_completion(
                self.hook_payload("Stop", "turn-1"), mark_notified=True
            )
        self.assertFalse(result["should_notify"])
        state = agent_state.read_state(self.server)
        self.assertEqual(state["state"], agent_state.IDLE)
        self.assertEqual(state["seen_turn_id"], "turn-1")

    def test_terminal_idle_only_clears_matching_working_turn(self):
        agent_state.record_working(self.hook_payload("UserPromptSubmit", "turn-1"))
        state = agent_state.mark_idle_if_working(
            self.server, "turn-1", "terminal-title-idle"
        )
        self.assertEqual(state["state"], agent_state.IDLE)
        self.assertFalse(state["unread"])
        self.assertEqual(state["ended_reason"], "terminal-title-idle")

    def test_terminal_idle_does_not_clear_newer_or_ready_turn(self):
        agent_state.record_working(self.hook_payload("UserPromptSubmit", "turn-1"))
        agent_state.record_working(self.hook_payload("UserPromptSubmit", "turn-2"))
        agent_state.mark_idle_if_working(self.server, "turn-1")
        state = agent_state.read_state(self.server)
        self.assertEqual(state["state"], agent_state.WORKING)
        self.assertEqual(state["turn_id"], "turn-2")

        agent_state.record_completion(
            self.hook_payload("Stop", "turn-2"), observed=False
        )
        agent_state.mark_idle_if_working(self.server, "turn-2")
        state = agent_state.read_state(self.server)
        self.assertEqual(state["state"], agent_state.READY)
        self.assertTrue(state["unread"])


if __name__ == "__main__":
    unittest.main()
