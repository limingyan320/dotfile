import unittest
from unittest import mock

import listener


class FakeProcess:
    def __init__(self):
        self.returncode = None

    def poll(self):
        return self.returncode

    def terminate(self):
        self.returncode = -15


class PopupRegistryTest(unittest.TestCase):
    def setUp(self):
        self.processes = []
        self.launch = mock.patch.object(
            listener.notify_backend,
            "launch_macos_notification",
            self._launch,
        )
        self.launch.start()
        self.registry = listener.PopupRegistry()

    def tearDown(self):
        self.registry.close()
        self.launch.stop()

    def _launch(self, _payload, slot=0):
        process = FakeProcess()
        process.slot = slot
        self.processes.append(process)
        return process

    def test_dismiss_tombstone_blocks_late_notification(self):
        payload = {"notification-id": "turn-1"}
        self.assertTrue(self.registry.show(payload))
        self.assertEqual(len(self.processes), 1)
        self.assertEqual(self.processes[0].slot, 0)

        self.assertTrue(self.registry.show(payload))
        self.assertEqual(len(self.processes), 1)

        self.assertTrue(self.registry.dismiss("turn-1"))
        self.assertEqual(self.processes[0].returncode, -15)
        self.assertTrue(self.registry.show(payload))
        self.assertEqual(len(self.processes), 1)

    def test_popups_receive_distinct_slots(self):
        self.registry.show({"notification-id": "turn-1"})
        self.registry.show({"notification-id": "turn-2"})
        self.assertEqual([process.slot for process in self.processes], [0, 1])


if __name__ == "__main__":
    unittest.main()
