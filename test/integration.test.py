"""Linux-only live collector checks; never signals a process."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

BIN = Path(__file__).resolve().parents[1] / "bin" / "omarchy-vitals"


@unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux /proc and /sys")
class CollectorIntegration(unittest.TestCase):
    def test_once(self):
        result = subprocess.run([sys.executable, str(BIN), "--once", "--procs", "3"],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        doc = json.loads(result.stdout)
        for key in ("version", "at", "uptimeSec", "host", "cpu", "memory", "gpu", "io", "disks", "processes"):
            self.assertIn(key, doc)
        self.assertEqual(doc["host"]["threads"], os.cpu_count())
        self.assertGreater(len(doc["cpu"]["cores"]), 0)
        self.assertLessEqual(len(doc["processes"]), 3)
        self.assertTrue(0 <= doc["memory"]["percent"] <= 100)
        self.assertTrue(any(d["path"] == "/" for d in doc["disks"]))
        for proc in doc["processes"]:
            for key in ("pid", "startTime", "name", "cpuPercent", "rssBytes", "mine"):
                self.assertIn(key, proc)
            self.assertTrue(proc["startTime"].isdigit())


if __name__ == "__main__":
    unittest.main()
