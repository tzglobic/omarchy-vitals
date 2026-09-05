#!/usr/bin/env python3
# Run with: python3 test/collector.test.py
# Exercises the parsers in bin/omarchy-vitals against fixtures, then runs the
# real collector once to check the document shape. Nothing here signals a
# process or reads anything the collector would not read anyway.

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "bin", "omarchy-vitals")

loader = importlib.machinery.SourceFileLoader("vitals", BIN)
spec = importlib.util.spec_from_loader("vitals", loader)
vitals = importlib.util.module_from_spec(spec)
loader.exec_module(vitals)

failures = 0


def check(name, actual, expected):
    global failures
    if actual == expected:
        return
    failures += 1
    print("FAIL %s\n  expected %r\n  actual   %r" % (name, expected, actual), file=sys.stderr)


def ok(name, condition):
    global failures
    if condition:
        return
    failures += 1
    print("FAIL " + name, file=sys.stderr)


# --- /proc/stat
STAT = """cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
intr 12345
ctxt 6789
"""
total, cores = vitals.parse_cpu_stat(STAT)
check("parse_cpu_stat aggregate", total, [100, 0, 100, 800, 0, 0, 0, 0, 0, 0])
check("parse_cpu_stat cores", sorted(cores), [0, 1])
check("busy_percent", vitals.busy_percent([200, 0, 200, 1600, 0, 0, 0], [100, 0, 100, 800, 0, 0, 0]), 20.0)
check("busy_percent counts iowait as idle", vitals.busy_percent([100, 0, 100, 800, 200, 0, 0], [100, 0, 100, 800, 0, 0, 0]), 0.0)
check("busy_percent no movement", vitals.busy_percent(total, total), 0.0)
check("busy_percent short input", vitals.busy_percent([1, 2], [0, 1]), 0.0)

# --- /proc/meminfo
MEMINFO = """MemTotal:       16000000 kB
MemFree:         3000000 kB
MemAvailable:    8000000 kB
Buffers:          500000 kB
Cached:          4000000 kB
SReclaimable:     500000 kB
SwapTotal:      16000000 kB
SwapFree:       15500000 kB
HugePages_Total:       0
"""
mem = vitals.parse_meminfo(MEMINFO)
check("parse_meminfo scales kB", mem["MemTotal"], 16000000 * 1024)
check("parse_meminfo keeps bare counts", mem["HugePages_Total"], 0)
snap = vitals.memory_snapshot(mem)
check("memory_snapshot used", snap["usedBytes"], 8000000 * 1024)
check("memory_snapshot percent", snap["percent"], 50.0)
check("memory_snapshot cached", snap["cachedBytes"], 5000000 * 1024)
check("memory_snapshot free", snap["freeBytes"], 3000000 * 1024)
check("memory_snapshot swap", (snap["swapUsedBytes"], snap["swapPercent"]), (500000 * 1024, 3.1))
check("memory_snapshot empty", vitals.memory_snapshot({})["percent"], 0.0)

# --- /proc/diskstats: whole physical disks only, no partitions, no zram
DISKSTATS = """ 259       0 nvme0n1 38653 26838 6610136 14668 42429 16439 2519293 49352 0 20806 67784 0 0 0 0 1841 3763
 259       1 nvme0n1p1 100 0 2000 0 100 0 4000 0 0 0 0 0 0 0 0 0 0
 252       0 zram0 75 0 2848 0 1 0 8 0 0 0 0 0 0 0 0 0 0
   8       0 sda 10 0 100 0 20 0 200 0 0 0 0 0 0 0 0 0 0
"""
check("parse_diskstats", vitals.parse_diskstats(DISKSTATS), ((6610136 + 100) * 512, (2519293 + 200) * 512))

# --- /proc/net/dev: everything but loopback
NETDEV = """Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:   51287     572    0    0    0     0          0         0    51287     572    0    0    0     0       0          0
wlp0s20f3: 234371576  189806    0    0    0     0          0         0 20296568   38000    0    0    0     0       0          0
enp0s13f0u1u4u4:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
"""
check("parse_netdev", vitals.parse_netdev(NETDEV), (234371576, 20296568))

# --- /proc/<pid>/stat with an awkward comm
STATLINE = "4242 (Web Content) S 1 4242 4242 0 -1 4194560 100 0 0 0 350 150 0 0 20 0 30 0 987654 1000000 2560 " + " ".join(["0"] * 28)
info = vitals.parse_stat(STATLINE)
check("parse_stat pid", info["pid"], 4242)
check("parse_stat comm with spaces", info["comm"], "Web Content")
check("parse_stat state", info["state"], "S")
check("parse_stat ticks", info["ticks"], 500)
check("parse_stat starttime", info["start"], 987654)
check("parse_stat rss", info["rss"], 2560 * vitals.PAGE_SIZE)
check("parse_stat nested parens", vitals.parse_stat("7 (a (b) c) R " + " ".join(["1"] * 50))["comm"], "a (b) c")
check("parse_stat garbage", vitals.parse_stat("nonsense"), None)
check("parse_stat truncated", vitals.parse_stat("7 (x) R 1 2"), None)

# --- pci.ids lookup prefers the bracketed marketing name
name = vitals.pci_device_name("0x8086", "0x46a6")
ok("pci_device_name resolves or degrades gracefully", name == "Iris Xe Graphics" or name == "")
check("pci_device_name unknown device", vitals.pci_device_name("0x8086", "0xffff"), "")

# --- signals: never touch pid 1, another user's process, or the shell itself
check("deliver_signal refuses init", vitals.deliver_signal("term", 1)["ok"], False)
check("deliver_signal refuses garbage", vitals.deliver_signal("term", "abc")["ok"], False)
check("deliver_signal refuses missing", vitals.deliver_signal("term", 2 ** 22 - 1)["ok"], False)
check("deliver_signal refuses itself", vitals.deliver_signal("term", os.getpid())["ok"], False)
if os.getuid() != 0:
    check("deliver_signal refuses another user's process", vitals.deliver_signal("term", 2)["ok"], False)

# --- the real thing, once
result = subprocess.run([sys.executable, BIN, "--once", "--procs", "3"], capture_output=True, text=True, timeout=20)
check("--once exits cleanly", result.returncode, 0)
doc = json.loads(result.stdout.strip().splitlines()[-1]) if result.stdout.strip() else {}
for key in ("version", "at", "uptimeSec", "host", "cpu", "memory", "gpu", "io", "disks", "processes"):
    ok("--once document has " + key, key in doc)
check("--once host threads", doc.get("host", {}).get("threads"), os.cpu_count())
ok("--once per-core list matches thread count", len(doc.get("cpu", {}).get("cores", [])) == os.cpu_count())
ok("--once reports at most the requested processes", len(doc.get("processes", [])) <= 3)
ok("--once memory percent is sane", 0 <= doc.get("memory", {}).get("percent", -1) <= 100)
ok("--once lists the root filesystem", any(d.get("path") == "/" for d in doc.get("disks", [])))
for proc in doc.get("processes", []):
    ok("--once process rows carry the panel's fields", all(k in proc for k in ("pid", "name", "cpuPercent", "rssBytes", "mine")))

if failures:
    print("%d failure(s)" % failures, file=sys.stderr)
    sys.exit(1)
print("collector.test.py: all checks passed")
