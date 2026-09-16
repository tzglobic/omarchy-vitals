"""Portable regression tests. All process signalling is mocked."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parents[1] / "bin" / "omarchy-vitals"
loader = importlib.machinery.SourceFileLoader("vitals", str(BIN))
spec = importlib.util.spec_from_loader("vitals", loader)
vitals = importlib.util.module_from_spec(spec)
loader.exec_module(vitals)


class CollectorRegressions(unittest.TestCase):
    def test_guest_time_is_not_counted_twice(self):
        self.assertEqual(vitals.busy_percent([100, 0, 0, 100, 0, 0, 0, 0, 50, 0], [0] * 10), 50.0)
        self.assertEqual(vitals.busy_percent([0, 100, 0, 100, 0, 0, 0, 0, 0, 50], [0] * 10), 50.0)

    def test_process_names(self):
        for cmdline, expected in [("   \0", "worker"), ("\0", "worker"),
                                  ("/usr/bin/worker-long\0", "worker-long")]:
            with self.subTest(cmdline=cmdline), patch.object(vitals, "read_text", return_value=cmdline):
                self.assertEqual(vitals.process_name(42, "worker"), expected)

    def test_nvidia_optional_fields(self):
        probe = vitals.GpuProbe.__new__(vitals.GpuProbe)
        probe.vendor, probe.name = "NVIDIA", ""
        for missing in ("[N/A]", "N/A", "[Not Supported]", "", "NaN", "inf", "-1"):
            with self.subTest(missing=missing), patch.object(vitals.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout="GPU, 12.5, 100.5, 1000, 50, 800, " + missing + "\n"
            )):
                result = probe._nvidia()
                self.assertTrue(result["available"])
                self.assertEqual(result["percent"], 12.5)
                self.assertEqual(result["vramUsedBytes"], 100.5 * 1024 * 1024)
                self.assertIsNone(result["maxFreqMhz"])
        with patch.object(vitals.subprocess, "run", return_value=SimpleNamespace(
            returncode=0, stdout="GPU, [N/A], [N/A], [N/A], [N/A], [N/A], [N/A]\n"
        )):
            result = probe._nvidia()
            self.assertIsNone(result["percent"])
            self.assertIsNone(result["vramUsedBytes"])
        for stdout, code in [("", 0), ("GPU, 10", 0), ("error", 1)]:
            with patch.object(vitals.subprocess, "run", return_value=SimpleNamespace(returncode=code, stdout=stdout)):
                self.assertFalse(probe._nvidia()["available"])

    def test_process_rows_include_identity(self):
        info = dict(pid=424242, start=987654, ticks=100, state="S", rss=4096, comm="worker")
        with patch.object(vitals.os, "listdir", return_value=["424242"]), \
             patch.object(vitals, "read_text", return_value=""), \
             patch.object(vitals, "parse_stat", return_value=info), \
             patch.object(vitals.os, "stat", return_value=SimpleNamespace(st_uid=os.getuid())):
            rows, _ = vitals.scan_processes({}, None, 1, os.getuid(), 1)
            self.assertEqual(rows[0]["startTime"], "987654")


class SignalRegressions(unittest.TestCase):
    def setUp(self):
        self.open = self.enterContext(patch.object(vitals.os, "pidfd_open", create=True, return_value=71))
        self.send = self.enterContext(patch.object(vitals.signal, "pidfd_send_signal", create=True))
        self.close = self.enterContext(patch.object(vitals.os, "close"))
        self.kill = self.enterContext(patch.object(vitals.os, "kill"))
        self.enterContext(patch.object(vitals.os, "getpid", return_value=100))
        self.enterContext(patch.object(vitals.os, "getppid", return_value=99))
        self.owner = self.enterContext(patch.object(vitals.os, "stat", return_value=SimpleNamespace(st_uid=os.getuid())))
        self.enterContext(patch.object(vitals, "read_text", return_value="fixture"))
        self.info = self.enterContext(patch.object(vitals, "parse_stat", return_value={"start": 123}))

    def tearDown(self):
        self.kill.assert_not_called()

    def test_matching_process_uses_pinned_descriptor(self):
        for mode, sig in [("term", vitals.signal.SIGTERM), ("kill", vitals.signal.SIGKILL)]:
            self.assertTrue(vitals.deliver_signal(mode, 424242, "123")["ok"])
            self.send.assert_called_with(71, sig)
        self.assertEqual(self.close.call_count, 2)

    def test_reused_pid_is_rejected(self):
        self.info.return_value = {"start": 124}
        self.assertFalse(vitals.deliver_signal("term", 424242, "123")["ok"])
        self.send.assert_not_called()
        self.close.assert_called_once_with(71)

    def test_owner_is_checked(self):
        self.owner.return_value.st_uid = os.getuid() + 1
        self.assertFalse(vitals.deliver_signal("term", 424242, "123")["ok"])
        self.send.assert_not_called()
        self.close.assert_called_once_with(71)

    def test_exit_after_validation_cannot_signal_replacement(self):
        self.send.side_effect = ProcessLookupError()
        self.assertFalse(vitals.deliver_signal("term", 424242, "123")["ok"])
        self.close.assert_called_once_with(71)

    def test_missing_process(self):
        self.info.return_value = None
        self.assertFalse(vitals.deliver_signal("term", 424242, "123")["ok"])
        self.send.assert_not_called()
        self.close.assert_called_once_with(71)

    def test_unsupported_kernel_fails_closed(self):
        self.open.side_effect = OSError("pidfd unavailable")
        self.assertFalse(vitals.deliver_signal("term", 424242, "123")["ok"])
        self.send.assert_not_called()
        self.close.assert_not_called()

    def test_invalid_requests_never_open_target(self):
        for mode, pid, start in [("term", 1, "123"), ("term", 100, "123"),
                                  ("term", 99, "123"), ("term", "bad", "123"),
                                  ("term", 424242, None), ("term", 424242, "bad"),
                                  ("term", 424242, "-1"), ("bad", 424242, "123")]:
            self.assertFalse(vitals.deliver_signal(mode, pid, start)["ok"])
        self.open.assert_not_called()
        self.send.assert_not_called()


if __name__ == "__main__":
    unittest.main()
